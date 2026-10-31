/*
 * scene_wire.h — Self-contained C11 wire encoder, xxHash64, and non-blocking
 * IPC client for the Caboose OS Decomposition Scene Graph Lane (0x25 / 0x26 / 0x9A).
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef CABOOSE_SCENE_WIRE_H
#define CABOOSE_SCENE_WIRE_H

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ========================================================================== *
 * Wire Message Types & Constants                                             *
 * ========================================================================== */

#define CB_MSG_SCENE_FONT   0x25u
#define CB_MSG_SCENE_COMMIT 0x26u
#define CB_MSG_SCENE_SCROLL 0x9Au

#define CB_FRAME_HEADER_LEN 5u
#define CB_GLYPH_RECORD_LEN 10u

/* Path binary stream verbs */
#define CB_PATH_VERB_MOVE_TO  0x01u
#define CB_PATH_VERB_LINE_TO  0x02u
#define CB_PATH_VERB_QUAD_TO  0x03u
#define CB_PATH_VERB_CUBIC_TO 0x04u
#define CB_PATH_VERB_CLOSE    0x05u

/* ========================================================================== *
 * 1. Standard 64-bit xxHash (xxh64)                                          *
 *    Matches caboose-display-protocol::xxh64                                 *
 *    Test vector: cb_xxh64("", 0, 0) == 0xEF46DB3751D8E999ULL                *
 * ========================================================================== */

#define CB_XXH_PRIME64_1 0x9E3779B185EBCA87ULL
#define CB_XXH_PRIME64_2 0xC2B2AE3D27D4EB4FULL
#define CB_XXH_PRIME64_3 0x165667B19E3779F9ULL
#define CB_XXH_PRIME64_4 0x85EBCA77C2B2AE63ULL
#define CB_XXH_PRIME64_5 0x27D4EB2F165667C5ULL

static inline uint64_t cb_rotl64(uint64_t x, int r) {
    return (x << r) | (x >> (64 - r));
}

static inline uint64_t cb_read_le64(const uint8_t *p) {
    return (uint64_t)p[0]
         | ((uint64_t)p[1] << 8)
         | ((uint64_t)p[2] << 16)
         | ((uint64_t)p[3] << 24)
         | ((uint64_t)p[4] << 32)
         | ((uint64_t)p[5] << 40)
         | ((uint64_t)p[6] << 48)
         | ((uint64_t)p[7] << 56);
}

static inline uint32_t cb_read_le32(const uint8_t *p) {
    return (uint32_t)p[0]
         | ((uint32_t)p[1] << 8)
         | ((uint32_t)p[2] << 16)
         | ((uint32_t)p[3] << 24);
}

static inline void cb_write_le16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v & 0xFFu);
    p[1] = (uint8_t)((v >> 8) & 0xFFu);
}

static inline void cb_write_le32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v & 0xFFu);
    p[1] = (uint8_t)((v >> 8) & 0xFFu);
    p[2] = (uint8_t)((v >> 16) & 0xFFu);
    p[3] = (uint8_t)((v >> 24) & 0xFFu);
}

static inline void cb_write_le_f32(uint8_t *p, float f) {
    uint32_t bits = 0;
    memcpy(&bits, &f, sizeof(bits));
    cb_write_le32(p, bits);
}

static inline uint64_t cb_xxh64_round(uint64_t acc, uint64_t input) {
    acc += input * CB_XXH_PRIME64_2;
    acc = cb_rotl64(acc, 31);
    acc *= CB_XXH_PRIME64_1;
    return acc;
}

static inline uint64_t cb_xxh64_merge_round(uint64_t acc, uint64_t val) {
    val = cb_xxh64_round(0, val);
    acc ^= val;
    acc = acc * CB_XXH_PRIME64_1 + CB_XXH_PRIME64_4;
    return acc;
}

static inline uint64_t cb_xxh64(const void *data, size_t len, uint64_t seed) {
    const uint8_t *p = (const uint8_t *)data;
    const uint8_t *const b_end = p + len;
    uint64_t h64;

    if (len >= 32) {
        const uint8_t *const limit = b_end - 32;
        uint64_t v1 = seed + CB_XXH_PRIME64_1 + CB_XXH_PRIME64_2;
        uint64_t v2 = seed + CB_XXH_PRIME64_2;
        uint64_t v3 = seed + 0;
        uint64_t v4 = seed - CB_XXH_PRIME64_1;

        do {
            v1 = cb_xxh64_round(v1, cb_read_le64(p));      p += 8;
            v2 = cb_xxh64_round(v2, cb_read_le64(p));      p += 8;
            v3 = cb_xxh64_round(v3, cb_read_le64(p));      p += 8;
            v4 = cb_xxh64_round(v4, cb_read_le64(p));      p += 8;
        } while (p <= limit);

        h64 = cb_rotl64(v1, 1) + cb_rotl64(v2, 7) + cb_rotl64(v3, 12) + cb_rotl64(v4, 18);
        h64 = cb_xxh64_merge_round(h64, v1);
        h64 = cb_xxh64_merge_round(h64, v2);
        h64 = cb_xxh64_merge_round(h64, v3);
        h64 = cb_xxh64_merge_round(h64, v4);
    } else {
        h64 = seed + CB_XXH_PRIME64_5;
    }

    h64 += (uint64_t)len;

    while (p + 8 <= b_end) {
        uint64_t k1 = cb_xxh64_round(0, cb_read_le64(p));
        h64 ^= k1;
        h64 = cb_rotl64(h64, 27) * CB_XXH_PRIME64_1 + CB_XXH_PRIME64_4;
        p += 8;
    }

    if (p + 4 <= b_end) {
        h64 ^= (uint64_t)cb_read_le32(p) * CB_XXH_PRIME64_1;
        h64 = cb_rotl64(h64, 23) * CB_XXH_PRIME64_2 + CB_XXH_PRIME64_3;
        p += 4;
    }

    while (p < b_end) {
        h64 ^= (uint64_t)(*p) * CB_XXH_PRIME64_5;
        h64 = cb_rotl64(h64, 11) * CB_XXH_PRIME64_1;
        p++;
    }

    h64 ^= h64 >> 33;
    h64 *= CB_XXH_PRIME64_2;
    h64 ^= h64 >> 29;
    h64 *= CB_XXH_PRIME64_3;
    h64 ^= h64 >> 32;

    return h64;
}

