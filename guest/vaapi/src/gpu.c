/* The media connection to the phone, for streams whose pictures a GPU-presented
 * window shows (docs/gpu-media.md). It is a stream of the GPU broker
 * ($CABOOSE_GFXSTREAM_SOCKET): the broker admits it with its ordinary hello and
 * binds it to this process like the process's Vulkan streams; the phone decodes
 * what it carries in hardware and keeps each surface's latest picture until the
 * Vulkan driver latches it into the image that samples the surface. */
#define _GNU_SOURCE
#include "cbva.h"
#include "gpu_media.h"

#include <errno.h>
#include <link.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <sys/random.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

/* The broker's local hello for the indexed (version 4) live wire, as the Vulkan
 * driver sends it (docs/gpu-live.md, "Envelope"). */
static const uint8_t broker_hello[48] = {
    'C', 'B', 'G', 'L', 'R', 'E', 'F', '1', 4, 0, 0, 0, 0x70, 0, 0, 0,
    0x20, 0xd3, 0xbb, 0x2e, 0x30, 0x33, 0x7c, 0xab, 0xf0, 0xfe, 0xbb, 0x00, 0x6e, 0xd1, 0x02, 0xab,
    0x25, 0xcc, 0xf6, 0xd9, 0xdd, 0xbf, 0xaf, 0x62, 0x4c, 0x7e, 0x68, 0xf9, 0x04, 0x09, 0x69, 0xc0,
};

#define EVENT_QUEUE 32
#define RX_LIMIT 4096

struct cb_gpu {
    int fd;
    uint8_t token[16];
    cb_gm_cap caps[CB_GM_MAX_CAPS];
    unsigned ncaps;
    uint8_t rx[RX_LIMIT];
    size_t rx_len;
    cb_gpu_event queue[EVENT_QUEUE];
    unsigned nqueue;
};

static long ms_since(const struct timespec *start)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (now.tv_sec - start->tv_sec) * 1000 + (now.tv_nsec - start->tv_nsec) / 1000000;
}

static int write_all(int fd, const uint8_t *p, size_t n)
{
    while (n) {
        ssize_t w = send(fd, p, n, MSG_NOSIGNAL);
        if (w < 0) {
            if (errno == EINTR)
                continue;
            return -1; /* includes the send timeout: a stalled phone */
        }
        p += w;
        n -= (size_t)w;
    }
    return 0;
}

static int read_exact(int fd, uint8_t *p, size_t n, int timeout_ms)
{
    struct timespec start;
    clock_gettime(CLOCK_MONOTONIC, &start);
    while (n) {
        long left = timeout_ms - ms_since(&start);
        if (left <= 0)
            return -1;
        struct pollfd pfd = { fd, POLLIN, 0 };
        int r = poll(&pfd, 1, (int)left);
        if (r < 0 && errno == EINTR)
            continue;
        if (r <= 0)
            return -1;
        ssize_t got = recv(fd, p, n, 0);
        if (got < 0 && errno == EINTR)
            continue;
        if (got <= 0)
            return -1;
        p += got;
        n -= (size_t)got;
    }
    return 0;
}

static int send_record(cb_gpu *g, uint32_t type, const uint8_t *head, size_t head_len,
                       const uint8_t *data, size_t len)
{
    if (head_len + len > CB_GM_MAX_RECORD)
        return -1;
    uint8_t env[8];
    cb_gm_record_head(env, type, (uint32_t)(head_len + len));
    return write_all(g->fd, env, 8) || write_all(g->fd, head, head_len) ||
                   (len && write_all(g->fd, data, len))
               ? -1
               : 0;
}

/* Parses one complete record from rx. Returns 1 with *type, *payload and
 * *len set, 0 when none is complete, -1 when the stream is malformed. */
