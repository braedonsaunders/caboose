/* Unit tests for the pure parts: bit I/O, NAL escaping, the marker code and the
 * reference detector (against synthetic screens: scaled, stretched, cropped,
 * colour-converted, over busy backgrounds). */
#include "bits.h"
#include "marker.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;
#define CHECK(cond, ...)                                                                                     \
    do {                                                                                                     \
        if (!(cond)) {                                                                                       \
            failures++;                                                                                      \
            fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__);                                             \
            fprintf(stderr, __VA_ARGS__);                                                                    \
            fprintf(stderr, "\n");                                                                           \
        }                                                                                                    \
    } while (0)

static uint32_t rng = 12345;
static uint32_t rnd(void)
{
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
}

static void test_bits(void)
{
    cb_buf b = { 0 };
    cb_bw w;
    cb_bw_init(&w, &b);
    for (uint32_t v = 0; v < 2000; v++)
        cb_bw_ue(&w, v * 37);
    for (int32_t v = -1000; v < 1000; v++)
        cb_bw_se(&w, v * 13);
    cb_bw_put(&w, 7, 0x55);
    cb_bw_ue(&w, 0xfffffffe);
    cb_bw_trailing(&w);
    cb_br r;
    cb_br_init(&r, b.data, b.len);
    for (uint32_t v = 0; v < 2000; v++)
        CHECK(cb_br_ue(&r) == v * 37, "ue %u", v * 37);
    for (int32_t v = -1000; v < 1000; v++)
        CHECK(cb_br_se(&r) == v * 13, "se %d", v * 13);
    CHECK(cb_br_get(&r, 7) == 0x55, "u7");
    CHECK(cb_br_ue(&r) == 0xfffffffe, "ue max");
    CHECK(cb_br_get(&r, 1) == 1, "trailing one");
    CHECK(!r.overrun, "overrun");
    CHECK(cb_br_left(&r) < 8, "trailing alignment");

    cb_buf_reset(&b);
    cb_bw_init(&w, &b);
    cb_bw_leb128(&w, 300);
    CHECK(b.len == 2 && b.data[0] == 0xac && b.data[1] == 0x02, "leb128 300");
    cb_buf_free(&b);
}

static void test_escape(void)
{
    for (int round = 0; round < 200; round++) {
        size_t n = rnd() % 300;
        uint8_t in[300], back[600];
        for (size_t i = 0; i < n; i++)
            in[i] = (rnd() % 3) ? 0 : (uint8_t)(rnd() % 5);
        cb_buf e = { 0 };
        cb_nal_escape(&e, in, n);
        /* No start code emulation in the escaped bytes. */
        for (size_t i = 0; i + 2 < e.len; i++)
            CHECK(!(e.data[i] == 0 && e.data[i + 1] == 0 && e.data[i + 2] <= 2), "emulation at %zu", i);
        size_t m = cb_nal_unescape(back, e.data, e.len);
        CHECK(m == n && (!n || memcmp(back, in, n) == 0), "escape round trip %d", round);
        CHECK(cb_nal_rbsp_offset(e.data, e.len, e.len) == n, "rbsp offset");
        cb_buf_free(&e);
    }
}

static void test_crc(void)
{
    for (uint32_t d = 0; d < (1u << 18); d += 7) {
        uint8_t c = cb_mark_crc7(d);
        for (int bit = 0; bit < 18; bit++)
            CHECK(cb_mark_crc7(d ^ (1u << bit)) != c, "crc misses a flip of bit %d in %u", bit, d);
    }
    uint32_t p = cb_mark_payload(5, 2, 33, 41);
    CHECK((p & 7) == 5 && ((p >> 3) & 7) == 2 && ((p >> 6) & 63) == 33 && ((p >> 12) & 63) == 41, "payload");
}

/* A screen: background, then the marked frame (coded cw x ch) scaled into rect
 * (dx, dy, dw, dh), clipped to (clip...), through a limited->full range conversion. */
