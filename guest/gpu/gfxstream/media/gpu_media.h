/* Phone-decoded video for GPU-presented windows: the wire and the surface
 * identity shared by caboose_drv_video.so (the producer) and the Caboose Vulkan
 * driver (the consumer). docs/gpu-media.md is the normative description; the
 * byte layouts here are pinned by tests/gpu-media-vectors.txt.
 *
 * Plain C99 with no libva dependency, so the Vulkan driver (C++) and the unit
 * tests include it as it is. All integers are little-endian. */
#ifndef CABOOSE_GPU_MEDIA_H
#define CABOOSE_GPU_MEDIA_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#ifdef __cplusplus
#include <atomic>
#define CB_GM_ATOMIC_U32 std::atomic<uint32_t>
#define CB_GM_LOAD_ACQ(p) (p)->load(std::memory_order_acquire)
#define CB_GM_STORE_REL(p, v) (p)->store((v), std::memory_order_release)
#define CB_GM_FENCE_ACQ() std::atomic_thread_fence(std::memory_order_acquire)
#define CB_GM_FENCE_REL() std::atomic_thread_fence(std::memory_order_release)
#else
#include <stdatomic.h>
#define CB_GM_ATOMIC_U32 _Atomic uint32_t
#define CB_GM_LOAD_ACQ(p) atomic_load_explicit((p), memory_order_acquire)
#define CB_GM_STORE_REL(p, v) atomic_store_explicit((p), (v), memory_order_release)
#define CB_GM_FENCE_ACQ() atomic_thread_fence(memory_order_acquire)
#define CB_GM_FENCE_REL() atomic_thread_fence(memory_order_release)
#endif

/* ---- Surface identity ----------------------------------------------------
 *
 * Every surface the driver allocates is one dmabuf whose last 4096-byte page
 * follows the picture planes and holds this record. It says what the picture
 * planes mean: nothing yet, a picture that only the phone has decoded, or the
 * picture's own pixels (local decoding). Any process that maps the dmabuf can
 * read it, so the consumer does not need to share an address space, a socket
 * or a lifetime with the decoder. Writers follow the sequence-lock protocol in
 * cb_gm_identity_write(); readers use cb_gm_identity_read(). */

#define CB_GM_IDENTITY_PAGE 4096u
#define CB_GM_IDENTITY_MAGIC "CBVAID01"

enum {
    CB_GM_EMPTY = 0,  /* no picture decoded into the surface yet */
    CB_GM_PHONE = 1,  /* the picture exists only on the phone, by (token, surface, serial) */
    CB_GM_PIXELS = 2, /* the planes hold the picture's pixels */
};

#define CB_GM_FOURCC_NV12 0x3231564eu /* 'NV12' */
#define CB_GM_FOURCC_P010 0x30313050u /* 'P010' */

typedef struct {
    uint8_t magic[8];
    CB_GM_ATOMIC_U32 sequence; /* odd while being written */
    uint32_t state;            /* CB_GM_EMPTY, CB_GM_PHONE or CB_GM_PIXELS */
    uint8_t token[16];         /* the media connection the serial belongs to */
    uint64_t serial;           /* nonzero; increases with every new picture or new pixels */
    uint32_t surface;          /* the VA surface ID, the phone's retention key */
    uint32_t fourcc;           /* NV12 or P010 */
    uint16_t width, height;    /* the picture's size in pixels */
    uint32_t pitch;            /* bytes per row, both planes */
    uint32_t uv_offset;        /* byte offset of the interleaved chroma plane */
    uint32_t reserved;         /* zero */
} cb_gm_identity_page;

/* A consistent copy of an identity record. */
typedef struct {
    uint32_t state;
    uint8_t token[16];
    uint64_t serial;
    uint32_t surface, fourcc;
    uint16_t width, height;
    uint32_t pitch, uv_offset;
} cb_gm_identity;

#ifdef __cplusplus
static_assert(sizeof(cb_gm_identity_page) == 64, "identity record is 64 bytes");
#else
_Static_assert(sizeof(cb_gm_identity_page) == 64, "identity record is 64 bytes");
#endif

/* The record of a mapped surface of `size` bytes (a multiple of 4096). */
static inline cb_gm_identity_page *cb_gm_identity_at(void *map, size_t size)
{
    return size >= CB_GM_IDENTITY_PAGE && !(size % CB_GM_IDENTITY_PAGE)
               ? (cb_gm_identity_page *)((uint8_t *)map + size - CB_GM_IDENTITY_PAGE)
               : NULL;
}