/* ========================================================================== *
 * 2. Canonical RFC 8949 CBOR Encoder Helpers                                 *
 *    - Definite-length arrays & maps                                         *
 *    - Minimal integer encoding                                              *
 *    - Canonical map key ordering: shorter byte length first, then           *
 *      lexicographic byte order (RFC 8949 Section 4.2.1).                    *
 * ========================================================================== */

typedef struct cb_cbor_buf {
    uint8_t *data;
    size_t   len;
    size_t   cap;
    bool     owned;
    bool     error;
} cb_cbor_buf;

static inline void cb_cbor_buf_init(cb_cbor_buf *b, size_t initial_cap) {
    if (initial_cap == 0) {
        initial_cap = 256;
    }
    b->data = (uint8_t *)malloc(initial_cap);
    b->len = 0;
    b->cap = b->data ? initial_cap : 0;
    b->owned = true;
    b->error = (b->data == NULL);
}

static inline void cb_cbor_buf_init_fixed(cb_cbor_buf *b, uint8_t *storage, size_t cap) {
    b->data = storage;
    b->len = 0;
    b->cap = cap;
    b->owned = false;
    b->error = (storage == NULL && cap > 0);
}

static inline void cb_cbor_buf_free(cb_cbor_buf *b) {
    if (b->owned && b->data) {
        free(b->data);
    }
    b->data = NULL;
    b->len = 0;
    b->cap = 0;
    b->owned = false;
}

static inline bool cb_cbor_buf_reserve(cb_cbor_buf *b, size_t extra) {
    if (b->error) {
        return false;
    }
    if (b->len + extra <= b->cap) {
        return true;
    }
    if (!b->owned) {
        b->error = true;
        return false;
    }
    size_t new_cap = b->cap ? b->cap * 2 : 256;
    while (new_cap < b->len + extra) {
        new_cap *= 2;
    }
    uint8_t *new_data = (uint8_t *)realloc(b->data, new_cap);
    if (!new_data) {
        b->error = true;
        return false;
    }
    b->data = new_data;
    b->cap = new_cap;
    return true;
}

static inline void cb_cbor_put_raw(cb_cbor_buf *b, const void *bytes, size_t n) {
    if (!cb_cbor_buf_reserve(b, n)) {
        return;
    }
    if (n > 0) {
        memcpy(b->data + b->len, bytes, n);
        b->len += n;
    }
}

static inline void cb_cbor_put_type_arg(cb_cbor_buf *b, uint8_t major, uint64_t val) {
    uint8_t prefix = (uint8_t)(major << 5);
    if (val < 24ULL) {
        uint8_t byte = (uint8_t)(prefix | (uint8_t)val);
        cb_cbor_put_raw(b, &byte, 1);
    } else if (val <= 0xFFULL) {
        uint8_t hdr[2] = { (uint8_t)(prefix | 24u), (uint8_t)val };
        cb_cbor_put_raw(b, hdr, 2);
    } else if (val <= 0xFFFFULL) {
        uint8_t hdr[3] = {
            (uint8_t)(prefix | 25u),
            (uint8_t)(val >> 8),
            (uint8_t)(val & 0xFFu)
        };
        cb_cbor_put_raw(b, hdr, 3);
    } else if (val <= 0xFFFFFFFFULL) {
        uint8_t hdr[5] = {
            (uint8_t)(prefix | 26u),
            (uint8_t)(val >> 24),
            (uint8_t)((val >> 16) & 0xFFu),
            (uint8_t)((val >> 8) & 0xFFu),
            (uint8_t)(val & 0xFFu)
        };
        cb_cbor_put_raw(b, hdr, 5);
    } else {
        uint8_t hdr[9] = {
            (uint8_t)(prefix | 27u),
            (uint8_t)(val >> 56),
            (uint8_t)((val >> 48) & 0xFFu),
            (uint8_t)((val >> 40) & 0xFFu),
            (uint8_t)((val >> 32) & 0xFFu),
            (uint8_t)((val >> 24) & 0xFFu),
            (uint8_t)((val >> 16) & 0xFFu),
            (uint8_t)((val >> 8) & 0xFFu),
            (uint8_t)(val & 0xFFu)
        };
        cb_cbor_put_raw(b, hdr, 9);
    }
}