typedef struct {
    unsigned w, h;
    uint8_t *px;
} screen_t;

static void paint_screen(screen_t *s, const uint8_t *luma, unsigned cw, unsigned ch, double dx, double dy,
                         double dw, double dh, int cx0, int cy0, int cx1, int cy1, int full_range)
{
    for (unsigned y = 0; y < s->h; y++)
        for (unsigned x = 0; x < s->w; x++)
            s->px[y * s->w + x] = (uint8_t)((x / 7 + y / 5) % 2 ? 200 : (rnd() & 0xff));
    for (int y = cy0; y < cy1; y++) {
        for (int x = cx0; x < cx1; x++) {
            double fx = (x + 0.5 - dx) * cw / dw - 0.5, fy = (y + 0.5 - dy) * ch / dh - 0.5;
            if (fx < 0) fx = 0;
            if (fy < 0) fy = 0;
            if (fx > cw - 1) fx = cw - 1;
            if (fy > ch - 1) fy = ch - 1;
            int x0 = (int)fx, y0 = (int)fy;
            int x1 = x0 + 1 < (int)cw ? x0 + 1 : x0, y1 = y0 + 1 < (int)ch ? y0 + 1 : y0;
            double ax = fx - x0, ay = fy - y0;
            double v = (1 - ay) * ((1 - ax) * luma[y0 * cw + x0] + ax * luma[y0 * cw + x1]) +
                       ay * ((1 - ax) * luma[y1 * cw + x0] + ax * luma[y1 * cw + x1]);
            if (!full_range)
                v = (v - 16) * 255.0 / 219.0;
            v += (rnd() % 3) - 1.0; /* dither */
            s->px[y * s->w + x] = (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v + 0.5);
        }
    }
}

static void detect_case(const char *name, unsigned cw, unsigned ch, unsigned sw, unsigned sh, double dx,
                        double dy, double dw, double dh, int cx0, int cy0, int cx1, int cy1, int full)
{
    uint8_t *luma = malloc((size_t)cw * ch);
    screen_t s = { sw, sh, malloc((size_t)sw * sh) };
    memset(luma, 0, (size_t)cw * ch);
    cb_mark_paint(luma, cw, cw, ch, 1, 9, 63, -1);
    /* Repaint for a later frame through the incremental path. */
    cb_mark_paint(luma, cw, cw, ch, 1, 21, 37, 9 << 6 | 63);
    paint_screen(&s, luma, cw, ch, dx, dy, dw, dh, cx0, cy0, cx1, cy1, full);
    cb_mark_hit hits[4];
    int n = (int)cb_mark_detect(s.px, sw, sh, sw, hits, 4);
    CHECK(n == 1, "%s: %d hits", name, n);
    if (n >= 1) {
        cb_mark_hit *h = &hits[0];
        double tol = 1.0 + dw / CB_MARK_GRID / 4;
        CHECK(h->tag == 21 && h->seq == 37, "%s: tag %u seq %u", name, h->tag, h->seq);
        CHECK(fabs(h->x - dx) < tol && fabs(h->y - dy) < tol && fabs(h->w - dw) < 2 * tol &&
                  fabs(h->h - dh) < 2 * tol,
              "%s: rect %.1f,%.1f %.1fx%.1f want %.1f,%.1f %.1fx%.1f", name, h->x, h->y, h->w, h->h, dx, dy, dw,
              dh);
        int ctol = 3;
        CHECK(abs(h->clip_x0 - cx0) <= ctol && abs(h->clip_y0 - cy0) <= ctol && abs(h->clip_x1 - cx1) <= ctol &&
                  abs(h->clip_y1 - cy1) <= ctol,
              "%s: clip %d,%d-%d,%d want %d,%d-%d,%d", name, h->clip_x0, h->clip_y0, h->clip_x1, h->clip_y1, cx0,
              cy0, cx1, cy1);
        printf("  %-28s tags=%2u rect=%.1f,%.1f %.1fx%.1f clip=%d,%d-%d,%d\n", name, h->tags_found, h->x, h->y,
               h->w, h->h, h->clip_x0, h->clip_y0, h->clip_x1, h->clip_y1);
    }
    free(luma);
    free(s.px);
}