/* Writes a record. Single writer (the decoding process); readers never block it. */
static inline void cb_gm_identity_write(cb_gm_identity_page *p, const cb_gm_identity *v)
{
    uint32_t seq = CB_GM_LOAD_ACQ(&p->sequence);
    if (seq & 1u)
        seq++; /* a writer died mid-update; restart from even */
    CB_GM_STORE_REL(&p->sequence, seq + 1u);
    CB_GM_FENCE_REL();
    memcpy(p->magic, CB_GM_IDENTITY_MAGIC, 8);
    p->state = v->state;
    memcpy(p->token, v->token, 16);
    p->serial = v->serial;
    p->surface = v->surface;
    p->fourcc = v->fourcc;
    p->width = v->width;
    p->height = v->height;
    p->pitch = v->pitch;
    p->uv_offset = v->uv_offset;
    p->reserved = 0;
    CB_GM_STORE_REL(&p->sequence, seq + 2u);
}

/* Reads a consistent, structurally valid record of a surface of `size` bytes.
 * Returns 1 on success, 0 when the page holds no valid record (not one of the
 * driver's surfaces, or one that is being rewritten for longer than the
 * reader is willing to spin). */
static inline int cb_gm_identity_read(const cb_gm_identity_page *p, size_t size, cb_gm_identity *out)
{
    for (int attempt = 0; attempt < 64; attempt++) {
        uint32_t before = CB_GM_LOAD_ACQ(&p->sequence);
        if (before & 1u)
            continue;
        cb_gm_identity v;
        uint8_t magic[8];
        memcpy(magic, p->magic, 8);
        v.state = p->state;
        memcpy(v.token, p->token, 16);
        v.serial = p->serial;
        v.surface = p->surface;
        v.fourcc = p->fourcc;
        v.width = p->width;
        v.height = p->height;
        v.pitch = p->pitch;
        v.uv_offset = p->uv_offset;
        CB_GM_FENCE_ACQ();
        if (CB_GM_LOAD_ACQ(&p->sequence) != before)
            continue;
        if (memcmp(magic, CB_GM_IDENTITY_MAGIC, 8) || v.state > CB_GM_PIXELS)
            return 0;
        if (v.state != CB_GM_EMPTY) {
            unsigned bps = v.fourcc == CB_GM_FOURCC_P010 ? 2u : v.fourcc == CB_GM_FOURCC_NV12 ? 1u : 0u;
            uint64_t luma_end = (uint64_t)v.pitch * v.height;
            uint64_t chroma_end = (uint64_t)v.uv_offset + (uint64_t)v.pitch * ((v.height + 1u) / 2u);
            if (!bps || !v.width || !v.height || !v.serial || v.pitch < (uint64_t)v.width * bps ||
                v.uv_offset < luma_end || chroma_end > size - CB_GM_IDENTITY_PAGE)
                return 0;
        }
        *out = v;
        return 1;
    }
    return 0;
}

/* ---- Media stream ---------------------------------------------------------
 *
 * The decoder connects to the GPU broker socket ($CABOOSE_GFXSTREAM_SOCKET)
 * with the ordinary broker hello, so the stream is admitted, bound to the
 * process and retired exactly like the process's Vulkan streams. In place of
 * Vulkan's client-flags word it sends CB_GM_STREAM_FLAGS; the phone hands the
 * rest of the stream to its media decoder instead of the Vulkan decoder.
 * Records follow: u32 type, u32 payload length, payload. */

#define CB_GM_STREAM_FLAGS 0x4d564243u /* "CBVM" */
#define CB_GM_VERSION 1u
#define CB_GM_MAX_RECORD (16u << 20)

/* decoder -> phone */
#define CB_GM_HELLO 0x01        /* u32 version, u8 token[16] */
#define CB_GM_OPEN 0x02         /* u32 stream, u8 codec, u8 bit_depth, u8 chroma (1: 4:2:0), u8 0, u16 w, u16 h */
#define CB_GM_UNIT 0x03         /* u32 stream, u32 seq, u32 surface, u32 flags, u64 serial, u16 w, u16 h, u32 0, data */
#define CB_GM_CLOSE 0x04        /* u32 stream */
#define CB_GM_SURFACE_GONE 0x05 /* u32 surface */

/* phone -> decoder */
#define CB_GM_CAPS 0x81   /* u32 version, u32 count, count x { u8 codec, u8 max_depth, u16 0, u16 max_w, u16 max_h } */
#define CB_GM_FAIL 0x82   /* u32 stream, u32 reason */
#define CB_GM_REPLAY 0x83 /* u32 stream: send again from the last key frame */

#define CB_GM_FAIL_UNSUPPORTED 1 /* the phone cannot decode this stream's format */
#define CB_GM_FAIL_DECODE 2      /* the phone's decoder keeps failing on it */

#define CB_GM_HELLO_SIZE 20u
#define CB_GM_OPEN_SIZE 12u
#define CB_GM_UNIT_HEAD 32u
#define CB_GM_CAPS_ENTRY 8u
#define CB_GM_MAX_CAPS 16u

