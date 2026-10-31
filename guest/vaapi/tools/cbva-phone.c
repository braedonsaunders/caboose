/* cbva-phone: a stand-in for the GPU broker and the phone at the other end of the
 * media connection (docs/gpu-media.md), for tests and debugging.
 *
 *   cbva-phone SOCKET CAPTURE [--caps all|h264|none] [--fail-after N] [--replay-after N]
 *
 * Listens on SOCKET (the driver's $CABOOSE_GFXSTREAM_SOCKET), answers the broker
 * hello and HELLO with CAPS (all: H.264 at 8 bits and the other codecs at 10, up to
 * 8192x8192, as a phone reports them), and
 * writes what the driver sends to CAPTURE in the video socket's capture format,
 * so `cbva-capture split` turns it into elementary streams: OPEN as OPEN, UNIT as
 * FRAME, CLOSE as CLOSE, SURFACE_GONE as SURFACE_GONE. --fail-after sends FAIL 2
 * for a stream after N units, --replay-after asks once for a replay after N units.
 * It checks the stream: HELLO first, known records, units of open streams with
 * nonzero serials that never decrease, per surface, except in replays. (A stream's
 * own units need not: an AV1 picture held back is sent after later ones, and a
 * shown forward key frame sends its picture a second time.) On SIGTERM or SIGINT it prints
 * one summary line and exits nonzero if the driver broke the contract. */
#define _GNU_SOURCE
#include "gpu_media.h"
#include "proto.h"

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static const uint8_t broker_hello[48] = {
    'C', 'B', 'G', 'L', 'R', 'E', 'F', '1', 4, 0, 0, 0, 0x70, 0, 0, 0,
    0x20, 0xd3, 0xbb, 0x2e, 0x30, 0x33, 0x7c, 0xab, 0xf0, 0xfe, 0xbb, 0x00, 0x6e, 0xd1, 0x02, 0xab,
    0x25, 0xcc, 0xf6, 0xd9, 0xdd, 0xbf, 0xaf, 0x62, 0x4c, 0x7e, 0x68, 0xf9, 0x04, 0x09, 0x69, 0xc0,
};

#define MAX_CLIENTS 16
#define MAX_STREAMS 256

typedef struct {
    int fd;
    int stage; /* 0 broker hello, 1 flags word, 2 HELLO record, 3 records */
    uint8_t *rx;
    size_t len, cap;
} client;

typedef struct {
    uint32_t id;
    int open;
    unsigned units;
    int failed, replayed;
} stream;

#define MAX_SURFACES 1024
static struct { uint32_t id; uint64_t serial; } surfaces[MAX_SURFACES];
static unsigned nsurfaces;

static uint64_t *surface_serial(uint32_t id)
{
    for (unsigned i = 0; i < nsurfaces; i++)
        if (surfaces[i].id == id)
            return &surfaces[i].serial;
    if (nsurfaces == MAX_SURFACES)
        return NULL;
    surfaces[nsurfaces].id = id;
    surfaces[nsurfaces].serial = 0;
    return &surfaces[nsurfaces++].serial;
}

static client clients[MAX_CLIENTS];
static stream streams[MAX_STREAMS];
static unsigned nstreams, total_units, violations, connections;
static FILE *capture;
static const char *caps_mode = "all";
static unsigned fail_after, replay_after;
static volatile sig_atomic_t done;

static void on_signal(int sig) { (void)sig; done = 1; }

static void violation(const char *what, uint32_t stream_id)
{
    fprintf(stderr, "cbva-phone: contract violation: %s (stream %u)\n", what, stream_id);
    violations++;
}

static stream *find(uint32_t id)
{
    for (unsigned i = 0; i < nstreams; i++)
        if (streams[i].id == id)
            return &streams[i];
    return NULL;
}

static int send_all(int fd, const uint8_t *p, size_t n)
{
    while (n) {
        ssize_t w = send(fd, p, n, MSG_NOSIGNAL);
        if (w < 0 && errno == EINTR)
            continue;
        if (w <= 0)
            return -1;
        p += w;
        n -= (size_t)w;
    }
    return 0;
}

static int send_record(int fd, uint32_t type, const uint8_t *payload, size_t len)
{
    uint8_t head[8];
    cb_gm_record_head(head, type, (uint32_t)len);
    return send_all(fd, head, 8) || send_all(fd, payload, len) ? -1 : 0;
}

static void put_msg(uint8_t type, const uint8_t *head, size_t head_len, const uint8_t *data, size_t len)
{
    uint8_t env[5] = { type };
    uint32_t total = (uint32_t)(head_len + len);
    memcpy(env + 1, &total, 4);
    fwrite(env, 1, 5, capture);
    fwrite(head, 1, head_len, capture);
    if (len)
        fwrite(data, 1, len, capture);
    fflush(capture);
}