static int take_record(cb_gpu *g, uint32_t *type, uint8_t *payload, size_t *len)
{
    if (g->rx_len < 8)
        return 0;
    uint32_t n = cb_gm_rd32(g->rx + 4);
    if (n > RX_LIMIT - 8)
        return -1;
    if (g->rx_len < 8 + n)
        return 0;
    *type = cb_gm_rd32(g->rx);
    memcpy(payload, g->rx + 8, n);
    *len = n;
    memmove(g->rx, g->rx + 8 + n, g->rx_len - 8 - n);
    g->rx_len -= 8 + n;
    return 1;
}

/* Reads what the phone sent, waiting up to timeout_ms for the first byte.
 * Returns 0, or -1 on a closed or broken stream. */
static int fill(cb_gpu *g, int timeout_ms)
{
    struct pollfd pfd = { g->fd, POLLIN, 0 };
    int r = poll(&pfd, 1, timeout_ms);
    if (r < 0)
        return errno == EINTR ? 0 : -1;
    if (r == 0)
        return 0;
    if (g->rx_len == RX_LIMIT)
        return -1;
    ssize_t n = recv(g->fd, g->rx + g->rx_len, RX_LIMIT - g->rx_len, MSG_DONTWAIT);
    if (n == 0)
        return -1;
    if (n < 0)
        return errno == EAGAIN || errno == EINTR ? 0 : -1;
    g->rx_len += (size_t)n;
    return 0;
}

/* Handles one record from the phone: CAPS is kept, FAIL and REPLAY are queued.
 * Returns -1 when it is malformed. */
static int handle(cb_gpu *g, uint32_t type, const uint8_t *p, size_t len)
{
    if (type == CB_GM_CAPS) {
        int n = cb_gm_parse_caps(p, len, g->caps, CB_GM_MAX_CAPS);
        if (n < 0)
            return -1;
        g->ncaps = (unsigned)n;
        return 0;
    }
    if ((type == CB_GM_FAIL && len == 8) || (type == CB_GM_REPLAY && len == 4)) {
        if (g->nqueue < EVENT_QUEUE)
            g->queue[g->nqueue++] = (cb_gpu_event){ type, cb_gm_rd32(p), type == CB_GM_FAIL ? cb_gm_rd32(p + 4) : 0 };
        return 0;
    }
    return -1;
}

static int phdr_has_driver(struct dl_phdr_info *info, size_t size, void *data)
{
    (void)size;
    (void)data;
    return info->dlpi_name && strstr(info->dlpi_name, "libvulkan_gfxstream") != NULL;
}

int cb_gpu_consumer_present(void)
{
    return dl_iterate_phdr(phdr_has_driver, NULL) != 0;
}