static inline void cb_cbor_put_uint(cb_cbor_buf *b, uint64_t v) {
    cb_cbor_put_type_arg(b, 0u, v);
}

static inline void cb_cbor_put_int(cb_cbor_buf *b, int64_t v) {
    if (v >= 0) {
        cb_cbor_put_type_arg(b, 0u, (uint64_t)v);
    } else {
        uint64_t neg = (uint64_t)(-(v + 1));
        cb_cbor_put_type_arg(b, 1u, neg);
    }
}

static inline void cb_cbor_put_bool(cb_cbor_buf *b, bool v) {
    uint8_t byte = v ? 0xF5u : 0xF4u;
    cb_cbor_put_raw(b, &byte, 1);
}

static inline void cb_cbor_put_float64(cb_cbor_buf *b, double v) {
    uint64_t bits = 0;
    memcpy(&bits, &v, sizeof(bits));
    uint8_t hdr[9] = {
        0xFBu,
        (uint8_t)(bits >> 56),
        (uint8_t)((bits >> 48) & 0xFFu),
        (uint8_t)((bits >> 40) & 0xFFu),
        (uint8_t)((bits >> 32) & 0xFFu),
        (uint8_t)((bits >> 24) & 0xFFu),
        (uint8_t)((bits >> 16) & 0xFFu),
        (uint8_t)((bits >> 8) & 0xFFu),
        (uint8_t)(bits & 0xFFu)
    };
    cb_cbor_put_raw(b, hdr, 9);
}

static inline void cb_cbor_put_bytes(cb_cbor_buf *b, const void *data, size_t len) {
    cb_cbor_put_type_arg(b, 2u, (uint64_t)len);
    cb_cbor_put_raw(b, data, len);
}

static inline void cb_cbor_put_text(cb_cbor_buf *b, const char *str) {
    size_t len = str ? strlen(str) : 0;
    cb_cbor_put_type_arg(b, 3u, (uint64_t)len);
    cb_cbor_put_raw(b, str, len);
}

static inline void cb_cbor_put_text_n(cb_cbor_buf *b, const char *str, size_t len) {
    cb_cbor_put_type_arg(b, 3u, (uint64_t)len);
    cb_cbor_put_raw(b, str, len);
}

static inline void cb_cbor_array_begin(cb_cbor_buf *b, size_t count) {
    cb_cbor_put_type_arg(b, 4u, (uint64_t)count);
}

static inline void cb_cbor_map_begin(cb_cbor_buf *b, size_t pair_count) {
    cb_cbor_put_type_arg(b, 5u, (uint64_t)pair_count);
}

/**
 * Compare two text keys according to RFC 8949 Section 4.2.1 canonical CBOR
 * map key order: shorter byte length sorts first; equal lengths sort
 * lexicographically by unsigned byte value.
 */
static inline int cb_cbor_key_cmp(const char *a, const char *b) {
    size_t la = strlen(a);
    size_t lb = strlen(b);
    if (la < lb) {
        return -1;
    }
    if (la > lb) {
        return 1;
    }
    return memcmp(a, b, la);
}

/* ========================================================================== *
 * 3. 5-byte Frame Header & Builders for 0x25 (scene.font) & 0x26 (commit)    *
 * ========================================================================== */

static inline size_t cb_frame_begin(cb_cbor_buf *b, uint8_t msg_type) {
    size_t offset = b->len;
    uint8_t hdr[CB_FRAME_HEADER_LEN] = { msg_type, 0, 0, 0, 0 };
    cb_cbor_put_raw(b, hdr, CB_FRAME_HEADER_LEN);
    return offset;
}

static inline bool cb_frame_finish(cb_cbor_buf *b, size_t hdr_offset) {
    if (b->error || b->len < hdr_offset + CB_FRAME_HEADER_LEN) {
        return false;
    }
    size_t payload_len = b->len - (hdr_offset + CB_FRAME_HEADER_LEN);
    if (payload_len > 0xFFFFFFFFULL) {
        b->error = true;
        return false;
    }
    cb_write_le32(b->data + hdr_offset + 1, (uint32_t)payload_len);
    return true;
}

/**
 * Encode a framed 0x25 (scene.font) message into `b`.
 *
 * Canonical key order (RFC 8949):
 *   1. "data"   (len 4) : bytes
 *   2. "font"   (len 4) : u64
 *   3. "index"  (len 5) : u32
 *   4. "family" (len 6) : text (optional, omitted if family == NULL or empty)
 */
static inline bool cb_encode_scene_font(
    cb_cbor_buf *b,
    uint64_t font_hash,
    uint32_t face_index,
    const char *family,
    const void *font_bytes,
    size_t font_len
) {
    bool has_family = (family != NULL && family[0] != '\0');
    size_t hdr_off = cb_frame_begin(b, CB_MSG_SCENE_FONT);

    cb_cbor_map_begin(b, has_family ? 4u : 3u);

    /* 1. "data" (len 4) */
    cb_cbor_put_text(b, "data");
    cb_cbor_put_bytes(b, font_bytes, font_len);

    /* 2. "font" (len 4) */
    cb_cbor_put_text(b, "font");
    cb_cbor_put_uint(b, font_hash);

    /* 3. "index" (len 5) */
    cb_cbor_put_text(b, "index");
    cb_cbor_put_uint(b, (uint64_t)face_index);

    /* 4. "family" (len 6, optional) */
    if (has_family) {
        cb_cbor_put_text(b, "family");
        cb_cbor_put_text(b, family);
    }

    return cb_frame_finish(b, hdr_off);
}

