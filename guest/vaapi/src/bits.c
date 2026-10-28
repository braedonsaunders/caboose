#include "bits.h"

#include <stdlib.h>
#include <string.h>

void cb_buf_free(cb_buf *b)
{
    free(b->data);
    b->data = NULL;
    b->len = b->cap = 0;
    b->oom = 0;
}

void cb_buf_reset(cb_buf *b)
{
    b->len = 0;
    b->oom = 0;
}

int cb_buf_reserve(cb_buf *b, size_t extra)
{
    if (b->oom)
        return -1;
    if (b->len + extra <= b->cap)
        return 0;
    size_t cap = b->cap ? b->cap : 256;
    while (cap < b->len + extra)
        cap *= 2;
    uint8_t *p = realloc(b->data, cap);
    if (!p) {
        b->oom = 1;
        return -1;
    }
    b->data = p;
    b->cap = cap;
    return 0;
}

void cb_buf_append(cb_buf *b, const void *p, size_t n)
{
    if (!n || cb_buf_reserve(b, n))
        return;
    memcpy(b->data + b->len, p, n);
    b->len += n;
}

void cb_buf_u8(cb_buf *b, uint8_t v) { cb_buf_append(b, &v, 1); }

void cb_buf_le16(cb_buf *b, uint16_t v)
{
    uint8_t t[2] = { v & 0xff, v >> 8 };
    cb_buf_append(b, t, 2);
}

void cb_buf_le32(cb_buf *b, uint32_t v)
{
    uint8_t t[4] = { v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, v >> 24 };
    cb_buf_append(b, t, 4);
}

void cb_buf_le64(cb_buf *b, uint64_t v)
{
    cb_buf_le32(b, (uint32_t)v);
    cb_buf_le32(b, (uint32_t)(v >> 32));
}

void cb_bw_init(cb_bw *w, cb_buf *out)
{
    w->out = out;
    w->acc = 0;
    w->nacc = 0;
    w->bits = 0;
}

void cb_bw_put(cb_bw *w, unsigned nbits, uint64_t v)
{
    if (!nbits)
        return;
    if (nbits < 64)
        v &= (1ull << nbits) - 1;
    w->acc = (w->acc << nbits) | v;
    w->nacc += nbits;
    w->bits += nbits;
    while (w->nacc >= 8) {
        w->nacc -= 8;
        cb_buf_u8(w->out, (uint8_t)(w->acc >> w->nacc));
    }
    w->acc &= (1ull << w->nacc) - 1;
}

void cb_bw_flag(cb_bw *w, int v) { cb_bw_put(w, 1, v ? 1 : 0); }

void cb_bw_ue(cb_bw *w, uint32_t v)
{
    uint64_t x = (uint64_t)v + 1;
    unsigned len = 0;
    while ((x >> len) > 1)
        len++;
    cb_bw_put(w, len, 0);
    cb_bw_put(w, len + 1, x);
}

void cb_bw_se(cb_bw *w, int32_t v)
{
    cb_bw_ue(w, v > 0 ? (uint32_t)(2 * (int64_t)v - 1) : (uint32_t)(-2 * (int64_t)v));
}

void cb_bw_leb128(cb_bw *w, uint64_t v)
{
    do {
        uint8_t byte = v & 0x7f;
        v >>= 7;
        cb_bw_put(w, 8, byte | (v ? 0x80 : 0));
    } while (v);
}

int cb_bw_aligned(const cb_bw *w) { return w->nacc == 0; }

void cb_bw_trailing(cb_bw *w)
{
    cb_bw_put(w, 1, 1);
    cb_bw_align_zero(w);
}

void cb_bw_align_zero(cb_bw *w)
{
    if (w->nacc)
        cb_bw_put(w, 8 - w->nacc, 0);
}

void cb_bw_flush(cb_bw *w) { cb_bw_align_zero(w); }

void cb_br_init(cb_br *r, const uint8_t *data, size_t size)
{
    r->data = data;
    r->size = size;
    r->pos = 0;
    r->overrun = 0;
}

uint32_t cb_br_get(cb_br *r, unsigned nbits)
{
    uint32_t v = 0;
    for (unsigned i = 0; i < nbits; i++) {
        size_t byte = r->pos >> 3;
        unsigned bit = 0;
        if (byte < r->size)
            bit = (r->data[byte] >> (7 - (r->pos & 7))) & 1;
        else
            r->overrun = 1;
        v = (v << 1) | bit;
        r->pos++;
    }
    return v;
}

int cb_br_flag(cb_br *r) { return (int)cb_br_get(r, 1); }

uint32_t cb_br_ue(cb_br *r)
{
    unsigned zeros = 0;
    while (!cb_br_get(r, 1)) {
        if (r->overrun || ++zeros > 31) {
            r->overrun = 1;
            return 0;
        }
    }
    if (!zeros)
        return 0;
    return (uint32_t)(((1ull << zeros) - 1) + cb_br_get(r, zeros));
}

int32_t cb_br_se(cb_br *r)
{
    uint32_t k = cb_br_ue(r);
    return (k & 1) ? (int32_t)((k + 1) / 2) : -(int32_t)(k / 2);
}

size_t cb_br_left(const cb_br *r)
{
    size_t total = r->size * 8;
    return r->pos >= total ? 0 : total - r->pos;
}

void cb_nal_escape(cb_buf *out, const uint8_t *rbsp, size_t n)
{
    unsigned zeros = 0;
    if (cb_buf_reserve(out, n + n / 2 + 1))
        return;
    for (size_t i = 0; i < n; i++) {
        if (zeros >= 2 && rbsp[i] <= 3) {
            out->data[out->len++] = 3;
            zeros = 0;
            if (cb_buf_reserve(out, n - i + 1))
                return;
        }
        out->data[out->len++] = rbsp[i];
        zeros = rbsp[i] ? 0 : zeros + 1;
    }
}

size_t cb_nal_unescape(uint8_t *out, const uint8_t *in, size_t n)
{
    size_t o = 0;
    unsigned zeros = 0;
    for (size_t i = 0; i < n; i++) {
        if (zeros >= 2 && in[i] == 3) {
            zeros = 0;
            continue;
        }
        out[o++] = in[i];
        zeros = in[i] ? 0 : zeros + 1;
    }
    return o;
}

size_t cb_nal_rbsp_offset(const uint8_t *in, size_t n, size_t off)
{
    size_t o = 0;
    unsigned zeros = 0;
    for (size_t i = 0; i < n && i < off; i++) {
        if (zeros >= 2 && in[i] == 3) {
            zeros = 0;
            continue;
        }
        o++;
        zeros = in[i] ? 0 : zeros + 1;
    }
    return o;
}
