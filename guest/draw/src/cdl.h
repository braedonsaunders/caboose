/*
 * Caboose draw lists (CDL): the wire format of recorded 2D drawing.
 *
 * A stream is a sequence of ops, each `op: u8, len: u32 LE, payload[len]`, so a reader
 * skips ops it does not know. Everything is little-endian; coordinates and colours are
 * IEEE-754 f32. The format is specified in docs/draw.md; this header is its C writer and
 * the constants every reader shares. Self-contained: no cairo, no libc beyond string.h.
 */
#ifndef CABOOSE_CDL_H
#define CABOOSE_CDL_H

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

enum cdl_op {
    CDL_SURFACE = 0x01,     /* u32 id, u32 w, u32 h, u8 kind (enum cdl_surface_kind) */
    CDL_FREE = 0x02,        /* u32 id */
    CDL_TARGET = 0x03,      /* u32 id: the surface later drawing ops draw into */
    CDL_CLIP = 0x04,        /* u32 n, n × clip item; n = 0 is no clip */
    CDL_FILL = 0x05,        /* u8 operator, u8 rule, u8 aa, matrix, source, path */
    CDL_STROKE = 0x06,      /* u8 operator, u8 aa, matrix, f32 width, u8 cap, u8 join, f32 miter,
                               u32 ndash, f32 dash_offset, f32 dashes[ndash], source, path */
    CDL_PAINT = 0x07,       /* u8 operator, f32 alpha, matrix, source */
    CDL_MASK = 0x08,        /* u8 operator, matrix, source, mask source */
    CDL_GLYPHS = 0x09,      /* u8 operator, matrix, font matrix, u64 font, source,
                               u32 n, n × (u32 glyph, f32 x, f32 y) */
    CDL_UNSUPPORTED = 0x0A, /* u32 reason, f32 x, y, w, h: device-space bounds drawn without a record */
    CDL_IMAGE = 0x20,       /* u64 hash, u32 w, u32 h, u8 format (0 = premultiplied RGBA8), pixels */
    CDL_GLYPH = 0x21,       /* u64 font, u32 glyph, path (em units, y down) */
    CDL_PRESENT = 0x30,     /* u32 surface, u32 wl_surface, u32 wl_buffer, u8 complete: a window
                               buffer was committed; complete when the stream holds all of it */
    CDL_PIXELS = 0x31,      /* u32 surface, u32 w, u32 h: premultiplied RGBA8 the app really drew */
    CDL_BEGIN = 0x32,       /* u32 generation: a fresh recording; nothing before it is referred to */
};

enum cdl_surface_kind {
    CDL_SURFACE_CLEAR = 0,   /* created transparent: its content is exactly its recorded ops */
    CDL_SURFACE_WINDOW = 1,  /* a window's wl_shm buffer: created transparent, shown by PRESENT */
    CDL_SURFACE_UNKNOWN = 2, /* drawn into without knowing what was there (an X11 window) */
};

enum cdl_source_kind {
    CDL_SOURCE_SOLID = 0,   /* f32 r, g, b, a (not premultiplied) */
    CDL_SOURCE_LINEAR = 1,  /* f32 x0, y0, x1, y1, u8 extend, matrix, stops */
    CDL_SOURCE_RADIAL = 2,  /* f32 cx0, cy0, r0, cx1, cy1, r1, u8 extend, matrix, stops */
    CDL_SOURCE_SURFACE = 3, /* u32 surface, u8 extend, u8 filter, matrix */
    CDL_SOURCE_IMAGE = 4,   /* u64 image, u8 extend, u8 filter, matrix */
};

enum cdl_clip_kind {
    CDL_CLIP_RECT = 0,      /* f32 x, y, w, h in device space */
    CDL_CLIP_PATH = 1,      /* matrix, u8 rule, u8 aa, path */
};

enum cdl_verb {
    CDL_MOVE = 0,           /* 1 point */
    CDL_LINE = 1,           /* 1 point */
    CDL_QUAD = 2,           /* 2 points */
    CDL_CUBIC = 3,          /* 3 points */
    CDL_CLOSE = 4,          /* 0 points */
};

enum cdl_unsupported {
    CDL_UNSUPPORTED_SOURCE = 1,     /* a mesh or raster-source pattern */
    CDL_UNSUPPORTED_SURFACE = 2,    /* a source surface whose pixels could not be read */
    CDL_UNSUPPORTED_GLYPHS = 3,     /* glyphs without outlines (colour glyphs) */
};

/* Matrices are cairo's six numbers (xx, yx, xy, yy, x0, y0). An op's matrix maps user space
 * to the target surface's pixels. A source's matrix is cairo's pattern matrix: user space to
 * pattern space. A font matrix maps em units to user space. Stops: u32 n, n × f32 offset, r, g,
 * b, a. Paths: u32 nverbs, u32 npoints, verbs[nverbs], points[npoints] × (f32 x, f32 y).
 * Operators, extend, filter, fill rule, antialias, cap and join are cairo's enum values. */