/* Scene Node representation */
typedef enum cb_scene_node_kind {
    CB_NODE_RECT   = 1,
    CB_NODE_RCLIP  = 2,
    CB_NODE_SCROLL = 3,
    CB_NODE_GLYPHS = 4,
    CB_NODE_PATH   = 5
} cb_scene_node_kind_t;

typedef struct cb_glyph_pos {
    uint16_t glyph_id;
    float    x;
    float    y;
} cb_glyph_pos_t;

typedef struct cb_scene_node {
    uint64_t             id;
    cb_scene_node_kind_t kind;
    double               x;
    double               y;
    double               w;
    double               h;
    double               r;          /* corner radius for rect / rclip */
    uint32_t             color_rgba; /* 0xRRGGBBAA */

    /* scroll specific */
    double               content_w;
    double               content_h;
    double               scroll_x;
    double               scroll_y;

    /* glyphs specific */
    uint64_t             font_hash;
    uint32_t             face_index;
    double               font_size;
    const uint8_t       *packed_data;
    size_t               packed_len;

    /* child node IDs (for rclip / scroll containers) */
    const uint64_t      *children;
    size_t               children_count;
} cb_scene_node_t;

/**
 * Pack an array of `cb_glyph_pos_t` into tight 10-byte little-endian records:
 *   bytes [0..1] : uint16_t glyph_id (LE)
 *   bytes [2..5] : float32  x        (IEEE-754 LE)
 *   bytes [6..9] : float32  y        (IEEE-754 LE)
 */
static inline void cb_pack_glyph_records(
    uint8_t *dst,
    const cb_glyph_pos_t *glyphs,
    size_t count
) {
    for (size_t i = 0; i < count; i++) {
        uint8_t *rec = dst + (i * CB_GLYPH_RECORD_LEN);
        cb_write_le16(rec + 0, glyphs[i].glyph_id);
        cb_write_le_f32(rec + 2, glyphs[i].x);
        cb_write_le_f32(rec + 6, glyphs[i].y);
    }
}

/* Path builder helpers */
static inline void cb_path_move_to(cb_cbor_buf *path_buf, float x, float y) {
    uint8_t rec[9];
    rec[0] = CB_PATH_VERB_MOVE_TO;
    cb_write_le_f32(rec + 1, x);
    cb_write_le_f32(rec + 5, y);
    cb_cbor_put_raw(path_buf, rec, sizeof(rec));
}

static inline void cb_path_line_to(cb_cbor_buf *path_buf, float x, float y) {
    uint8_t rec[9];
    rec[0] = CB_PATH_VERB_LINE_TO;
    cb_write_le_f32(rec + 1, x);
    cb_write_le_f32(rec + 5, y);
    cb_cbor_put_raw(path_buf, rec, sizeof(rec));
}

static inline void cb_path_cubic_to(
    cb_cbor_buf *path_buf,
    float c1x, float c1y,
    float c2x, float c2y,
    float x, float y
) {
    uint8_t rec[25];
    rec[0] = CB_PATH_VERB_CUBIC_TO;
    cb_write_le_f32(rec + 1, c1x);
    cb_write_le_f32(rec + 5, c1y);
    cb_write_le_f32(rec + 9, c2x);
    cb_write_le_f32(rec + 13, c2y);
    cb_write_le_f32(rec + 17, x);
    cb_write_le_f32(rec + 21, y);
    cb_cbor_put_raw(path_buf, rec, sizeof(rec));
}

static inline void cb_path_close(cb_cbor_buf *path_buf) {
    uint8_t verb = CB_PATH_VERB_CLOSE;
    cb_cbor_put_raw(path_buf, &verb, 1);
}

/**
 * Encode a single scene node map with canonical RFC 8949 key order.
 */
