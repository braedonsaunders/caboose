/* cbva-capture: the receiving end of the Caboose video socket, for tests and
 * debugging.
 *
 *   cbva-capture split CAPTURE PREFIX
 *       Splits a capture (CABOOSE_VA_SINK file, or what `serve` wrote) into one
 *       elementary stream per VA stream: PREFIX-<stream>.h264 / .hevc (Annex B)
 *       or .ivf (VP9, AV1), and prints one summary line per stream.
 *   cbva-capture serve SOCKET CAPTURE [DECODE_AFTER [REPLAY_AFTER]]
 *       Listens like caboose-display: accepts every stream (tags from 0), writes
 *       every message to CAPTURE, asks for a replay after REPLAY_AFTER frames of a
 *       stream, and asks the driver to decode it locally after DECODE_AFTER
 *       frames (0: never). Runs until killed. */
#define _GNU_SOURCE
#include "proto.h"

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static uint32_t le32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint16_t le16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }

typedef struct {
    uint32_t id;
    uint8_t codec;
    FILE *out;
    unsigned frames, keys, hidden, replays, replay_key, w, h;
    uint64_t bytes;
    int closed, close_reason;
} stream_t;

static stream_t streams[256];
static unsigned nstreams;

static stream_t *find(uint32_t id)
{
    for (unsigned i = 0; i < nstreams; i++)
        if (streams[i].id == id)
            return &streams[i];
    return NULL;
}

static void put_le(FILE *f, uint64_t v, int n)
{
    for (int i = 0; i < n; i++)
        fputc((int)(v >> (8 * i)) & 0xff, f);
}

static int split(const char *capture, const char *prefix)
{
    FILE *in = fopen(capture, "rb");
    if (!in) {
        perror(capture);
        return 1;
    }
    uint8_t env[5];
    uint8_t *buf = NULL;
    size_t cap = 0;
    unsigned surfaces = 0;
    while (fread(env, 1, 5, in) == 5) {
        uint32_t len = le32(env + 1);
        if (len > cap) {
            cap = len;
            buf = realloc(buf, cap);
            if (!buf)
                return 1;
        }
        if (len && fread(buf, 1, len, in) != len) {
            fprintf(stderr, "truncated message\n");
            break;
        }
        if (env[0] == CB_MSG_OPEN && len >= 12 && nstreams < 256) {
            stream_t *s = &streams[nstreams++];
            memset(s, 0, sizeof(*s));
            s->id = le32(buf);
            s->codec = buf[4];
            const char *ext = s->codec == CB_CODEC_H264 ? "h264" : s->codec == CB_CODEC_HEVC ? "hevc" : "ivf";
            char path[4096];
            snprintf(path, sizeof(path), "%s-%u.%s", prefix, s->id, ext);
            s->out = fopen(path, "wb");
            if (!s->out) {
                perror(path);
                return 1;
            }
            if (s->codec == CB_CODEC_VP9 || s->codec == CB_CODEC_AV1) {
                fwrite("DKIF", 1, 4, s->out);
                put_le(s->out, 0, 2);
                put_le(s->out, 32, 2);
                fwrite(s->codec == CB_CODEC_VP9 ? "VP90" : "AV01", 1, 4, s->out);
                put_le(s->out, le16(buf + 8), 2);
                put_le(s->out, le16(buf + 10), 2);
                put_le(s->out, 30, 4);
                put_le(s->out, 1, 4);
                put_le(s->out, 0, 4);
                put_le(s->out, 0, 4);
            }
        } else if (env[0] == CB_MSG_FRAME && len >= 28) {
            stream_t *s = find(le32(buf));
            if (!s)
                continue;
            unsigned flags = buf[12];
            if (flags & CB_FRAME_REPLAY) {
                if (!s->replays++)
                    s->replay_key = !!(flags & CB_FRAME_KEY);
                continue;
            }
            const uint8_t *data = buf + 28;
            uint32_t n = len - 28;
            if (s->codec == CB_CODEC_VP9 || s->codec == CB_CODEC_AV1) {
                put_le(s->out, n, 4);
                put_le(s->out, s->frames, 8);
            }
            fwrite(data, 1, n, s->out);
            s->frames++;
            s->keys += !!(flags & CB_FRAME_KEY);
            s->hidden += !!(flags & CB_FRAME_HIDDEN);
            s->bytes += n;
            s->w = le16(buf + 24);
            s->h = le16(buf + 26);
        } else if (env[0] == CB_MSG_CLOSE && len >= 5) {
            stream_t *s = find(le32(buf));
            if (s) {
                s->closed = 1;
                s->close_reason = buf[4];
            }
        } else if (env[0] == CB_MSG_SURFACE) {
            surfaces++;
        }
    }
    for (unsigned i = 0; i < nstreams; i++) {
        stream_t *s = &streams[i];
        printf("stream=%u codec=%u frames=%u keys=%u hidden=%u replays=%u replay_from_key=%u bytes=%llu size=%ux%u "
               "close=%d\n",
               s->id, s->codec, s->frames, s->keys, s->hidden, s->replays, s->replay_key,
               (unsigned long long)s->bytes, s->w, s->h, s->closed ? s->close_reason : -1);
        fclose(s->out);
    }
    printf("surfaces_exported=%u\n", surfaces);
    free(buf);
    fclose(in);
    return 0;
}

