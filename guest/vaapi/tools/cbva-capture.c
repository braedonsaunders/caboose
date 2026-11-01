/* cbva-capture: splits a capture (proto.h), as tools/cbva-phone writes it, into
 * one elementary stream per VA stream, for tests and debugging.
 *
 *   cbva-capture split CAPTURE PREFIX
 *       Writes PREFIX-<stream>.h264 / .hevc (Annex B) or .ivf (VP9, AV1), and
 *       prints one summary line per stream. */
#include "proto.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
        if (env[0] == CB_CAP_OPEN && len >= 12 && nstreams < 256) {
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
        } else if (env[0] == CB_CAP_FRAME && len >= 28) {
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
        } else if (env[0] == CB_CAP_CLOSE && len >= 5) {
            stream_t *s = find(le32(buf));
            if (s) {
                s->closed = 1;
                s->close_reason = buf[4];
            }
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
    free(buf);
    fclose(in);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc == 4 && !strcmp(argv[1], "split"))
        return split(argv[2], argv[3]);
    fprintf(stderr, "usage: cbva-capture split CAPTURE PREFIX\n");
    return 2;
}