static void test_detect(void)
{
    detect_case("1:1", 640, 360, 900, 600, 100, 80, 640, 360, 100, 80, 740, 440, 0);
    detect_case("1080p shown at 1/3", 1920, 1080, 900, 600, 33, 41, 640, 360, 33, 41, 673, 401, 0);
    detect_case("shown at 1/4.5", 1920, 1080, 900, 600, 10, 10, 1920 / 4.5, 1080 / 4.5, 10, 10, 437, 250, 0);
    detect_case("upscaled 2.3x", 320, 180, 900, 600, 50, 60, 736, 414, 50, 60, 786, 474, 0);
    detect_case("stretched", 640, 480, 900, 600, 20, 30, 853, 480, 20, 30, 873, 510, 0);
    detect_case("full range", 1280, 720, 900, 600, 0, 0, 640, 360, 0, 0, 640, 360, 1);
    /* object-fit: cover, the frame wider than its box */
    detect_case("cropped (cover)", 1280, 720, 900, 600, -200, 40, 1066.7, 600, 0, 40, 667, 600, 0);
    /* 1920x1088 coded, the app shows the top 1080 rows */
    detect_case("1088 coded, 1080 shown", 1920, 1088, 900, 600, 30, 20, 640, 362.7, 30, 20, 670, 380, 0);

    /* The same frame twice (a video mirrored into a canvas): two hits. */
    {
        unsigned cw = 640, ch = 360, sw = 1000, sh = 400;
        uint8_t *luma = calloc((size_t)cw * ch, 1);
        screen_t s2 = { sw, sh, malloc((size_t)sw * sh) };
        cb_mark_paint(luma, cw, cw, ch, 1, 4, 9, -1);
        paint_screen(&s2, luma, cw, ch, 10, 20, 480, 270, 10, 20, 490, 290, 0);
        /* second copy, smaller, painted over the right side */
        screen_t tmp = { sw, sh, malloc((size_t)sw * sh) };
        paint_screen(&tmp, luma, cw, ch, 560, 60, 320, 180, 560, 60, 880, 240, 0);
        for (unsigned y = 60; y < 240; y++)
            memcpy(s2.px + y * sw + 560, tmp.px + y * sw + 560, 320);
        cb_mark_hit two[4];
        size_t nh = cb_mark_detect(s2.px, sw, sh, sw, two, 4);
        CHECK(nh == 2, "mirrored: %zu hits", nh);
        if (nh == 2) {
            int a = two[0].w > two[1].w ? 0 : 1;
            CHECK(fabs(two[a].w - 480) < 3 && fabs(two[1 - a].w - 320) < 3 && fabs(two[1 - a].x - 560) < 2,
                  "mirrored rects %.1f/%.1f", two[a].w, two[1 - a].w);
        }
        free(luma);
        free(s2.px);
        free(tmp.px);
    }

    /* Noise and plain backgrounds hold no markers. */
    screen_t s = { 800, 600, malloc(800 * 600) };
    for (size_t i = 0; i < 800 * 600; i++)
        s.px[i] = (uint8_t)rnd();
    cb_mark_hit hits[4];
    CHECK(cb_mark_detect(s.px, 800, 600, 800, hits, 4) == 0, "noise");
    for (size_t i = 0; i < 800 * 600; i++)
        s.px[i] = (uint8_t)(((i % 800) / 9 + (i / 800) / 9) % 2 ? 0 : 60);
    CHECK(cb_mark_detect(s.px, 800, 600, 800, hits, 4) == 0, "checkerboard");
    free(s.px);
}

int main(void)
{
    test_bits();
    test_escape();
    test_crc();
    test_detect();
    if (failures) {
        fprintf(stderr, "%d failures\n", failures);
        return 1;
    }
    printf("unit: ok\n");
    return 0;
}
