/* The video socket to caboose-display (see proto.h), or, for tests, a file that
 * receives the same messages: CABOOSE_VA_SINK=/path/to/capture. */
#define _GNU_SOURCE
#include "cbva.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define EVENT_QUEUE 32

struct cb_sink {
    int fd;
    int is_file;
    unsigned next_tag;
    uint8_t rx[64];
    size_t rx_len;
    cb_sink_event queue[EVENT_QUEUE];
    unsigned nqueue;
};

static int write_all(cb_sink *s, const uint8_t *p, size_t n)
{
    while (n) {
        ssize_t w = s->is_file ? write(s->fd, p, n) : send(s->fd, p, n, MSG_NOSIGNAL);
        if (w < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        p += w;
        n -= (size_t)w;
    }
    return 0;
}

static int send_msg(cb_sink *s, uint8_t type, const uint8_t *head, size_t head_len,
                    const uint8_t *data, size_t len)
{
    uint8_t env[5] = { type };
    uint32_t total = (uint32_t)(head_len + len);
    memcpy(env + 1, &total, 4); /* little-endian hosts only (x86_64, aarch64) */
    if (write_all(s, env, 5) || write_all(s, head, head_len) || write_all(s, data, len))
        return -1;
    return 0;
}

cb_sink *cb_sink_open(void)
{
    cb_sink *s = calloc(1, sizeof(*s));
    if (!s)
        return NULL;
    s->fd = -1;
    const char *file = getenv("CABOOSE_VA_SINK");
    if (file && *file) {
        s->fd = open(file, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_APPEND, 0644);
        s->is_file = 1;
    } else {
        char path[sizeof(((struct sockaddr_un *)0)->sun_path)];
        const char *env = getenv("CABOOSE_VIDEO_SOCKET");
        const char *run = getenv("XDG_RUNTIME_DIR");
        if (env && *env)
            snprintf(path, sizeof(path), "%s", env);
        else if (run && *run)
            snprintf(path, sizeof(path), "%s/caboose-video.sock", run);
        else
            goto fail;
        s->fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
        if (s->fd < 0)
            goto fail;
        struct sockaddr_un addr = { .sun_family = AF_UNIX };
        memcpy(addr.sun_path, path, strlen(path) + 1);
        if (connect(s->fd, (struct sockaddr *)&addr, sizeof(addr)) < 0)
            goto fail;
        /* A stalled compositor must not wedge the player forever. */
        struct timeval tv = { 2, 0 };
        setsockopt(s->fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
        int sz = 4 << 20;
        setsockopt(s->fd, SOL_SOCKET, SO_SNDBUF, &sz, sizeof(sz));
    }
    if (s->fd < 0)
        goto fail;
    uint8_t head[8];
    uint16_t ver = CB_PROTO_VERSION, zero = 0;
    uint32_t pid = (uint32_t)getpid();
    memcpy(head, &ver, 2);
    memcpy(head + 2, &zero, 2);
    memcpy(head + 4, &pid, 4);
    const char *name = program_invocation_short_name;
    if (send_msg(s, CB_MSG_HELLO, head, sizeof(head), (const uint8_t *)name, strlen(name)))
        goto fail;
    return s;
fail:
    if (s->fd >= 0)
        close(s->fd);
    free(s);
    return NULL;
}

void cb_sink_close(cb_sink *s)
{
    if (!s)
        return;
    close(s->fd);
    free(s);
}

/* Reads whatever the compositor sent. Returns 1 when a message was parsed into
 * *ev, 0 when none is complete, -1 on a closed or broken socket. */
static int read_one(cb_sink *s, cb_sink_event *ev, int timeout_ms)
{
    for (;;) {
        if (s->rx_len >= 5) {
            uint32_t len;
            memcpy(&len, s->rx + 1, 4);
            if (len > sizeof(s->rx) - 5)
                return -1;
            if (s->rx_len >= 5 + len) {
                uint8_t *p = s->rx + 5;
                memset(ev, 0, sizeof(*ev));
                ev->type = s->rx[0];
                if (len >= 4)
                    memcpy(&ev->stream, p, 4);
                if (len >= 5)
                    ev->a = p[4];
                if (len >= 6)
                    ev->b = p[5];
                memmove(s->rx, s->rx + 5 + len, s->rx_len - 5 - len);
                s->rx_len -= 5 + len;
                return 1;
            }
        }
        struct pollfd pfd = { s->fd, POLLIN, 0 };
        int r = poll(&pfd, 1, timeout_ms);
        if (r <= 0)
            return r < 0 && errno != EINTR ? -1 : 0;
        ssize_t n = recv(s->fd, s->rx + s->rx_len, sizeof(s->rx) - s->rx_len, MSG_DONTWAIT);
        if (n == 0)
            return -1;
        if (n < 0)
            return errno == EAGAIN || errno == EINTR ? 0 : -1;
        s->rx_len += (size_t)n;
    }
}

/* Returns 0 with the tag and mode, -2 when the compositor did not answer in
 * time, -1 when the socket failed. */
int cb_sink_open_stream(cb_sink *s, uint32_t stream, uint8_t codec, uint8_t profile,
                        uint8_t depth, unsigned w, unsigned h, unsigned *tag, int *mode)
{
    uint8_t head[12];
    uint16_t w16 = (uint16_t)w, h16 = (uint16_t)h;
    memcpy(head, &stream, 4);
    head[4] = codec;
    head[5] = profile;
    head[6] = depth;
    head[7] = 1; /* 4:2:0 */
    memcpy(head + 8, &w16, 2);
    memcpy(head + 10, &h16, 2);
    if (send_msg(s, CB_MSG_OPEN, head, sizeof(head), NULL, 0))
        return -1;
    if (s->is_file) {
        *tag = s->next_tag++ & 63;
        *mode = CB_MODE_PASSTHROUGH;
        return 0;
    }
    struct timespec start;
    clock_gettime(CLOCK_MONOTONIC, &start);
    for (;;) {
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        long waited = (now.tv_sec - start.tv_sec) * 1000 + (now.tv_nsec - start.tv_nsec) / 1000000;
        if (waited >= 1000)
            return -2; /* no answer: this stream decodes locally, the socket stays */
        cb_sink_event ev;
        int r = read_one(s, &ev, (int)(1000 - waited));
        if (r < 0)
            return -1;
        if (r == 0)
            continue;
        if (ev.type == CB_MSG_ACCEPT && ev.stream == stream) {
            *tag = ev.a & 63;
            *mode = ev.b;
            return 0;
        }
        if (s->nqueue < EVENT_QUEUE)
            s->queue[s->nqueue++] = ev;
    }
}

int cb_sink_poll(cb_sink *s, cb_sink_event *ev)
{
    if (s->nqueue) {
        *ev = s->queue[0];
        memmove(s->queue, s->queue + 1, --s->nqueue * sizeof(*ev));
        return 1;
    }
    if (s->is_file)
        return 0;
    return read_one(s, ev, 0);
}

static uint64_t now_us(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000u + (uint64_t)t.tv_nsec / 1000u;
}

int cb_sink_frame(cb_sink *s, uint32_t stream, uint32_t seq, uint32_t surface, unsigned flags,
                  unsigned w, unsigned h, const uint8_t *data, size_t len)
{
    uint8_t head[28] = { 0 };
    uint64_t t = now_us();
    uint16_t w16 = (uint16_t)w, h16 = (uint16_t)h;
    memcpy(head, &stream, 4);
    memcpy(head + 4, &seq, 4);
    memcpy(head + 8, &surface, 4);
    head[12] = (uint8_t)flags;
    memcpy(head + 16, &t, 8);
    memcpy(head + 24, &w16, 2);
    memcpy(head + 26, &h16, 2);
    return send_msg(s, CB_MSG_FRAME, head, sizeof(head), data, len);
}

int cb_sink_surface(cb_sink *s, uint32_t surface, uint64_t dev, uint64_t ino)
{
    uint8_t head[24] = { 0 };
    memcpy(head, &surface, 4);
    memcpy(head + 8, &dev, 8);
    memcpy(head + 16, &ino, 8);
    return send_msg(s, CB_MSG_SURFACE, head, sizeof(head), NULL, 0);
}

int cb_sink_surface_gone(cb_sink *s, uint32_t surface)
{
    return send_msg(s, CB_MSG_SURFACE_GONE, (const uint8_t *)&surface, 4, NULL, 0);
}

int cb_sink_close_stream(cb_sink *s, uint32_t stream, uint8_t reason)
{
    uint8_t head[5];
    memcpy(head, &stream, 4);
    head[4] = reason;
    return send_msg(s, CB_MSG_CLOSE, head, sizeof(head), NULL, 0);
}
