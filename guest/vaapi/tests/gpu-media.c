/* Unit tests for gpu_media.h: every encoder against the golden vectors in
 * gpu-media-vectors.txt, the CAPS parser, and the surface identity record
 * (layout, validation, the sequence lock under a concurrent writer).
 *
 *   build/gpu-media tests/gpu-media-vectors.txt */
#include "gpu_media.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;
#define CHECK(c)                                                         \
    do {                                                                 \
        if (!(c)) {                                                      \
            fprintf(stderr, "%s:%d: CHECK(%s)\n", __FILE__, __LINE__, #c); \
            failures++;                                                  \
        }                                                                \
    } while (0)

typedef struct {
    char name[64];
    uint8_t bytes[512];
    size_t len;
} vector;

static vector vectors[64];
static unsigned nvectors;

static int hexval(int c) { return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : -1; }

static void load(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) {
        perror(path);
        exit(2);
    }
    char line[2048];
    while (fgets(line, sizeof(line), f)) {
        if (line[0] == '#' || line[0] == '\n')
            continue;
        vector *v = &vectors[nvectors++];
        char hex[1500];
        if (sscanf(line, "%63s %1499s", v->name, hex) != 2) {
            fprintf(stderr, "bad vector line: %s", line);
            exit(2);
        }
        for (size_t i = 0; hex[2 * i] && hex[2 * i + 1]; i++)
            v->bytes[v->len++] = (uint8_t)(hexval(hex[2 * i]) << 4 | hexval(hex[2 * i + 1]));
    }
    fclose(f);
}

static const vector *get(const char *name)
{
    for (unsigned i = 0; i < nvectors; i++)
        if (!strcmp(vectors[i].name, name))
            return &vectors[i];
    fprintf(stderr, "missing vector %s\n", name);
    exit(2);
}

/* Builds a record (header + payload) and compares it with a vector. */
static void check_record(const char *name, uint32_t type, const uint8_t *head, size_t head_len,
                         const uint8_t *data, size_t len)
{
    uint8_t out[512];
    cb_gm_record_head(out, type, (uint32_t)(head_len + len));
    memcpy(out + 8, head, head_len);
    if (len)
        memcpy(out + 8 + head_len, data, len);
    const vector *v = get(name);
    CHECK(v->len == 8 + head_len + len);
    CHECK(!memcmp(v->bytes, out, v->len));
}

static const uint8_t token[16] = { 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
                                   0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f };

static void test_records(void)
{
    uint8_t flags[4];
    cb_gm_le32(flags, CB_GM_STREAM_FLAGS);
    CHECK(get("stream-flags")->len == 4 && !memcmp(get("stream-flags")->bytes, flags, 4));

    uint8_t hello[CB_GM_HELLO_SIZE];
    cb_gm_encode_hello(hello, token);
    check_record("hello", CB_GM_HELLO, hello, sizeof(hello), NULL, 0);

    uint8_t open[CB_GM_OPEN_SIZE];
    cb_gm_encode_open(open, 7, 1, 8, 1920, 1088);
    check_record("open-h264-1080p", CB_GM_OPEN, open, sizeof(open), NULL, 0);
    cb_gm_encode_open(open, 9, 4, 10, 3840, 2160);
    check_record("open-av1-10bit", CB_GM_OPEN, open, sizeof(open), NULL, 0);

    uint8_t unit[CB_GM_UNIT_HEAD];
    static const uint8_t idr[] = { 0, 0, 0, 1, 0x65, 0x88, 0x84, 0x00 };
    cb_gm_encode_unit(unit, 7, 0, 0x03000002, 1, 41, 1920, 1088);
    check_record("unit-key", CB_GM_UNIT, unit, sizeof(unit), idr, sizeof(idr));
    static const uint8_t tiny[] = { 0x12, 0x00 };
    cb_gm_encode_unit(unit, 9, 12, 0x03000005, 6, 0x0102030405060708ull, 3840, 2160);
    check_record("unit-hidden-replay", CB_GM_UNIT, unit, sizeof(unit), tiny, sizeof(tiny));

    uint8_t word[4];
    cb_gm_le32(word, 7);
    check_record("close", CB_GM_CLOSE, word, 4, NULL, 0);
    cb_gm_le32(word, 0x03000002);
    check_record("surface-gone", CB_GM_SURFACE_GONE, word, 4, NULL, 0);
}