cb_gpu *cb_gpu_open(void)
{
    const char *path = getenv("CABOOSE_GFXSTREAM_SOCKET");
    const char *opt = getenv("CABOOSE_VA_GPU");
    if (!path || !*path || (opt && strcmp(opt, "0") == 0))
        return NULL;
    struct sockaddr_un addr = { .sun_family = AF_UNIX };
    if (strlen(path) >= sizeof(addr.sun_path))
        return NULL;
    memcpy(addr.sun_path, path, strlen(path) + 1);
    cb_gpu *g = calloc(1, sizeof(*g));
    if (!g)
        return NULL;
    g->fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (g->fd < 0 || connect(g->fd, (struct sockaddr *)&addr, sizeof(addr)) < 0)
        goto fail;
    /* A phone that stops reading must not wedge the player: the stream falls back. */
    struct timeval tv = { 2, 0 };
    setsockopt(g->fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    int sz = 4 << 20;
    setsockopt(g->fd, SOL_SOCKET, SO_SNDBUF, &sz, sizeof(sz));
    if (getrandom(g->token, sizeof(g->token), 0) != (ssize_t)sizeof(g->token))
        goto fail;
    /* The broker answers once the phone has opened this stream for the process. */
    uint8_t reply[sizeof(broker_hello)];
    if (write_all(g->fd, broker_hello, sizeof(broker_hello)) ||
        read_exact(g->fd, reply, sizeof(reply), 5000) || memcmp(reply, broker_hello, sizeof(reply)))
        goto fail;
    uint8_t flags[4], hello[CB_GM_HELLO_SIZE];
    cb_gm_le32(flags, CB_GM_STREAM_FLAGS);
    cb_gm_encode_hello(hello, g->token);
    if (write_all(g->fd, flags, 4) || send_record(g, CB_GM_HELLO, hello, sizeof(hello), NULL, 0))
        goto fail;
    /* The phone answers HELLO with what it can decode. */
    struct timespec start;
    clock_gettime(CLOCK_MONOTONIC, &start);
    for (;;) {
        uint32_t type;
        uint8_t payload[RX_LIMIT];
        size_t len;
        int r = take_record(g, &type, payload, &len);
        if (r < 0)
            goto fail;
        if (r) {
            if (type != CB_GM_CAPS || handle(g, type, payload, len))
                goto fail;
            break;
        }
        long left = 1000 - ms_since(&start);
        if (left <= 0 || fill(g, (int)left))
            goto fail;
    }
    cb_log("media connection: the phone decodes %u formats", g->ncaps);
    return g;
fail:
    cb_log("no media connection to the phone (%s)", strerror(errno));
    if (g->fd >= 0)
        close(g->fd);
    free(g);
    return NULL;
}

void cb_gpu_close(cb_gpu *g)
{
    if (!g)
        return;
    close(g->fd);
    free(g);
}

const uint8_t *cb_gpu_token(const cb_gpu *g) { return g->token; }

int cb_gpu_supports(const cb_gpu *g, uint8_t codec, unsigned depth, unsigned w, unsigned h)
{
    for (unsigned i = 0; i < g->ncaps; i++) {
        const cb_gm_cap *c = &g->caps[i];
        if (c->codec == codec && depth <= c->max_depth && w <= c->max_width && h <= c->max_height)
            return 1;
    }
    return 0;
}

int cb_gpu_open_stream(cb_gpu *g, uint32_t stream, uint8_t codec, unsigned depth, unsigned w, unsigned h)
{
    uint8_t head[CB_GM_OPEN_SIZE];
    cb_gm_encode_open(head, stream, codec, (uint8_t)depth, (uint16_t)w, (uint16_t)h);
    return send_record(g, CB_GM_OPEN, head, sizeof(head), NULL, 0);
}

int cb_gpu_unit(cb_gpu *g, uint32_t stream, uint32_t seq, uint32_t surface, unsigned flags,
                uint64_t serial, unsigned w, unsigned h, const uint8_t *data, size_t len)
{
    uint8_t head[CB_GM_UNIT_HEAD];
    cb_gm_encode_unit(head, stream, seq, surface, flags, serial, (uint16_t)w, (uint16_t)h);
    return send_record(g, CB_GM_UNIT, head, sizeof(head), data, len);
}

int cb_gpu_close_stream(cb_gpu *g, uint32_t stream)
{
    uint8_t head[4];
    cb_gm_le32(head, stream);
    return send_record(g, CB_GM_CLOSE, head, sizeof(head), NULL, 0);
}

int cb_gpu_surface_gone(cb_gpu *g, uint32_t surface)
{
    uint8_t head[4];
    cb_gm_le32(head, surface);
    return send_record(g, CB_GM_SURFACE_GONE, head, sizeof(head), NULL, 0);
}

int cb_gpu_poll(cb_gpu *g, cb_gpu_event *ev)
{
    for (;;) {
        if (g->nqueue) {
            *ev = g->queue[0];
            memmove(g->queue, g->queue + 1, --g->nqueue * sizeof(*ev));
            return 1;
        }
        uint32_t type;
        uint8_t payload[RX_LIMIT];
        size_t len;
        int r = take_record(g, &type, payload, &len);
        if (r < 0)
            return -1;
        if (r) {
            if (handle(g, type, payload, len))
                return -1;
            continue;
        }
        size_t before = g->rx_len;
        if (fill(g, 0))
            return -1;
        if (g->rx_len == before)
            return 0;
    }
}
