/* Internal interfaces of caboose_drv_video.so. */
#ifndef CABOOSE_VA_H
#define CABOOSE_VA_H

#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <va/va.h>
#include <va/va_backend.h>
#include <va/va_drmcommon.h>

#include "bits.h"
#include "proto.h"

#define CB_UNSUPPORTED (-2)

typedef struct cb_driver cb_driver;
typedef struct cb_context cb_context;
typedef struct cb_sink cb_sink;
typedef struct cb_local cb_local;

typedef struct {
    VAProfile profile;
    VAEntrypoint entrypoint;
    unsigned rt_format;
} cb_config;

typedef struct {
    VASurfaceID id;
    unsigned width, height;
    uint32_t fourcc; /* VA_FOURCC_NV12 or VA_FOURCC_P010 */
    unsigned bps;    /* bytes per sample: 1 or 2 */
    unsigned pitch, rows; /* luma pitch and allocated rows */
    size_t uv_offset, size;
    int memfd;      /* our memory, or -1 when imported */
    int dmabuf;     /* udmabuf over memfd, or the imported dmabuf; -1 if none */
    int imported;
    uint8_t *map;
    uint64_t dev, ino; /* the dmabuf's identity, for the compositor */
    int announced;
    int mark;          /* (tag << 6 | seq & 63) painted now; -1 when it holds pixels */
    VAContextID owner; /* context that last decoded into it */
    uint32_t seq;      /* that frame's sequence number */
} cb_surface;

typedef struct {
    VABufferType type;
    unsigned elem_size, count;
    uint8_t *data;       /* owned, or the surface memory for a derived image */
    VASurfaceID derived; /* VA_INVALID_SURFACE unless this is a derived image's buffer */
    int mapped;
} cb_buffer;

typedef struct {
    VAImage image;
    VASurfaceID derived;
} cb_image;

typedef struct {
    void *params;     /* `count` slice parameter structs of `elem_size` bytes */
    unsigned count, elem_size;
    uint8_t *data;    /* the slice data buffer they index */
    size_t data_size;
} cb_slice;

typedef struct {
    VASurfaceID target;
    void *pp;
    size_t pp_size;
    void *iq;
    size_t iq_size;
    cb_slice *slices;
    unsigned nslices, cap;
} cb_picture;

/* A codec's bitstream rebuilder. picture() turns one VA picture into compressed
 * data and hands it to cb_emit(), now or (AV1) once the next picture shows what
 * it needs; flush() emits anything held back. */
typedef struct {
    const char *name;
    uint8_t id;
    size_t state_size;
    int (*picture)(cb_context *c, const cb_picture *p, uint32_t seq);
    void (*flush)(cb_context *c);
    /* Optional: data that decodes the held-back picture's pixels now, for the
     * local decoder only (it is decoded again, exactly, when emitted).
     * A nonmatching requested seq must not consume the held picture. */
    int (*provisional)(cb_context *c, cb_buf *out, uint32_t seq);
    /* Optional: the surface the app presents the picture in, when it is not the
     * decode target (AV1 film grain); it carries the marker and the pixels. */
    VASurfaceID (*display)(cb_context *c, const cb_picture *p);
    void (*fini)(cb_context *c);
} cb_codec;

extern const cb_codec cb_codec_h264, cb_codec_hevc, cb_codec_vp9, cb_codec_av1;

#define CB_GOP_LIMIT (64u << 20)
#define CB_SEQ_MAP 256

typedef struct {
    uint32_t seq;
    VASurfaceID surface;
    unsigned flags;
    uint16_t w, h;
    size_t off, len; /* into gop.data */
} cb_gop_entry;

struct cb_context {
    VAContextID id;
    cb_driver *drv;
    VAProfile profile;
    const cb_codec *codec;
    void *state; /* codec state */
    unsigned width, height;
    cb_picture pic;
    int in_picture;
    uint32_t next_seq;
    uint32_t stream;   /* id on the video socket */
    int mode;          /* CB_MODE_* */
    unsigned tag;
    int unsupported;
    /* Bitstream since the last key frame: replayed to the client on request
     * and into the local decoder when this stream falls back. */
    cb_buf gop;
    cb_gop_entry *gop_entries;
    unsigned gop_count, gop_cap;
    int gop_valid; /* the buffer starts at a key frame and is complete */
    cb_local *local;
    VASurfaceID seq_surface[CB_SEQ_MAP];
    uint32_t seq_of[CB_SEQ_MAP];
};

struct cb_driver {
    pthread_mutex_t lock;
    void **objs[5];
    unsigned nobjs[5];
    cb_sink *sink;
    int udmabuf;
    int force_decode;
    uint32_t next_stream;
};

enum { CB_OBJ_CONFIG, CB_OBJ_CONTEXT, CB_OBJ_SURFACE, CB_OBJ_BUFFER, CB_OBJ_IMAGE };

void *cb_obj(cb_driver *d, int kind, unsigned id);
cb_surface *cb_get_surface(cb_driver *d, VASurfaceID id);

/* Hands one unit of rebuilt bitstream for picture `seq` to the stream. */
void cb_emit(cb_context *c, uint32_t seq, VASurfaceID surface, unsigned flags,
             const uint8_t *data, size_t len, unsigned w, unsigned h);
/* Marks the stream as using something passthrough cannot carry. */
void cb_unsupported(cb_context *c, const char *why);
void cb_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

/* Surfaces (surface.c) */
VAStatus cb_surface_alloc(cb_driver *d, cb_surface *s, unsigned w, unsigned h, uint32_t fourcc);
VAStatus cb_surface_import(cb_driver *d, cb_surface *s, const VADRMPRIMESurfaceDescriptor *desc);
void cb_surface_free(cb_surface *s);
void cb_surface_begin_cpu(cb_surface *s);
void cb_surface_end_cpu(cb_surface *s);
void cb_surface_mark(cb_surface *s, unsigned tag, uint32_t seq);
VAStatus cb_surface_export(cb_surface *s, uint32_t mem_type, uint32_t flags, void *descriptor);

/* The video socket (sink.c) */
typedef struct {
    uint8_t type;
    uint32_t stream;
    uint8_t a, b;
} cb_sink_event;

cb_sink *cb_sink_open(void);
void cb_sink_close(cb_sink *s);
int cb_sink_open_stream(cb_sink *s, uint32_t stream, uint8_t codec, uint8_t profile,
                        uint8_t depth, unsigned w, unsigned h, unsigned *tag, int *mode);
int cb_sink_frame(cb_sink *s, uint32_t stream, uint32_t seq, uint32_t surface, unsigned flags,
                  unsigned w, unsigned h, const uint8_t *data, size_t len);
int cb_sink_surface(cb_sink *s, uint32_t surface, uint64_t dev, uint64_t ino);
int cb_sink_surface_gone(cb_sink *s, uint32_t surface);
int cb_sink_close_stream(cb_sink *s, uint32_t stream, uint8_t reason);
int cb_sink_poll(cb_sink *s, cb_sink_event *ev);

/* Local decoding, the fallback (local.c) */
cb_local *cb_local_new(cb_context *c);
void cb_local_free(cb_local *l);
/* Decodes one unit; pixels land in the surface that frame `seq` was decoded into,
 * if it still holds that frame. */
void cb_local_decode(cb_local *l, uint32_t seq, const uint8_t *data, size_t len);

#endif