static void test_caps(void)
{
    const vector *v = get("caps");
    CHECK(cb_gm_rd32(v->bytes) == CB_GM_CAPS && cb_gm_rd32(v->bytes + 4) == v->len - 8);
    cb_gm_cap caps[CB_GM_MAX_CAPS];
    int n = cb_gm_parse_caps(v->bytes + 8, v->len - 8, caps, CB_GM_MAX_CAPS);
    CHECK(n == 3);
    CHECK(caps[0].codec == 1 && caps[0].max_depth == 8 && caps[0].max_width == 4096 && caps[0].max_height == 2304);
    CHECK(caps[1].codec == 2 && caps[1].max_depth == 10 && caps[1].max_width == 8192 && caps[1].max_height == 4320);
    CHECK(caps[2].codec == 4 && caps[2].max_depth == 10 && caps[2].max_height == 4352);
    const vector *e = get("caps-empty");
    CHECK(cb_gm_parse_caps(e->bytes + 8, e->len - 8, caps, CB_GM_MAX_CAPS) == 0);
    /* Wrong version, truncated entries, a count past the limit, nonzero padding. */
    uint8_t bad[8 + 17 * CB_GM_CAPS_ENTRY];
    memcpy(bad, v->bytes + 8, v->len - 8);
    bad[0] = 2;
    CHECK(cb_gm_parse_caps(bad, v->len - 8, caps, CB_GM_MAX_CAPS) < 0);
    CHECK(cb_gm_parse_caps(v->bytes + 8, v->len - 9, caps, CB_GM_MAX_CAPS) < 0);
    memset(bad, 0, sizeof(bad));
    cb_gm_le32(bad, CB_GM_VERSION);
    cb_gm_le32(bad + 4, 17);
    CHECK(cb_gm_parse_caps(bad, sizeof(bad), caps, CB_GM_MAX_CAPS) < 0);
    memcpy(bad, v->bytes + 8, v->len - 8);
    bad[8 + 2] = 1;
    CHECK(cb_gm_parse_caps(bad, v->len - 8, caps, CB_GM_MAX_CAPS) < 0);
    /* A smaller output keeps the first entries. */
    CHECK(cb_gm_parse_caps(v->bytes + 8, v->len - 8, caps, 1) == 1 && caps[0].codec == 1);
}

#define SURFACE (2048u * 1088u * 3u / 2u + 4096u + CB_GM_IDENTITY_PAGE)
static uint8_t *surface_map;