static inline void cb_encode_scene_node(cb_cbor_buf *b, const cb_scene_node_t *n) {
    switch (n->kind) {
        case CB_NODE_RECT: {
            /* Keys sorted by (len, lex):
             * len 1: "h", "r", "w", "x", "y"
             * len 2: "id", "op"
             * len 5: "color"
             */
            cb_cbor_map_begin(b, 8u);
            cb_cbor_put_text(b, "h");     cb_cbor_put_float64(b, n->h);
            cb_cbor_put_text(b, "r");     cb_cbor_put_float64(b, n->r);
            cb_cbor_put_text(b, "w");     cb_cbor_put_float64(b, n->w);
            cb_cbor_put_text(b, "x");     cb_cbor_put_float64(b, n->x);
            cb_cbor_put_text(b, "y");     cb_cbor_put_float64(b, n->y);
            cb_cbor_put_text(b, "id");    cb_cbor_put_uint(b, n->id);
            cb_cbor_put_text(b, "op");    cb_cbor_put_text(b, "rect");
            cb_cbor_put_text(b, "color"); cb_cbor_put_uint(b, (uint64_t)n->color_rgba);
            break;
        }
        case CB_NODE_RCLIP: {
            /* Keys sorted by (len, lex):
             * len 1: "h", "r", "w", "x", "y"
             * len 2: "id", "op"
             * len 8: "children" (optional)
             */
            bool has_children = (n->children != NULL && n->children_count > 0);
            cb_cbor_map_begin(b, has_children ? 8u : 7u);
            cb_cbor_put_text(b, "h");  cb_cbor_put_float64(b, n->h);
            cb_cbor_put_text(b, "r");  cb_cbor_put_float64(b, n->r);
            cb_cbor_put_text(b, "w");  cb_cbor_put_float64(b, n->w);
            cb_cbor_put_text(b, "x");  cb_cbor_put_float64(b, n->x);
            cb_cbor_put_text(b, "y");  cb_cbor_put_float64(b, n->y);
            cb_cbor_put_text(b, "id"); cb_cbor_put_uint(b, n->id);
            cb_cbor_put_text(b, "op"); cb_cbor_put_text(b, "rclip");
            if (has_children) {
                cb_cbor_put_text(b, "children");
                cb_cbor_array_begin(b, n->children_count);
                for (size_t i = 0; i < n->children_count; i++) {
                    cb_cbor_put_uint(b, n->children[i]);
                }
            }
            break;
        }
        case CB_NODE_SCROLL: {
            /* Keys sorted by (len, lex):
             * len 1: "h", "w", "x", "y"
             * len 2: "ch", "cw", "id", "op", "sx", "sy"
             * len 8: "children" (optional)
             */
            bool has_children = (n->children != NULL && n->children_count > 0);
            cb_cbor_map_begin(b, has_children ? 11u : 10u);
            cb_cbor_put_text(b, "h");  cb_cbor_put_float64(b, n->h);
            cb_cbor_put_text(b, "w");  cb_cbor_put_float64(b, n->w);
            cb_cbor_put_text(b, "x");  cb_cbor_put_float64(b, n->x);
            cb_cbor_put_text(b, "y");  cb_cbor_put_float64(b, n->y);
            cb_cbor_put_text(b, "ch"); cb_cbor_put_float64(b, n->content_h);
            cb_cbor_put_text(b, "cw"); cb_cbor_put_float64(b, n->content_w);
            cb_cbor_put_text(b, "id"); cb_cbor_put_uint(b, n->id);
            cb_cbor_put_text(b, "op"); cb_cbor_put_text(b, "scroll");
            cb_cbor_put_text(b, "sx"); cb_cbor_put_float64(b, n->scroll_x);
            cb_cbor_put_text(b, "sy"); cb_cbor_put_float64(b, n->scroll_y);
            if (has_children) {
                cb_cbor_put_text(b, "children");
                cb_cbor_array_begin(b, n->children_count);
                for (size_t i = 0; i < n->children_count; i++) {
                    cb_cbor_put_uint(b, n->children[i]);
                }
            }
            break;
        }
        case CB_NODE_GLYPHS: {
            /* Keys sorted by (len, lex):
             * len 1: "x", "y"
             * len 2: "id", "op"
             * len 4: "data", "font", "size"
             * len 5: "color", "index"
             */
            cb_cbor_map_begin(b, 9u);
            cb_cbor_put_text(b, "x");     cb_cbor_put_float64(b, n->x);
            cb_cbor_put_text(b, "y");     cb_cbor_put_float64(b, n->y);
            cb_cbor_put_text(b, "id");    cb_cbor_put_uint(b, n->id);
            cb_cbor_put_text(b, "op");    cb_cbor_put_text(b, "glyphs");
            cb_cbor_put_text(b, "data");  cb_cbor_put_bytes(b, n->packed_data, n->packed_len);
            cb_cbor_put_text(b, "font");  cb_cbor_put_uint(b, n->font_hash);
            cb_cbor_put_text(b, "size");  cb_cbor_put_float64(b, n->font_size);
            cb_cbor_put_text(b, "color"); cb_cbor_put_uint(b, (uint64_t)n->color_rgba);
            cb_cbor_put_text(b, "index"); cb_cbor_put_uint(b, (uint64_t)n->face_index);
            break;
        }
        case CB_NODE_PATH: {
            /* Keys sorted by (len, lex):
             * len 2: "id", "op"
             * len 4: "data"
             * len 5: "color"
             */
            cb_cbor_map_begin(b, 4u);
            cb_cbor_put_text(b, "id");    cb_cbor_put_uint(b, n->id);
            cb_cbor_put_text(b, "op");    cb_cbor_put_text(b, "path");
            cb_cbor_put_text(b, "data");  cb_cbor_put_bytes(b, n->packed_data, n->packed_len);
            cb_cbor_put_text(b, "color"); cb_cbor_put_uint(b, (uint64_t)n->color_rgba);
            break;
        }
    }
}

/**
 * Encode a framed 0x26 (scene.commit) message into `b`.
 *
 * Canonical key order (RFC 8949):
 *   1. "id"     (len 2) : u64
 *   2. "seq"    (len 3) : u64
 *   3. "root"   (len 4) : u64
 *   4. "nodes"  (len 5) : [node, ...] (optional, included if node_count > 0)
 *   5. "reset"  (len 5) : bool        (optional, included if has_reset)
 *   6. "pts_us" (len 6) : u64
 *   7. "remove" (len 6) : [u64, ...]  (optional, included if remove_count > 0)
 */
