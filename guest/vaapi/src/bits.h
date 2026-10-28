/* Bit-level reading and writing for the bitstream rebuilders.
 *
 * The writer appends MSB-first into a growable byte buffer. H.264 and HEVC
 * rebuild RBSPs with it and escape them into NAL units with cb_nal_escape();
 * AV1 writes OBUs directly (AV1 has no emulation prevention). */
#ifndef CABOOSE_VA_BITS_H
#define CABOOSE_VA_BITS_H

#include <stddef.h>
#include <stdint.h>

/* A growable byte buffer. Allocation failure is sticky: `oom` is set and every
 * later append is a no-op, so callers check once at the end. */
typedef struct {
    uint8_t *data;
    size_t len, cap;
    int oom;
} cb_buf;

void cb_buf_free(cb_buf *b);
void cb_buf_reset(cb_buf *b);
int cb_buf_reserve(cb_buf *b, size_t extra);
void cb_buf_append(cb_buf *b, const void *p, size_t n);
void cb_buf_u8(cb_buf *b, uint8_t v);
void cb_buf_le16(cb_buf *b, uint16_t v);
void cb_buf_le32(cb_buf *b, uint32_t v);
void cb_buf_le64(cb_buf *b, uint64_t v);

typedef struct {
    cb_buf *out;
    uint64_t acc; /* pending bits, right-aligned */
    unsigned nacc;
    uint64_t bits; /* total bits written */
} cb_bw;

void cb_bw_init(cb_bw *w, cb_buf *out);
void cb_bw_put(cb_bw *w, unsigned nbits, uint64_t v); /* nbits <= 56 */
void cb_bw_flag(cb_bw *w, int v);
void cb_bw_ue(cb_bw *w, uint32_t v);  /* Exp-Golomb ue(v) */
void cb_bw_se(cb_bw *w, int32_t v);   /* Exp-Golomb se(v) */
void cb_bw_leb128(cb_bw *w, uint64_t v); /* byte aligned only */
int cb_bw_aligned(const cb_bw *w);
/* rbsp_trailing_bits(): a one bit, then zero bits to the byte boundary. */
void cb_bw_trailing(cb_bw *w);
/* Zero bits to the byte boundary (AV1 byte_alignment()). */
void cb_bw_align_zero(cb_bw *w);
/* Flushes partial bits (zero padded) into the buffer. */
void cb_bw_flush(cb_bw *w);

typedef struct {
    const uint8_t *data;
    size_t size;  /* bytes */
    size_t pos;   /* bit position */
    int overrun;
} cb_br;

void cb_br_init(cb_br *r, const uint8_t *data, size_t size);
uint32_t cb_br_get(cb_br *r, unsigned nbits); /* nbits <= 32 */
int cb_br_flag(cb_br *r);
uint32_t cb_br_ue(cb_br *r);
int32_t cb_br_se(cb_br *r);
size_t cb_br_left(const cb_br *r);

/* Escapes an RBSP into NAL payload bytes (inserts emulation_prevention_three_byte),
 * appending to `out`. */
void cb_nal_escape(cb_buf *out, const uint8_t *rbsp, size_t n);
/* Removes emulation prevention bytes. Returns the RBSP length; `out` must hold
 * n bytes. */
size_t cb_nal_unescape(uint8_t *out, const uint8_t *in, size_t n);
/* Number of RBSP bytes that precede escaped offset `off` in `in`. */
size_t cb_nal_rbsp_offset(const uint8_t *in, size_t n, size_t off);

#endif