static int send_caps(int fd)
{
    static const cb_gm_cap all[] = { { CB_CODEC_H264, 8, 8192, 8192 }, { CB_CODEC_HEVC, 10, 8192, 8192 },
                                     { CB_CODEC_VP9, 10, 8192, 8192 }, { CB_CODEC_AV1, 10, 8192, 8192 } };
    unsigned n = !strcmp(caps_mode, "none") ? 0 : !strcmp(caps_mode, "h264") ? 1 : 4;
    uint8_t p[8 + 4 * CB_GM_CAPS_ENTRY] = { 0 };
    cb_gm_le32(p, CB_GM_VERSION);
    cb_gm_le32(p + 4, n);
    for (unsigned i = 0; i < n; i++) {
        uint8_t *e = p + 8 + i * CB_GM_CAPS_ENTRY;
        e[0] = all[i].codec;
        e[1] = all[i].max_depth;
        cb_gm_le16(e + 4, all[i].max_width);
        cb_gm_le16(e + 6, all[i].max_height);
    }
    return send_record(fd, CB_GM_CAPS, p, 8 + n * CB_GM_CAPS_ENTRY);
}

/* One complete record. Returns -1 to drop the client. */
static int handle(client *c, uint32_t type, const uint8_t *p, uint32_t len)
{
    if (c->stage == 2) {
        if (type != CB_GM_HELLO || len != CB_GM_HELLO_SIZE || cb_gm_rd32(p) != CB_GM_VERSION) {
            violation("first record is not HELLO version 1", 0);
            return -1;
        }
        c->stage = 3;
        return send_caps(c->fd);
    }
    switch (type) {
    case CB_GM_OPEN: {
        if (len != CB_GM_OPEN_SIZE || p[6] != 1 || nstreams == MAX_STREAMS) {
            violation("malformed OPEN", 0);
            return -1;
        }
        uint32_t id = cb_gm_rd32(p);
        stream *s = find(id);
        if (s && s->open)
            violation("OPEN of an open stream", id);
        if (!s)
            s = &streams[nstreams++];
        *s = (stream){ .id = id, .open = 1 };
        uint8_t head[12];
        memcpy(head, p, 4);
        head[4] = p[4];
        head[5] = 0;
        head[6] = p[5];
        head[7] = p[6];
        memcpy(head + 8, p + 8, 4);
        put_msg(CB_MSG_OPEN, head, sizeof(head), NULL, 0);
        return 0;
    }
    case CB_GM_UNIT: {
        if (len < CB_GM_UNIT_HEAD) {
            violation("short UNIT", 0);
            return -1;
        }
        uint32_t id = cb_gm_rd32(p), flags = cb_gm_rd32(p + 12);
        uint64_t serial = cb_gm_rd64(p + 16);
        stream *s = find(id);
        if (!s || !s->open) {
            violation("UNIT of a stream that is not open", id);
            return 0;
        }
        if (!serial)
            violation("UNIT with serial 0", id);
        uint64_t *last = surface_serial(cb_gm_rd32(p + 8));
        if (!(flags & CB_FRAME_REPLAY) && last) {
            if (serial < *last) {
                fprintf(stderr, "cbva-phone: seq %u surface %#x serial %llu after %llu\n", cb_gm_rd32(p + 4),
                        cb_gm_rd32(p + 8), (unsigned long long)serial, (unsigned long long)*last);
                violation("a surface's serials decrease", id);
            }
            *last = serial;
        }
        s->units++;
        total_units++;
        uint8_t head[28] = { 0 };
        memcpy(head, p, 12);  /* stream, seq, surface */
        head[12] = (uint8_t)flags;
        memcpy(head + 24, p + 24, 4); /* w, h */
        put_msg(CB_MSG_FRAME, head, sizeof(head), p + CB_GM_UNIT_HEAD, len - CB_GM_UNIT_HEAD);
        uint8_t reply[8];
        cb_gm_le32(reply, id);
        if (replay_after && !s->replayed && s->units == replay_after) {
            s->replayed = 1;
            if (send_record(c->fd, CB_GM_REPLAY, reply, 4))
                return -1;
        }
        if (fail_after && !s->failed && s->units == fail_after) {
            s->failed = 1;
            cb_gm_le32(reply + 4, CB_GM_FAIL_DECODE);
            if (send_record(c->fd, CB_GM_FAIL, reply, 8))
                return -1;
        }
        return 0;
    }
    case CB_GM_CLOSE: {
        if (len != 4) {
            violation("malformed CLOSE", 0);
            return -1;
        }
        uint32_t id = cb_gm_rd32(p);
        stream *s = find(id);
        if (!s || !s->open)
            violation("CLOSE of a stream that is not open", id);
        else
            s->open = 0;
        uint8_t head[5];
        memcpy(head, p, 4);
        head[4] = 0;
        put_msg(CB_MSG_CLOSE, head, sizeof(head), NULL, 0);
        return 0;
    }
    case CB_GM_SURFACE_GONE:
        if (len != 4) {
            violation("malformed SURFACE_GONE", 0);
            return -1;
        }
        put_msg(CB_MSG_SURFACE_GONE, p, 4, NULL, 0);
        return 0;
    default:
        violation("unknown record", type);
        return -1;
    }
}