typedef struct {
    uint8_t codec, max_depth;
    uint16_t max_width, max_height;
} cb_gm_cap;

static inline void cb_gm_le16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static inline void cb_gm_le32(uint8_t *p, uint32_t v)
{
    for (int i = 0; i < 4; i++)
        p[i] = (uint8_t)(v >> (8 * i));
}
static inline void cb_gm_le64(uint8_t *p, uint64_t v)
{
    for (int i = 0; i < 8; i++)
        p[i] = (uint8_t)(v >> (8 * i));
}
static inline uint16_t cb_gm_rd16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static inline uint32_t cb_gm_rd32(const uint8_t *p)
{
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static inline uint64_t cb_gm_rd64(const uint8_t *p) { return cb_gm_rd32(p) | (uint64_t)cb_gm_rd32(p + 4) << 32; }

/* Record headers. `out` holds 8 bytes. */
static inline void cb_gm_record_head(uint8_t *out, uint32_t type, uint32_t length)
{
    cb_gm_le32(out, type);
    cb_gm_le32(out + 4, length);
}

static inline void cb_gm_encode_hello(uint8_t out[CB_GM_HELLO_SIZE], const uint8_t token[16])
{
    cb_gm_le32(out, CB_GM_VERSION);
    memcpy(out + 4, token, 16);
}

static inline void cb_gm_encode_open(uint8_t out[CB_GM_OPEN_SIZE], uint32_t stream, uint8_t codec,
                                     uint8_t depth, uint16_t w, uint16_t h)
{
    cb_gm_le32(out, stream);
    out[4] = codec;
    out[5] = depth;
    out[6] = 1;
    out[7] = 0;
    cb_gm_le16(out + 8, w);
    cb_gm_le16(out + 10, h);
}

static inline void cb_gm_encode_unit(uint8_t out[CB_GM_UNIT_HEAD], uint32_t stream, uint32_t seq,
                                     uint32_t surface, uint32_t flags, uint64_t serial, uint16_t w,
                                     uint16_t h)
{
    cb_gm_le32(out, stream);
    cb_gm_le32(out + 4, seq);
    cb_gm_le32(out + 8, surface);
    cb_gm_le32(out + 12, flags);
    cb_gm_le64(out + 16, serial);
    cb_gm_le16(out + 24, w);
    cb_gm_le16(out + 26, h);
    cb_gm_le32(out + 28, 0);
}

/* Parses a CAPS payload. Returns the number of entries, or -1 when malformed. */
static inline int cb_gm_parse_caps(const uint8_t *p, size_t len, cb_gm_cap *caps, unsigned max)
{
    if (len < 8 || cb_gm_rd32(p) != CB_GM_VERSION)
        return -1;
    uint32_t count = cb_gm_rd32(p + 4);
    if (count > CB_GM_MAX_CAPS || len != 8u + (size_t)count * CB_GM_CAPS_ENTRY)
        return -1;
    unsigned n = 0;
    for (uint32_t i = 0; i < count; i++) {
        const uint8_t *e = p + 8 + (size_t)i * CB_GM_CAPS_ENTRY;
        if (cb_gm_rd16(e + 2) != 0)
            return -1;
        if (n < max)
            caps[n++] = (cb_gm_cap){ e[0], e[1], cb_gm_rd16(e + 4), cb_gm_rd16(e + 6) };
    }
    return (int)n;
}

/* ---- Latch ----------------------------------------------------------------
 *
 * The Vulkan driver puts this packet in a process's ordered Vulkan stream just
 * before the queue submission that may sample the images it names. The phone
 * fills each image there, on that queue: from its decoded picture (PICTURE),
 * or from the pixels carried in the packet (PIXELS). It is not a Vulkan
 * command and has no sequence number; the phone's stream reader handles it
 * before the Vulkan decoder sees the stream. */

#define CB_GM_LATCH_OPCODE 0x4c564243u /* "CBVL" */
#define CB_GM_LATCH_HEAD 24u           /* u32 opcode, u32 size, u64 queue, u32 count, u32 0 */
#define CB_GM_LATCH_ENTRY 24u          /* u64 image, u32 kind, u32 planes, u32 fourcc, u16 w, u16 h */
#define CB_GM_LATCH_PICTURE 32u        /* u8 token[16], u32 surface, u32 0, u64 serial */
#define CB_GM_LATCH_PIXELS 16u         /* u32 pitch, u32 uv_offset, u64 bytes, then the bytes */
#define CB_GM_LATCH_MAX_ENTRIES 64u
#define CB_GM_LATCH_MAX_PACKET (16u << 20) /* the phone's largest stream packet */

#define CB_GM_KIND_PICTURE 1u
#define CB_GM_KIND_PIXELS 2u

/* Which of the surface's planes the image holds. */
#define CB_GM_PLANE_LUMA 1u
#define CB_GM_PLANE_CHROMA 2u

#endif