static inline bool cb_encode_scene_commit(
    cb_cbor_buf *b,
    uint64_t surface_id,
    uint64_t seq,
    uint64_t pts_us,
    uint64_t root_id,
    bool has_reset,
    bool reset_val,
    const cb_scene_node_t *nodes,
    size_t node_count,
    const uint64_t *remove_ids,
    size_t remove_count
) {
    bool has_nodes = (nodes != NULL && node_count > 0);
    bool has_remove = (remove_ids != NULL && remove_count > 0);
    size_t map_count = 4u
        + (has_nodes ? 1u : 0u)
        + (has_reset ? 1u : 0u)
        + (has_remove ? 1u : 0u);

    size_t hdr_off = cb_frame_begin(b, CB_MSG_SCENE_COMMIT);
    cb_cbor_map_begin(b, map_count);

    /* 1. "id" (len 2) */
    cb_cbor_put_text(b, "id");
    cb_cbor_put_uint(b, surface_id);

    /* 2. "seq" (len 3) */
    cb_cbor_put_text(b, "seq");
    cb_cbor_put_uint(b, seq);

    /* 3. "root" (len 4) */
    cb_cbor_put_text(b, "root");
    cb_cbor_put_uint(b, root_id);

    /* 4. "nodes" (len 5, 'n' < 'r') */
    if (has_nodes) {
        cb_cbor_put_text(b, "nodes");
        cb_cbor_array_begin(b, node_count);
        for (size_t i = 0; i < node_count; i++) {
            cb_encode_scene_node(b, &nodes[i]);
        }
    }

    /* 5. "reset" (len 5) */
    if (has_reset) {
        cb_cbor_put_text(b, "reset");
        cb_cbor_put_bool(b, reset_val);
    }

    /* 6. "pts_us" (len 6, 'p' < 'r') */
    cb_cbor_put_text(b, "pts_us");
    cb_cbor_put_uint(b, pts_us);

    /* 7. "remove" (len 6) */
    if (has_remove) {
        cb_cbor_put_text(b, "remove");
        cb_cbor_array_begin(b, remove_count);
        for (size_t i = 0; i < remove_count; i++) {
            cb_cbor_put_uint(b, remove_ids[i]);
        }
    }

    return cb_frame_finish(b, hdr_off);
}

/* ========================================================================== *
 * 4. 0x9A (scene.scroll) Encoder & Decoder                                   *
 *    Map: { "id": u64, "sx": f64, "sy": f64, "node": u64 }                   *
 * ========================================================================== */

typedef struct cb_scene_scroll_event {
    uint64_t surface_id;
    uint64_t node_id;
    double   sx;
    double   sy;
} cb_scene_scroll_event_t;

static inline bool cb_encode_scene_scroll(
    cb_cbor_buf *b,
    const cb_scene_scroll_event_t *ev
) {
    size_t hdr_off = cb_frame_begin(b, CB_MSG_SCENE_SCROLL);
    /* Canonical key order: "id" (2), "sx" (2), "sy" (2), "node" (4) */
    cb_cbor_map_begin(b, 4u);
    cb_cbor_put_text(b, "id");   cb_cbor_put_uint(b, ev->surface_id);
    cb_cbor_put_text(b, "sx");   cb_cbor_put_float64(b, ev->sx);
    cb_cbor_put_text(b, "sy");   cb_cbor_put_float64(b, ev->sy);
    cb_cbor_put_text(b, "node"); cb_cbor_put_uint(b, ev->node_id);
    return cb_frame_finish(b, hdr_off);
}

/* Minimal CBOR cursor for reading 0x9A (scene.scroll) maps */
static inline bool cb_cbor_read_type_arg(
    const uint8_t *buf,
    size_t len,
    size_t *pos,
    uint8_t *major_out,
    uint64_t *val_out
) {
    if (*pos >= len) {
        return false;
    }
    uint8_t b0 = buf[(*pos)++];
    *major_out = (uint8_t)(b0 >> 5);
    uint8_t ai = (uint8_t)(b0 & 0x1Fu);
    if (ai < 24u) {
        *val_out = ai;
        return true;
    } else if (ai == 24u) {
        if (*pos + 1 > len) return false;
        *val_out = buf[(*pos)++];
        return true;
    } else if (ai == 25u) {
        if (*pos + 2 > len) return false;
        *val_out = ((uint64_t)buf[*pos] << 8) | (uint64_t)buf[*pos + 1];
        *pos += 2;
        return true;
    } else if (ai == 26u) {
        if (*pos + 4 > len) return false;
        *val_out = ((uint64_t)buf[*pos] << 24)
                 | ((uint64_t)buf[*pos + 1] << 16)
                 | ((uint64_t)buf[*pos + 2] << 8)
                 | (uint64_t)buf[*pos + 3];
        *pos += 4;
        return true;
    } else if (ai == 27u) {
        if (*pos + 8 > len) return false;
        *val_out = ((uint64_t)buf[*pos] << 56)
                 | ((uint64_t)buf[*pos + 1] << 48)
                 | ((uint64_t)buf[*pos + 2] << 40)
                 | ((uint64_t)buf[*pos + 3] << 32)
                 | ((uint64_t)buf[*pos + 4] << 24)
                 | ((uint64_t)buf[*pos + 5] << 16)
                 | ((uint64_t)buf[*pos + 6] << 8)
                 | (uint64_t)buf[*pos + 7];
        *pos += 8;
        return true;
    }
    return false;
}