static int consume(client *c)
{
    for (;;) {
        if (c->stage == 0) {
            if (c->len < sizeof(broker_hello))
                return 0;
            if (memcmp(c->rx, broker_hello, sizeof(broker_hello))) {
                violation("wrong broker hello", 0);
                return -1;
            }
            if (send_all(c->fd, broker_hello, sizeof(broker_hello)))
                return -1;
            memmove(c->rx, c->rx + 48, c->len -= 48);
            c->stage = 1;
            continue;
        }
        if (c->stage == 1) {
            if (c->len < 4)
                return 0;
            if (cb_gm_rd32(c->rx) != CB_GM_STREAM_FLAGS) {
                violation("stream is not a media stream", 0);
                return -1;
            }
            memmove(c->rx, c->rx + 4, c->len -= 4);
            c->stage = 2;
            continue;
        }
        if (c->len < 8)
            return 0;
        uint32_t type = cb_gm_rd32(c->rx), n = cb_gm_rd32(c->rx + 4);
        if (n > CB_GM_MAX_RECORD) {
            violation("record too long", type);
            return -1;
        }
        if (c->len < 8 + (size_t)n)
            return 0;
        if (handle(c, type, c->rx + 8, n))
            return -1;
        memmove(c->rx, c->rx + 8 + n, c->len - 8 - n);
        c->len -= 8 + n;
    }
}

static void drop(client *c)
{
    close(c->fd);
    free(c->rx);
    *c = (client){ .fd = -1 };
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: cbva-phone SOCKET CAPTURE [--caps all|h264|none] [--fail-after N] [--replay-after N]\n");
        return 2;
    }
    for (int i = 3; i + 1 < argc; i += 2) {
        if (!strcmp(argv[i], "--caps"))
            caps_mode = argv[i + 1];
        else if (!strcmp(argv[i], "--fail-after"))
            fail_after = (unsigned)atoi(argv[i + 1]);
        else if (!strcmp(argv[i], "--replay-after"))
            replay_after = (unsigned)atoi(argv[i + 1]);
    }
    capture = fopen(argv[2], "wb");
    if (!capture) {
        perror(argv[2]);
        return 2;
    }
    int ls = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    struct sockaddr_un addr = { .sun_family = AF_UNIX };
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", argv[1]);
    unlink(argv[1]);
    if (ls < 0 || bind(ls, (struct sockaddr *)&addr, sizeof(addr)) || listen(ls, 8)) {
        perror(argv[1]);
        return 2;
    }
    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);
    signal(SIGPIPE, SIG_IGN);
    for (int i = 0; i < MAX_CLIENTS; i++)
        clients[i].fd = -1;
    while (!done) {
        struct pollfd pfd[MAX_CLIENTS + 1];
        int map[MAX_CLIENTS + 1], n = 0;
        pfd[n] = (struct pollfd){ ls, POLLIN, 0 };
        map[n++] = -1;
        for (int i = 0; i < MAX_CLIENTS; i++)
            if (clients[i].fd >= 0) {
                pfd[n] = (struct pollfd){ clients[i].fd, POLLIN, 0 };
                map[n++] = i;
            }
        if (poll(pfd, (nfds_t)n, 200) < 0 && errno != EINTR)
            break;
        for (int k = 0; k < n; k++) {
            if (!(pfd[k].revents & (POLLIN | POLLHUP | POLLERR)))
                continue;
            if (map[k] < 0) {
                int fd = accept4(ls, NULL, NULL, SOCK_CLOEXEC);
                int slot = -1;
                for (int i = 0; i < MAX_CLIENTS && slot < 0; i++)
                    if (clients[i].fd < 0)
                        slot = i;
                if (fd >= 0 && slot >= 0) {
                    clients[slot] = (client){ .fd = fd };
                    connections++;
                } else if (fd >= 0) {
                    close(fd);
                }
                continue;
            }
            client *c = &clients[map[k]];
            if (c->len + 65536 > c->cap) {
                size_t cap = c->cap ? c->cap * 2 : 1 << 20;
                while (cap < c->len + 65536)
                    cap *= 2;
                uint8_t *rx = realloc(c->rx, cap);
                if (!rx) {
                    drop(c);
                    continue;
                }
                c->rx = rx;
                c->cap = cap;
            }
            ssize_t got = recv(c->fd, c->rx + c->len, 65536, 0);
            if (got <= 0) {
                if (c->len)
                    violation("connection closed inside a record", 0);
                drop(c);
                continue;
            }
            c->len += (size_t)got;
            if (consume(c))
                drop(c);
        }
    }
    unsigned open = 0;
    for (unsigned i = 0; i < nstreams; i++)
        open += streams[i].open;
    printf("cbva-phone: connections=%u streams=%u open=%u units=%u violations=%u\n", connections, nstreams,
           open, total_units, violations);
    fclose(capture);
    unlink(argv[1]);
    return violations ? 1 : 0;
}