static void test_identity_layout(void)
{
    size_t size = (SURFACE + 4095) / 4096 * 4096;
    surface_map = calloc(1, size);
    cb_gm_identity_page *p = cb_gm_identity_at(surface_map, size);
    CHECK(p && (uint8_t *)p == surface_map + size - CB_GM_IDENTITY_PAGE);
    CHECK(cb_gm_identity_at(surface_map, size - 1) == NULL);
    cb_gm_identity v = { .state = CB_GM_PHONE, .serial = 41, .surface = 0x03000002, .fourcc = CB_GM_FOURCC_NV12,
                         .width = 1920, .height = 1080, .pitch = 2048, .uv_offset = 2048 * 1088 };
    memcpy(v.token, token, 16);
    /* Two writes from a zeroed page leave sequence 4, as in the vector. */
    cb_gm_identity_write(p, &v);
    cb_gm_identity_write(p, &v);
    const vector *vec = get("identity-phone-nv12-1080p");
    CHECK(vec->len == 64 && !memcmp(vec->bytes, p, 64));
    cb_gm_identity r;
    CHECK(cb_gm_identity_read(p, size, &r) == 1);
    CHECK(r.state == CB_GM_PHONE && r.serial == 41 && r.surface == 0x03000002 && !memcmp(r.token, token, 16));
    CHECK(r.width == 1920 && r.height == 1080 && r.pitch == 2048 && r.uv_offset == 2048u * 1088u);

    /* The P010 vector decodes too (a 720p surface large enough for it). */
    const vector *p010 = get("identity-pixels-p010-720p");
    size_t small = 2560u * 736u * 3u / 2u;
    small = (small + 4095) / 4096 * 4096 + CB_GM_IDENTITY_PAGE;
    uint8_t *m = calloc(1, small);
    memcpy(m + small - CB_GM_IDENTITY_PAGE, p010->bytes, 64);
    CHECK(cb_gm_identity_read(cb_gm_identity_at(m, small), small, &r) == 1);
    CHECK(r.state == CB_GM_PIXELS && r.fourcc == CB_GM_FOURCC_P010 && r.serial == 42 && r.width == 1280);
    /* Planes that do not fit the buffer, a pitch narrower than a row, no magic, a
     * zero serial, an odd (in progress) sequence: all rejected. */
    CHECK(cb_gm_identity_read(cb_gm_identity_at(m, small), small - 4096 * 64, &r) == 0);
    cb_gm_identity_page *q = cb_gm_identity_at(m, small);
    q->pitch = 1000;
    CHECK(cb_gm_identity_read(q, small, &r) == 0);
    memcpy(q, p010->bytes, 64);
    q->magic[0] = 'X';
    CHECK(cb_gm_identity_read(q, small, &r) == 0);
    memcpy(q, p010->bytes, 64);
    q->serial = 0;
    CHECK(cb_gm_identity_read(q, small, &r) == 0);
    memcpy(q, p010->bytes, 64);
    q->sequence = 11;
    CHECK(cb_gm_identity_read(q, small, &r) == 0);
    /* An empty record needs no geometry. */
    cb_gm_identity empty = { .state = CB_GM_EMPTY };
    cb_gm_identity_write(q, &empty);
    CHECK(cb_gm_identity_read(q, small, &r) == 1 && r.state == CB_GM_EMPTY);
    free(m);
}

/* A reader never sees a record mixed from two writes. */
static volatile int stop_writer;

static void *writer(void *arg)
{
    cb_gm_identity_page *p = arg;
    cb_gm_identity v = { .state = CB_GM_PHONE, .fourcc = CB_GM_FOURCC_NV12, .width = 1920, .height = 1080,
                         .pitch = 2048, .uv_offset = 2048 * 1088 };
    for (uint64_t n = 1; !stop_writer; n++) {
        v.serial = n;
        v.surface = (uint32_t)n;           /* must always equal the serial's low word */
        memset(v.token, (int)(n & 0xff), 16); /* and so must every token byte */
        cb_gm_identity_write(p, &v);
    }
    return NULL;
}

static void test_identity_concurrency(void)
{
    size_t size = (SURFACE + 4095) / 4096 * 4096;
    cb_gm_identity_page *p = cb_gm_identity_at(surface_map, size);
    cb_gm_identity empty = { .state = CB_GM_EMPTY };
    cb_gm_identity_write(p, &empty); /* only the writer's records are PHONE */
    pthread_t t;
    stop_writer = 0;
    pthread_create(&t, NULL, writer, p);
    unsigned reads = 0, torn = 0;
    uint64_t last = 0;
    for (int i = 0; i < 2000000; i++) {
        cb_gm_identity r;
        if (!cb_gm_identity_read(p, size, &r) || r.state != CB_GM_PHONE)
            continue;
        reads++;
        int ok = r.surface == (uint32_t)r.serial && r.serial >= last;
        for (int k = 0; k < 16; k++)
            ok &= r.token[k] == (uint8_t)(r.serial & 0xff);
        torn += !ok;
        last = r.serial;
    }
    stop_writer = 1;
    pthread_join(t, NULL);
    CHECK(reads > 0);
    CHECK(torn == 0);
    printf("identity: %u consistent reads under a concurrent writer, %u torn\n", reads, torn);
}

int main(int argc, char **argv)
{
    load(argc > 1 ? argv[1] : "tests/gpu-media-vectors.txt");
    test_records();
    test_caps();
    test_identity_layout();
    test_identity_concurrency();
    free(surface_map);
    if (failures) {
        fprintf(stderr, "gpu-media: %d failures\n", failures);
        return 1;
    }
    printf("gpu-media: all checks passed (%u vectors)\n", nvectors);
    return 0;
}
