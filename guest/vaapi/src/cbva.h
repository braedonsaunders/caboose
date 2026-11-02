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
#include "gpu_media.h"
#include "proto.h"

#define CB_UNSUPPORTED (-2)

typedef struct cb_driver cb_driver;
typedef struct cb_context cb_context;
typedef struct cb_local cb_local;
typedef struct cb_gpu cb_gpu;

/* A stream's pictures go to the phone over the media connection and its surfaces
 * name them (gpu_media.h), or the driver decodes them itself (local.c). */
#define CB_MODE_GPU 1
#define CB_MODE_DECODE 2

/* Why a GPU stream decodes locally from now on (logged). */
#define CB_LOCAL_READBACK 1    /* the app read pixels back */
#define CB_LOCAL_PHONE 2       /* the phone failed the stream */
#define CB_LOCAL_UNSUPPORTED 3 /* the bitstream cannot be rebuilt, or a surface carries no identity */
#define CB_LOCAL_ERROR 4       /* the media connection failed */

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
    int memfd;      /* our memory, or -1 when imported or on vgem */
    int dmabuf;     /* udmabuf over memfd, a vgem buffer, or the imported dmabuf; -1 if none */
    int imported;
    uint8_t *map;
    cb_gm_identity_page *identity; /* the last page of our own surfaces; NULL when imported */
    int gpu_announced; /* the phone may retain a picture for it */
    int pending;       /* it holds no pixels of its latest picture */
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
    int shared;       /* `data` belongs to an earlier slice */
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
     * decode target (AV1 film grain); it carries the identity and the pixels. */
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
    uint32_t stream;   /* id on the media connection */
    int mode;          /* CB_MODE_* */
    int unsupported;
    /* Bitstream since the last key frame: replayed to the phone on request
     * and into the local decoder when this stream falls back. */
    cb_buf gop;
    cb_gop_entry *gop_entries;
    unsigned gop_count, gop_cap;
    int gop_valid; /* the buffer starts at a key frame and is complete */
    cb_local *local;
    VASurfaceID seq_surface[CB_SEQ_MAP];
    uint32_t seq_of[CB_SEQ_MAP];
    uint64_t seq_serial[CB_SEQ_MAP]; /* GPU mode: the serial each picture's surface names */
};

struct cb_driver {
    pthread_mutex_t lock;
    void **objs[5];
    unsigned nobjs[5];
    int udmabuf;
    int vgem;       /* vgem's primary node, the exporter when udmabuf is missing; -1 if none */
    int force_decode;
    uint32_t next_stream;
    cb_gpu *gpu;          /* the media connection to the phone, or NULL */
    uint8_t token[16];    /* names this driver's pictures in surface identities */
    uint64_t next_serial; /* the last serial written to a surface identity */
};

enum { CB_OBJ_CONFIG, CB_OBJ_CONTEXT, CB_OBJ_SURFACE, CB_OBJ_BUFFER, CB_OBJ_IMAGE };

void *cb_obj(cb_driver *d, int kind, unsigned id);
cb_surface *cb_get_surface(cb_driver *d, VASurfaceID id);

/* Hands one unit of rebuilt bitstream for picture `seq` to the stream. */
void cb_emit(cb_context *c, uint32_t seq, VASurfaceID surface, unsigned flags,
             const uint8_t *data, size_t len, unsigned w, unsigned h);
/* Marks the stream as using something the rebuild cannot express. */
void cb_unsupported(cb_context *c, const char *why);
void cb_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

/* Surfaces (surface.c) */
int cb_vgem_open(void);
VAStatus cb_surface_alloc(cb_driver *d, cb_surface *s, unsigned w, unsigned h, uint32_t fourcc);
VAStatus cb_surface_import(cb_driver *d, cb_surface *s, const VADRMPRIMESurfaceDescriptor *desc);
void cb_surface_free(cb_surface *s);
void cb_surface_begin_cpu(cb_surface *s);
void cb_surface_end_cpu(cb_surface *s);
/* Surface identities (gpu_media.h): the picture `serial` decoded on the phone,
 * new pixels in the planes, or neither. No-ops on imported surfaces. */
void cb_surface_phone(cb_driver *d, cb_surface *s, uint64_t serial);
void cb_surface_pixels(cb_driver *d, cb_surface *s);
void cb_surface_empty(cb_driver *d, cb_surface *s);
VAStatus cb_surface_export(cb_surface *s, uint32_t mem_type, uint32_t flags, void *descriptor);

/* The media connection to the phone (gpu.c) */
typedef struct {
    uint32_t type; /* CB_GM_FAIL or CB_GM_REPLAY */
    uint32_t stream;
    uint32_t reason;
} cb_gpu_event;

/* Connects when $CABOOSE_GFXSTREAM_SOCKET names a broker whose phone answers. */
cb_gpu *cb_gpu_open(void);
void cb_gpu_close(cb_gpu *g);
const uint8_t *cb_gpu_token(const cb_gpu *g);
/* The Caboose Vulkan driver is loaded in this process: it latches the phone's
 * pictures into the images that sample our surfaces. */
int cb_gpu_consumer_present(void);
int cb_gpu_supports(const cb_gpu *g, uint8_t codec, unsigned depth, unsigned w, unsigned h);
int cb_gpu_open_stream(cb_gpu *g, uint32_t stream, uint8_t codec, unsigned depth, unsigned w, unsigned h);
int cb_gpu_unit(cb_gpu *g, uint32_t stream, uint32_t seq, uint32_t surface, unsigned flags,
                uint64_t serial, unsigned w, unsigned h, const uint8_t *data, size_t len);
int cb_gpu_close_stream(cb_gpu *g, uint32_t stream);
int cb_gpu_surface_gone(cb_gpu *g, uint32_t surface);
/* Returns 1 with an event, 0 when none is pending, -1 on a failed connection. */
int cb_gpu_poll(cb_gpu *g, cb_gpu_event *ev);

/* Local decoding, the fallback (local.c) */
cb_local *cb_local_new(cb_context *c);
void cb_local_free(cb_local *l);
/* Decodes one unit; pixels land in the surface that frame `seq` was decoded into,
 * if it still holds that frame. */
void cb_local_decode(cb_local *l, uint32_t seq, const uint8_t *data, size_t len);

#endif
