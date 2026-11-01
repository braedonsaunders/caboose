/* Unit tests for the pure parts: bit I/O and NAL escaping. */
#include "bits.h"

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

int main(void)
{
    test_bits();
    test_escape();
    if (failures) {
        fprintf(stderr, "%d failures\n", failures);
        return 1;
    }
    printf("unit: ok\n");
    return 0;
}