static inline bool cb_decode_scene_scroll_payload(
    const uint8_t *payload,
    size_t len,
    cb_scene_scroll_event_t *out
) {
    size_t pos = 0;
    uint8_t major = 0;
    uint64_t map_len = 0;
    if (!cb_cbor_read_type_arg(payload, len, &pos, &major, &map_len) || major != 5u) {
        return false;
    }
    memset(out, 0, sizeof(*out));
    bool got_id = false, got_node = false, got_sx = false, got_sy = false;

    for (uint64_t i = 0; i < map_len; i++) {
        uint8_t kmaj = 0;
        uint64_t klen = 0;
        if (!cb_cbor_read_type_arg(payload, len, &pos, &kmaj, &klen) || kmaj != 3u) {
            return false;
        }
        if (pos + klen > len) {
            return false;
        }
        const char *key = (const char *)(payload + pos);
        pos += (size_t)klen;

        uint8_t vmaj = 0;
        uint64_t vraw = 0;
        if (!cb_cbor_read_type_arg(payload, len, &pos, &vmaj, &vraw)) {
            return false;
        }

        if (klen == 2 && memcmp(key, "id", 2) == 0 && vmaj == 0u) {
            out->surface_id = vraw;
            got_id = true;
        } else if (klen == 4 && memcmp(key, "node", 4) == 0 && vmaj == 0u) {
            out->node_id = vraw;
            got_node = true;
        } else if (klen == 2 && memcmp(key, "sx", 2) == 0 && vmaj == 7u) {
            double d = 0.0;
            memcpy(&d, &vraw, sizeof(d));
            out->sx = d;
            got_sx = true;
        } else if (klen == 2 && memcmp(key, "sy", 2) == 0 && vmaj == 7u) {
            double d = 0.0;
            memcpy(&d, &vraw, sizeof(d));
            out->sy = d;
            got_sy = true;
        }
    }
    return got_id && got_node && got_sx && got_sy;
}

/* ========================================================================== *
 * 5. Non-blocking Socket Client (cb_scene_client_t)                          *
 *    Invariant A (Headless Liveness):                                        *
 *      If CABOOSE_SCENE_SOCKET is unset, missing, refuses connection, or     *
 *      returns EAGAIN / EPIPE / ECONNRESET on write, cb_scene_client_t       *
 *      immediately drops into non-blocking local passthrough mode without    *
 *      ever stalling, blocking, or raising SIGPIPE!                          *
 * ========================================================================== */

#define CB_MAX_KNOWN_FONTS 128u

typedef struct cb_font_dedup_entry {
    uint64_t font_hash;
    uint32_t face_index;
} cb_font_dedup_entry_t;

typedef struct cb_scene_client {
    int                   fd;
    bool                  passthrough;
    uint64_t              bytes_sent;
    uint64_t              frames_committed;
    uint64_t              drops;
    cb_font_dedup_entry_t sent_fonts[CB_MAX_KNOWN_FONTS];
    size_t                sent_fonts_count;
    uint8_t               rx_buf[512];
    size_t                rx_len;
} cb_scene_client_t;

static inline uint64_t cb_monotonic_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000ULL + (uint64_t)(ts.tv_nsec / 1000ULL);
}

static inline void cb_set_socket_nonblocking_nosigpipe(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) {
        (void)fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    }
    int cloexec = fcntl(fd, F_GETFD, 0);
    if (cloexec >= 0) {
        (void)fcntl(fd, F_SETFD, cloexec | FD_CLOEXEC);
    }
#ifdef SO_NOSIGPIPE
    int one = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
}

static inline void cb_scene_client_init_from_fd(cb_scene_client_t *c, int fd) {
    memset(c, 0, sizeof(*c));
    if (fd >= 0) {
        cb_set_socket_nonblocking_nosigpipe(fd);
        c->fd = fd;
        c->passthrough = false;
    } else {
        c->fd = -1;
        c->passthrough = true;
    }
}

static inline void cb_scene_client_connect_path(cb_scene_client_t *c, const char *sock_path) {
    memset(c, 0, sizeof(*c));
    c->fd = -1;
    c->passthrough = true;

    if (!sock_path || sock_path[0] == '\0') {
        return;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    if (strlen(sock_path) >= sizeof(addr.sun_path)) {
        return;
    }
    strncpy(addr.sun_path, sock_path, sizeof(addr.sun_path) - 1);

#ifdef SOCK_NONBLOCK
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
#else
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
#endif
    if (fd < 0) {
        return;
    }
    cb_set_socket_nonblocking_nosigpipe(fd);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return;
    }

    c->fd = fd;
    c->passthrough = false;
}

static inline void cb_scene_client_init_env(cb_scene_client_t *c) {
    const char *path = getenv("CABOOSE_SCENE_SOCKET");
    cb_scene_client_connect_path(c, path);
}

static inline void cb_scene_client_close(cb_scene_client_t *c) {
    if (c->fd >= 0) {
        close(c->fd);
        c->fd = -1;
    }
    c->passthrough = true;
    c->sent_fonts_count = 0;
    c->rx_len = 0;
}