typedef struct {
    uint8_t *data;
    size_t len;
    size_t cap;
    int failed;
} cdl_buf;

static inline void cdl_reserve(cdl_buf *b, size_t extra) {
    if (b->failed || b->len + extra <= b->cap) return;
    size_t cap = b->cap ? b->cap : 4096;
    while (cap < b->len + extra) cap *= 2;
    uint8_t *data = (uint8_t *)realloc(b->data, cap);
    if (!data) {
        b->failed = 1;
        return;
    }
    b->data = data;
    b->cap = cap;
}

static inline void cdl_bytes(cdl_buf *b, const void *p, size_t n) {
    cdl_reserve(b, n);
    if (b->failed) return;
    memcpy(b->data + b->len, p, n);
    b->len += n;
}

static inline void cdl_u8(cdl_buf *b, uint8_t v) { cdl_bytes(b, &v, 1); }

static inline void cdl_u32(cdl_buf *b, uint32_t v) {
    uint8_t le[4] = {(uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16), (uint8_t)(v >> 24)};
    cdl_bytes(b, le, 4);
}

static inline void cdl_u64(cdl_buf *b, uint64_t v) {
    cdl_u32(b, (uint32_t)v);
    cdl_u32(b, (uint32_t)(v >> 32));
}

static inline void cdl_f32(cdl_buf *b, double v) {
    float f = (float)v;
    uint32_t u;
    memcpy(&u, &f, 4);
    cdl_u32(b, u);
}

/* Starts an op; returns the offset to pass to cdl_end. */
static inline size_t cdl_begin(cdl_buf *b, uint8_t op) {
    cdl_u8(b, op);
    size_t at = b->len;
    cdl_u32(b, 0);
    return at;
}

static inline void cdl_end(cdl_buf *b, size_t at) {
    if (b->failed) return;
    uint32_t n = (uint32_t)(b->len - at - 4);
    uint8_t le[4] = {(uint8_t)n, (uint8_t)(n >> 8), (uint8_t)(n >> 16), (uint8_t)(n >> 24)};
    memcpy(b->data + at, le, 4);
}

/* XXH64 (seed 0 in Caboose), matching caboose-display-protocol's xxh64. */
static inline uint64_t cdl_rotl64(uint64_t x, int r) { return (x << r) | (x >> (64 - r)); }

static inline uint64_t cdl_read64(const uint8_t *p) {
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) v = (v << 8) | p[i];
    return v;
}

static inline uint32_t cdl_read32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static inline uint64_t cdl_xxh64(const void *input, size_t len, uint64_t seed) {
    const uint64_t P1 = 11400714785074694791ULL, P2 = 14029467366897019727ULL, P3 = 1609587929392839161ULL,
                   P4 = 9650029242287828579ULL, P5 = 2870177450012600261ULL;
    const uint8_t *p = (const uint8_t *)input, *end = p + len;
    uint64_t h;
    if (len >= 32) {
        uint64_t v1 = seed + P1 + P2, v2 = seed + P2, v3 = seed, v4 = seed - P1;
        const uint8_t *limit = end - 32;
        do {
            v1 = cdl_rotl64(v1 + cdl_read64(p) * P2, 31) * P1; p += 8;
            v2 = cdl_rotl64(v2 + cdl_read64(p) * P2, 31) * P1; p += 8;
            v3 = cdl_rotl64(v3 + cdl_read64(p) * P2, 31) * P1; p += 8;
            v4 = cdl_rotl64(v4 + cdl_read64(p) * P2, 31) * P1; p += 8;
        } while (p <= limit);
        h = cdl_rotl64(v1, 1) + cdl_rotl64(v2, 7) + cdl_rotl64(v3, 12) + cdl_rotl64(v4, 18);
        uint64_t vs[4] = {v1, v2, v3, v4};
        for (int i = 0; i < 4; i++) {
            h ^= cdl_rotl64(vs[i] * P2, 31) * P1;
            h = h * P1 + P4;
        }
    } else {
        h = seed + P5;
    }
    h += (uint64_t)len;
    while (p + 8 <= end) {
        h ^= cdl_rotl64(cdl_read64(p) * P2, 31) * P1;
        h = cdl_rotl64(h, 27) * P1 + P4;
        p += 8;
    }
    if (p + 4 <= end) {
        h ^= (uint64_t)cdl_read32(p) * P1;
        h = cdl_rotl64(h, 23) * P2 + P3;
        p += 4;
    }
    while (p < end) {
        h ^= (*p) * P5;
        h = cdl_rotl64(h, 11) * P1;
        p++;
    }
    h ^= h >> 33;
    h *= P2;
    h ^= h >> 29;
    h *= P3;
    h ^= h >> 32;
    return h;
}

#endif