typedef struct {
    int fd;
    uint8_t *buf;
    size_t len, cap;
    unsigned frames[256];
    uint32_t ids[256];
    unsigned n;
} client_t;

static void reply(int fd, uint8_t type, uint32_t stream, uint8_t a, uint8_t b, int n)
{
    uint8_t m[11] = { type, (uint8_t)n, 0, 0, 0 };
    memcpy(m + 5, &stream, 4);
    m[9] = a;
    m[10] = b;
    if (write(fd, m, 5 + (size_t)n) < 0)
        perror("reply");
}

static int serve(const char *path, const char *capture, unsigned decode_after, unsigned replay_after)
{
    signal(SIGPIPE, SIG_IGN);
    int ls = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    struct sockaddr_un addr = { .sun_family = AF_UNIX };
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", path);
    unlink(path);
    if (ls < 0 || bind(ls, (struct sockaddr *)&addr, sizeof(addr)) || listen(ls, 16)) {
        perror(path);
        return 1;
    }
    FILE *out = fopen(capture, "wb");
    if (!out) {
        perror(capture);
        return 1;
    }
    setvbuf(out, NULL, _IONBF, 0);
    client_t clients[32];
    unsigned nclients = 0, next_tag = 0;
    for (;;) {
        struct pollfd pfd[33];
        pfd[0] = (struct pollfd){ ls, POLLIN, 0 };
        for (unsigned i = 0; i < nclients; i++)
            pfd[i + 1] = (struct pollfd){ clients[i].fd, POLLIN, 0 };
        if (poll(pfd, nclients + 1, -1) < 0 && errno != EINTR)
            return 1;
        if ((pfd[0].revents & POLLIN) && nclients < 32) {
            int fd = accept4(ls, NULL, NULL, SOCK_CLOEXEC);
            if (fd >= 0)
                clients[nclients++] = (client_t){ .fd = fd };
        }
        for (unsigned i = 0; i < nclients; i++) {
            if (!(pfd[i + 1].revents & (POLLIN | POLLHUP)))
                continue;
            client_t *c = &clients[i];
            if (c->cap - c->len < 65536) {
                c->cap = c->cap ? c->cap * 2 : 1 << 20;
                c->buf = realloc(c->buf, c->cap);
            }
            ssize_t r = read(c->fd, c->buf + c->len, c->cap - c->len);
            if (r <= 0) {
                close(c->fd);
                free(c->buf);
                clients[i] = clients[--nclients];
                i--;
                continue;
            }
            c->len += (size_t)r;
            size_t off = 0;
            while (c->len - off >= 5) {
                uint32_t len = le32(c->buf + off + 1);
                if (c->len - off < 5 + (size_t)len)
                    break;
                uint8_t type = c->buf[off];
                uint8_t *p = c->buf + off + 5;
                fwrite(c->buf + off, 1, 5 + (size_t)len, out);
                if (type == CB_MSG_OPEN && len >= 12) {
                    uint32_t id = le32(p);
                    reply(c->fd, CB_MSG_ACCEPT, id, (uint8_t)(next_tag++ & 63), CB_MODE_PASSTHROUGH, 6);
                    if (c->n < 256) {
                        c->ids[c->n] = id;
                        c->frames[c->n++] = 0;
                    }
                } else if (type == CB_MSG_FRAME && len >= 28) {
                    uint32_t id = le32(p);
                    if (p[12] & CB_FRAME_REPLAY)
                        goto next;
                    for (unsigned k = 0; k < c->n; k++) {
                        if (c->ids[k] != id)
                            continue;
                        c->frames[k]++;
                        if (replay_after && c->frames[k] == replay_after)
                            reply(c->fd, CB_MSG_REPLAY, id, 0, 0, 4);
                        if (decode_after && c->frames[k] == decode_after)
                            reply(c->fd, CB_MSG_DECODE, id, CB_CLOSE_REQUESTED, 0, 5);
                    }
                }
            next:
                off += 5 + (size_t)len;
            }
            memmove(c->buf, c->buf + off, c->len - off);
            c->len -= off;
        }
    }
}

int main(int argc, char **argv)
{
    if (argc == 4 && !strcmp(argv[1], "split"))
        return split(argv[2], argv[3]);
    if (argc >= 4 && argc <= 6 && !strcmp(argv[1], "serve"))
        return serve(argv[2], argv[3], argc >= 5 ? (unsigned)atoi(argv[4]) : 0,
                     argc >= 6 ? (unsigned)atoi(argv[5]) : 0);
    fprintf(stderr, "usage: cbva-capture split CAPTURE PREFIX | serve SOCKET CAPTURE [DECODE_AFTER [REPLAY_AFTER]]\n");
    return 2;
}