static inline bool cb_scene_client_has_font(
    const cb_scene_client_t *c,
    uint64_t font_hash,
    uint32_t face_index
) {
    for (size_t i = 0; i < c->sent_fonts_count; i++) {
        if (c->sent_fonts[i].font_hash == font_hash &&
            c->sent_fonts[i].face_index == face_index) {
            return true;
        }
    }
    return false;
}

static inline void cb_scene_client_record_font(
    cb_scene_client_t *c,
    uint64_t font_hash,
    uint32_t face_index
) {
    if (cb_scene_client_has_font(c, font_hash, face_index)) {
        return;
    }
    if (c->sent_fonts_count < CB_MAX_KNOWN_FONTS) {
        c->sent_fonts[c->sent_fonts_count].font_hash = font_hash;
        c->sent_fonts[c->sent_fonts_count].face_index = face_index;
        c->sent_fonts_count++;
    }
}

/**
 * Non-blocking send of a complete framed message.
 * If the socket returns EAGAIN/EWOULDBLOCK or EPIPE/ECONNRESET, immediately
 * drops into passthrough mode without stalling the application.
 */
static inline bool cb_scene_client_send_raw(
    cb_scene_client_t *c,
    const uint8_t *data,
    size_t len
) {
    if (c->passthrough || c->fd < 0) {
        c->drops++;
        return false;
    }

    int send_flags = 0;
#ifdef MSG_NOSIGNAL
    send_flags |= MSG_NOSIGNAL;
#endif
#ifdef MSG_DONTWAIT
    send_flags |= MSG_DONTWAIT;
#endif

    size_t total = 0;
    while (total < len) {
        ssize_t n = send(c->fd, data + total, len - total, send_flags);
        if (n > 0) {
            total += (size_t)n;
            continue;
        }
        if (n < 0 && errno == EINTR) {
            continue;
        }
        /* Invariant A (Headless Liveness): never block on EAGAIN or broken pipe */
        cb_scene_client_close(c);
        c->drops++;
        return false;
    }

    c->bytes_sent += (uint64_t)total;
    return true;
}

/**
 * Send `0x25` (scene.font) if and only if `(font_hash, face_index)` has not
 * yet been sent on this session. Returns true if already sent or newly sent.
 */
static inline bool cb_scene_client_send_font_once(
    cb_scene_client_t *c,
    uint64_t font_hash,
    uint32_t face_index,
    const char *family,
    const void *font_bytes,
    size_t font_len
) {
    if (c->passthrough || c->fd < 0) {
        return false;
    }
    if (cb_scene_client_has_font(c, font_hash, face_index)) {
        return true;
    }
    cb_cbor_buf buf;
    cb_cbor_buf_init(&buf, font_len + 64u);
    if (!cb_encode_scene_font(&buf, font_hash, face_index, family, font_bytes, font_len)) {
        cb_cbor_buf_free(&buf);
        return false;
    }
    bool ok = cb_scene_client_send_raw(c, buf.data, buf.len);
    cb_cbor_buf_free(&buf);
    if (ok) {
        cb_scene_client_record_font(c, font_hash, face_index);
    }
    return ok;
}

/**
 * Non-blocking poll for incoming `0x9A` (scene.scroll) messages from the
 * display server. Returns true and populates `out_event` if a scroll update
 * was read.
 */
static inline bool cb_scene_client_poll_scroll(
    cb_scene_client_t *c,
    cb_scene_scroll_event_t *out_event
) {
    if (c->passthrough || c->fd < 0) {
        return false;
    }

    int recv_flags = 0;
#ifdef MSG_DONTWAIT
    recv_flags |= MSG_DONTWAIT;
#endif

    if (c->rx_len < sizeof(c->rx_buf)) {
        ssize_t n = recv(c->fd, c->rx_buf + c->rx_len, sizeof(c->rx_buf) - c->rx_len, recv_flags);
        if (n > 0) {
            c->rx_len += (size_t)n;
        } else if (n == 0) {
            cb_scene_client_close(c);
            return false;
        } else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
            cb_scene_client_close(c);
            return false;
        }
    }

    while (c->rx_len >= CB_FRAME_HEADER_LEN) {
        uint8_t msg_type = c->rx_buf[0];
        uint32_t payload_len = cb_read_le32(c->rx_buf + 1);
        size_t frame_len = CB_FRAME_HEADER_LEN + (size_t)payload_len;
        if (frame_len > sizeof(c->rx_buf)) {
            /* Corrupt/oversized frame on feedback channel */
            c->rx_len = 0;
            return false;
        }
        if (c->rx_len < frame_len) {
            return false;
        }

        const uint8_t *payload = c->rx_buf + CB_FRAME_HEADER_LEN;
        bool decoded = false;
        if (msg_type == CB_MSG_SCENE_SCROLL && out_event != NULL) {
            decoded = cb_decode_scene_scroll_payload(payload, payload_len, out_event);
        }

        size_t remaining = c->rx_len - frame_len;
        if (remaining > 0) {
            memmove(c->rx_buf, c->rx_buf + frame_len, remaining);
        }
        c->rx_len = remaining;

        if (decoded) {
            return true;
        }
    }

    return false;
}

#ifdef __cplusplus
}
#endif

#endif /* CABOOSE_SCENE_WIRE_H */
