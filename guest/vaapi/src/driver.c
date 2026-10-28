/* caboose_drv_video.so: the libva driver entry point and objects.
 *
 * The driver advertises H.264, HEVC, VP9 and AV1 decoding. It does not decode:
 * each picture's parameter and slice buffers are rebuilt into the compressed
 * bitstream (h264.c, hevc.c, vp9.c, av1.c) and sent to caboose-display, which
 * forwards it to the client; the surface the app gets back holds the marker
 * (marker.h) that tells the compositor where the client should layer the video.
 * When passthrough cannot serve a stream, the same bitstream is decoded locally
 * (local.c) into the app's surfaces. docs/display.md is the design. */
#define _GNU_SOURCE
#include "cbva.h"

#include <drm_fourcc.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <va/va_drmcommon.h>

#define MAX_SIZE 8192

static int log_enabled = -1;

void cb_log(const char *fmt, ...)
{
    if (log_enabled < 0) {
        const char *e = getenv("CABOOSE_VA_LOG");
        log_enabled = e && *e && strcmp(e, "0") != 0;
    }
    if (!log_enabled)
        return;
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "caboose-va: ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
}

#define DRV(ctx) ((cb_driver *)(ctx)->pDriverData)
#define LOCK(d) pthread_mutex_lock(&(d)->lock)
#define UNLOCK(d) pthread_mutex_unlock(&(d)->lock)

/* ---- Objects ------------------------------------------------------------- */

static unsigned obj_id(int kind, unsigned index) { return ((unsigned)(kind + 1) << 24) | index; }

void *cb_obj(cb_driver *d, int kind, unsigned id)
{
    if ((id >> 24) != (unsigned)(kind + 1))
        return NULL;
    unsigned i = id & 0xffffff;
    return i < d->nobjs[kind] ? d->objs[kind][i] : NULL;
}

cb_surface *cb_get_surface(cb_driver *d, VASurfaceID id) { return cb_obj(d, CB_OBJ_SURFACE, id); }

static unsigned obj_add(cb_driver *d, int kind, void *p)
{
    for (unsigned i = 0; i < d->nobjs[kind]; i++)
        if (!d->objs[kind][i]) {
            d->objs[kind][i] = p;
            return obj_id(kind, i);
        }
    void **n = realloc(d->objs[kind], sizeof(void *) * (d->nobjs[kind] + 64));
    if (!n)
        return VA_INVALID_ID;
    memset(n + d->nobjs[kind], 0, sizeof(void *) * 64);
    d->objs[kind] = n;
    unsigned i = d->nobjs[kind];
    d->nobjs[kind] += 64;
    n[i] = p;
    return obj_id(kind, i);
}

static void obj_remove(cb_driver *d, int kind, unsigned id)
{
    if (cb_obj(d, kind, id))
        d->objs[kind][id & 0xffffff] = NULL;
}

/* ---- Profiles ------------------------------------------------------------ */

static const struct {
    VAProfile profile;
    const cb_codec *codec;
    unsigned rt;
} profiles[] = {
    { VAProfileH264ConstrainedBaseline, &cb_codec_h264, VA_RT_FORMAT_YUV420 },
    { VAProfileH264Main, &cb_codec_h264, VA_RT_FORMAT_YUV420 },
    { VAProfileH264High, &cb_codec_h264, VA_RT_FORMAT_YUV420 },
    { VAProfileH264High10, &cb_codec_h264, VA_RT_FORMAT_YUV420 | VA_RT_FORMAT_YUV420_10 },
    { VAProfileHEVCMain, &cb_codec_hevc, VA_RT_FORMAT_YUV420 },
    { VAProfileHEVCMain10, &cb_codec_hevc, VA_RT_FORMAT_YUV420 | VA_RT_FORMAT_YUV420_10 },
    { VAProfileVP9Profile0, &cb_codec_vp9, VA_RT_FORMAT_YUV420 },
    { VAProfileVP9Profile2, &cb_codec_vp9, VA_RT_FORMAT_YUV420 | VA_RT_FORMAT_YUV420_10 },
    { VAProfileAV1Profile0, &cb_codec_av1, VA_RT_FORMAT_YUV420 | VA_RT_FORMAT_YUV420_10 },
};
#define NPROFILES (sizeof(profiles) / sizeof(profiles[0]))

static int profile_index(VAProfile p)
{
    for (unsigned i = 0; i < NPROFILES; i++)
        if (profiles[i].profile == p && profiles[i].codec)
            return (int)i;
    return -1;
}

static VAStatus query_profiles(VADriverContextP ctx, VAProfile *list, int *num)
{
    (void)ctx;
    int n = 0;
    for (unsigned i = 0; i < NPROFILES; i++)
        list[n++] = profiles[i].profile;
    *num = n;
    return VA_STATUS_SUCCESS;
}

static VAStatus query_entrypoints(VADriverContextP ctx, VAProfile profile, VAEntrypoint *list, int *num)
{
    (void)ctx;
    if (profile_index(profile) < 0) {
        *num = 0;
        return VA_STATUS_ERROR_UNSUPPORTED_PROFILE;
    }
    list[0] = VAEntrypointVLD;
    *num = 1;
    return VA_STATUS_SUCCESS;
}

static void fill_attribs(int pi, VAConfigAttrib *a, int n)
{
    for (int i = 0; i < n; i++) {
        switch (a[i].type) {
        case VAConfigAttribRTFormat: a[i].value = profiles[pi].rt; break;
        case VAConfigAttribDecSliceMode: a[i].value = VA_DEC_SLICE_MODE_NORMAL; break;
        case VAConfigAttribMaxPictureWidth:
        case VAConfigAttribMaxPictureHeight: a[i].value = MAX_SIZE; break;
        default: a[i].value = VA_ATTRIB_NOT_SUPPORTED; break;
        }
    }
}

static VAStatus get_config_attributes(VADriverContextP ctx, VAProfile profile, VAEntrypoint ep,
                                      VAConfigAttrib *a, int n)
{
    (void)ctx;
    int pi = profile_index(profile);
    if (pi < 0)
        return VA_STATUS_ERROR_UNSUPPORTED_PROFILE;
    if (ep != VAEntrypointVLD)
        return VA_STATUS_ERROR_UNSUPPORTED_ENTRYPOINT;
    fill_attribs(pi, a, n);
    return VA_STATUS_SUCCESS;
}

static VAStatus create_config(VADriverContextP ctx, VAProfile profile, VAEntrypoint ep,
                              VAConfigAttrib *a, int n, VAConfigID *out)
{
    cb_driver *d = DRV(ctx);
    int pi = profile_index(profile);
    if (pi < 0)
        return VA_STATUS_ERROR_UNSUPPORTED_PROFILE;
    if (ep != VAEntrypointVLD)
        return VA_STATUS_ERROR_UNSUPPORTED_ENTRYPOINT;
    cb_config *c = calloc(1, sizeof(*c));
    if (!c)
        return VA_STATUS_ERROR_ALLOCATION_FAILED;
    c->profile = profile;
    c->entrypoint = ep;
    c->rt_format = profiles[pi].rt;
    for (int i = 0; i < n; i++) {
        if (a[i].type == VAConfigAttribRTFormat) {
            if (!(a[i].value & profiles[pi].rt)) {
                free(c);
                return VA_STATUS_ERROR_UNSUPPORTED_RT_FORMAT;
            }
            c->rt_format = a[i].value;
        }
    }
    LOCK(d);
    *out = obj_add(d, CB_OBJ_CONFIG, c);
    UNLOCK(d);
    if (*out == VA_INVALID_ID) {
        free(c);
        return VA_STATUS_ERROR_ALLOCATION_FAILED;
    }
    return VA_STATUS_SUCCESS;
}

static VAStatus destroy_config(VADriverContextP ctx, VAConfigID id)
{
    cb_driver *d = DRV(ctx);
    LOCK(d);
    cb_config *c = cb_obj(d, CB_OBJ_CONFIG, id);
    obj_remove(d, CB_OBJ_CONFIG, id);
    UNLOCK(d);
    if (!c)
        return VA_STATUS_ERROR_INVALID_CONFIG;
    free(c);
    return VA_STATUS_SUCCESS;
}

static VAStatus query_config_attributes(VADriverContextP ctx, VAConfigID id, VAProfile *profile,
                                        VAEntrypoint *ep, VAConfigAttrib *a, int *n)
{
    cb_driver *d = DRV(ctx);
    LOCK(d);
    cb_config *c = cb_obj(d, CB_OBJ_CONFIG, id);
    if (!c) {
        UNLOCK(d);
        return VA_STATUS_ERROR_INVALID_CONFIG;
    }
    *profile = c->profile;
    *ep = c->entrypoint;
    a[0].type = VAConfigAttribRTFormat;
    a[0].value = c->rt_format;
    *n = 1;
    UNLOCK(d);
    return VA_STATUS_SUCCESS;
}

/* ---- Surfaces ------------------------------------------------------------ */

static VAStatus create_surfaces2(VADriverContextP ctx, unsigned format, unsigned w, unsigned h,
                                 VASurfaceID *out, unsigned n, VASurfaceAttrib *attribs,
                                 unsigned nattribs)
{
    cb_driver *d = DRV(ctx);
    uint32_t fourcc;
    if (format & VA_RT_FORMAT_YUV420_10)
        fourcc = VA_FOURCC_P010;
    else if (format & VA_RT_FORMAT_YUV420)
        fourcc = VA_FOURCC_NV12;
    else
        return VA_STATUS_ERROR_UNSUPPORTED_RT_FORMAT;
    if (!w || !h || w > MAX_SIZE || h > MAX_SIZE)
        return VA_STATUS_ERROR_RESOLUTION_NOT_SUPPORTED;
    uint32_t mem = VA_SURFACE_ATTRIB_MEM_TYPE_VA;
    const VADRMPRIMESurfaceDescriptor *prime2 = NULL;
    const VASurfaceAttribExternalBuffers *prime = NULL;
    for (unsigned i = 0; i < nattribs; i++) {
        if (!(attribs[i].flags & VA_SURFACE_ATTRIB_SETTABLE))
            continue;
        switch (attribs[i].type) {
        case VASurfaceAttribPixelFormat:
            if (attribs[i].value.value.i != VA_FOURCC_NV12 && attribs[i].value.value.i != VA_FOURCC_P010)
                return VA_STATUS_ERROR_UNSUPPORTED_RT_FORMAT;
            fourcc = (uint32_t)attribs[i].value.value.i;
            break;
        case VASurfaceAttribMemoryType: mem = (uint32_t)attribs[i].value.value.i; break;
        case VASurfaceAttribExternalBufferDescriptor:
            prime2 = attribs[i].value.value.p;
            prime = attribs[i].value.value.p;
            break;
        default: break;
        }
    }
    if (mem != VA_SURFACE_ATTRIB_MEM_TYPE_VA && mem != VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME &&
        mem != VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2)
        return VA_STATUS_ERROR_UNSUPPORTED_MEMORY_TYPE;
    if (mem == VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2 && (!prime2 || n != 1))
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    if (mem == VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME && (!prime || prime->num_buffers < n))
        return VA_STATUS_ERROR_INVALID_PARAMETER;

    VAStatus st = VA_STATUS_SUCCESS;
    unsigned made = 0;
    for (; made < n; made++) {
        cb_surface *s = calloc(1, sizeof(*s));
        if (!s) {
            st = VA_STATUS_ERROR_ALLOCATION_FAILED;
            break;
        }
        if (mem == VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2) {
            st = cb_surface_import(d, s, prime2);
        } else if (mem == VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME) {
            VADRMPRIMESurfaceDescriptor desc = { 0 };
            desc.fourcc = prime->pixel_format;
            desc.width = prime->width;
            desc.height = prime->height;
            desc.num_objects = 1;
            desc.objects[0].fd = (int)prime->buffers[made];
            desc.objects[0].size = prime->data_size;
            desc.objects[0].drm_format_modifier = DRM_FORMAT_MOD_INVALID;
            desc.num_layers = 1;
            desc.layers[0].num_planes = prime->num_planes;
            for (unsigned p = 0; p < prime->num_planes && p < 4; p++) {
                desc.layers[0].offset[p] = prime->offsets[p];
                desc.layers[0].pitch[p] = prime->pitches[p];
            }
            st = cb_surface_import(d, s, &desc);
        } else {
            st = cb_surface_alloc(d, s, w, h, fourcc);
        }
        if (st != VA_STATUS_SUCCESS) {
            free(s);
            break;
        }
        LOCK(d);
        s->id = obj_add(d, CB_OBJ_SURFACE, s);
        UNLOCK(d);
        if (s->id == VA_INVALID_ID) {
            cb_surface_free(s);
            free(s);
            st = VA_STATUS_ERROR_ALLOCATION_FAILED;
            break;
        }
        out[made] = s->id;
    }
    if (st != VA_STATUS_SUCCESS) {
        LOCK(d);
        for (unsigned i = 0; i < made; i++) {
            cb_surface *s = cb_get_surface(d, out[i]);
            obj_remove(d, CB_OBJ_SURFACE, out[i]);
            cb_surface_free(s);
            free(s);
        }
        UNLOCK(d);
    }
    return st;
}

static VAStatus create_surfaces(VADriverContextP ctx, int w, int h, int format, int n, VASurfaceID *out)
{
    return create_surfaces2(ctx, (unsigned)format, (unsigned)w, (unsigned)h, out, (unsigned)n, NULL, 0);
}

static VAStatus destroy_surfaces(VADriverContextP ctx, VASurfaceID *list, int n)
{
    cb_driver *d = DRV(ctx);
    LOCK(d);
    for (int i = 0; i < n; i++) {
        cb_surface *s = cb_get_surface(d, list[i]);
        if (!s)
            continue;
        if (s->announced && d->sink)
            cb_sink_surface_gone(d->sink, s->id);
        obj_remove(d, CB_OBJ_SURFACE, list[i]);
        cb_surface_free(s);
        free(s);
    }
    UNLOCK(d);
    return VA_STATUS_SUCCESS;
}

static VAStatus query_surface_attributes(VADriverContextP ctx, VAConfigID config, VASurfaceAttrib *a,
                                         unsigned *n)
{
    cb_driver *d = DRV(ctx);
    LOCK(d);
    cb_config *c = cb_obj(d, CB_OBJ_CONFIG, config);
    unsigned rt = c ? c->rt_format : 0;
    UNLOCK(d);
    if (!c)
        return VA_STATUS_ERROR_INVALID_CONFIG;
    VASurfaceAttrib list[8];
    unsigned k = 0;
    if (rt & VA_RT_FORMAT_YUV420_10)
        list[k++] = (VASurfaceAttrib){ VASurfaceAttribPixelFormat,
                                        VA_SURFACE_ATTRIB_GETTABLE | VA_SURFACE_ATTRIB_SETTABLE,
                                        { VAGenericValueTypeInteger, { .i = VA_FOURCC_P010 } } };
    if (rt & VA_RT_FORMAT_YUV420)
        list[k++] = (VASurfaceAttrib){ VASurfaceAttribPixelFormat,
                                        VA_SURFACE_ATTRIB_GETTABLE | VA_SURFACE_ATTRIB_SETTABLE,
                                        { VAGenericValueTypeInteger, { .i = VA_FOURCC_NV12 } } };
    list[k++] = (VASurfaceAttrib){ VASurfaceAttribMemoryType,
                                    VA_SURFACE_ATTRIB_GETTABLE | VA_SURFACE_ATTRIB_SETTABLE,
                                    { VAGenericValueTypeInteger,
                                      { .i = VA_SURFACE_ATTRIB_MEM_TYPE_VA | VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME |
                                             VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2 } } };
    list[k++] = (VASurfaceAttrib){ VASurfaceAttribExternalBufferDescriptor, VA_SURFACE_ATTRIB_SETTABLE,
                                    { VAGenericValueTypePointer, { .p = NULL } } };
    list[k++] = (VASurfaceAttrib){ VASurfaceAttribMinWidth, VA_SURFACE_ATTRIB_GETTABLE,
                                    { VAGenericValueTypeInteger, { .i = 16 } } };
    list[k++] = (VASurfaceAttrib){ VASurfaceAttribMinHeight, VA_SURFACE_ATTRIB_GETTABLE,
                                    { VAGenericValueTypeInteger, { .i = 16 } } };
    list[k++] = (VASurfaceAttrib){ VASurfaceAttribMaxWidth, VA_SURFACE_ATTRIB_GETTABLE,
                                    { VAGenericValueTypeInteger, { .i = MAX_SIZE } } };
    list[k++] = (VASurfaceAttrib){ VASurfaceAttribMaxHeight, VA_SURFACE_ATTRIB_GETTABLE,
                                    { VAGenericValueTypeInteger, { .i = MAX_SIZE } } };
    if (!a) {
        *n = k;
        return VA_STATUS_SUCCESS;
    }
    if (*n < k) {
        *n = k;
        return VA_STATUS_ERROR_MAX_NUM_EXCEEDED;
    }
    memcpy(a, list, sizeof(VASurfaceAttrib) * k);
    *n = k;
    return VA_STATUS_SUCCESS;
}

/* ---- Streams: passthrough, and the switch to local decoding --------------- */

static void gop_reset(cb_context *c)
{
    cb_buf_reset(&c->gop);
    c->gop_count = 0;
}

/* Drops the entries before index `keep`. */
static void gop_trim(cb_context *c, unsigned keep)
{
    if (!keep)
        return;
    size_t off = keep < c->gop_count ? c->gop_entries[keep].off : c->gop.len;
    memmove(c->gop.data, c->gop.data + off, c->gop.len - off);
    c->gop.len -= off;
    memmove(c->gop_entries, c->gop_entries + keep, sizeof(cb_gop_entry) * (c->gop_count - keep));
    c->gop_count -= keep;
    for (unsigned i = 0; i < c->gop_count; i++)
        c->gop_entries[i].off -= off;
}

/* The buffer holds the last two GOPs: an app that decodes ahead may still read
 * back pictures from before the newest key frame. */
static void gop_add(cb_context *c, uint32_t seq, VASurfaceID surface, unsigned flags,
                    const uint8_t *data, size_t len, unsigned w, unsigned h)
{
    if (flags & CB_FRAME_KEY) {
        if (!c->gop_valid) {
            gop_reset(c);
            c->gop_valid = 1;
        } else {
            /* Keep the GOP that is ending; drop the one before it. */
            unsigned last_key = 0;
            for (unsigned i = 0; i < c->gop_count; i++)
                if (c->gop_entries[i].flags & CB_FRAME_KEY)
                    last_key = i;
            gop_trim(c, last_key);
        }
    }
    if (!c->gop_valid)
        return;
    while (c->gop.len + len > CB_GOP_LIMIT && c->gop_count) {
        /* Too long: drop the older GOP; if only one is left, stop until the next key frame. */
        unsigned next = 0;
        for (unsigned i = 1; i < c->gop_count && !next; i++)
            if (c->gop_entries[i].flags & CB_FRAME_KEY)
                next = i;
        if (!next) {
            gop_reset(c);
            c->gop_valid = 0;
            return;
        }
        gop_trim(c, next);
    }
    if (c->gop_count == c->gop_cap) {
        unsigned cap = c->gop_cap ? c->gop_cap * 2 : 64;
        cb_gop_entry *e = realloc(c->gop_entries, sizeof(*e) * cap);
        if (!e) {
            c->gop_valid = 0;
            return;
        }
        c->gop_entries = e;
        c->gop_cap = cap;
    }
    c->gop_entries[c->gop_count++] = (cb_gop_entry){ seq, surface, flags, (uint16_t)w, (uint16_t)h,
                                                     c->gop.len, len };
    cb_buf_append(&c->gop, data, len);
    if (c->gop.oom) {
        gop_reset(c);
        c->gop_valid = 0;
    }
}

static void sink_failed(cb_driver *d);

static void switch_to_decode(cb_context *c, uint8_t reason)
{
    if (c->mode == CB_MODE_DECODE)
        return;
    cb_driver *d = c->drv;
    c->mode = CB_MODE_DECODE;
    cb_log("stream %u (%s): decoding locally (reason %u)", c->stream, c->codec->name, reason);
    if (d->sink && reason != CB_CLOSE_ERROR && cb_sink_close_stream(d->sink, c->stream, reason))
        sink_failed(d);
    c->local = cb_local_new(c);
    if (!c->local) {
        cb_log("stream %u: no local %s decoder", c->stream, c->codec->name);
        return;
    }
    /* Catch up from the last key frame so the surfaces in use get their pixels. */
    if (c->gop_valid)
        for (unsigned i = 0; i < c->gop_count; i++)
            cb_local_decode(c->local, c->gop_entries[i].seq, c->gop.data + c->gop_entries[i].off,
                            c->gop_entries[i].len);
}

static void sink_failed(cb_driver *d)
{
    cb_sink *s = d->sink;
    if (!s)
        return;
    cb_log("video socket failed; every stream decodes locally");
    d->sink = NULL;
    cb_sink_close(s);
    for (unsigned i = 0; i < d->nobjs[CB_OBJ_CONTEXT]; i++) {
        cb_context *c = d->objs[CB_OBJ_CONTEXT][i];
        if (c)
            switch_to_decode(c, CB_CLOSE_ERROR);
    }
}

static cb_context *context_by_stream(cb_driver *d, uint32_t stream)
{
    for (unsigned i = 0; i < d->nobjs[CB_OBJ_CONTEXT]; i++) {
        cb_context *c = d->objs[CB_OBJ_CONTEXT][i];
        if (c && c->stream == stream)
            return c;
    }
    return NULL;
}

static void replay(cb_context *c)
{
    cb_driver *d = c->drv;
    if (c->mode != CB_MODE_PASSTHROUGH || !d->sink || !c->gop_valid)
        return;
    unsigned from = 0;
    for (unsigned i = 0; i < c->gop_count; i++)
        if (c->gop_entries[i].flags & CB_FRAME_KEY)
            from = i;
    for (unsigned i = from; i < c->gop_count && d->sink; i++) {
        cb_gop_entry *e = &c->gop_entries[i];
        if (cb_sink_frame(d->sink, c->stream, e->seq, e->surface, e->flags | CB_FRAME_REPLAY, e->w, e->h,
                          c->gop.data + e->off, e->len))
            sink_failed(d);
    }
}

static void poll_sink(cb_driver *d)
{
    cb_sink_event ev;
    int r;
    while (d->sink && (r = cb_sink_poll(d->sink, &ev)) != 0) {
        if (r < 0) {
            sink_failed(d);
            return;
        }
        cb_context *c = context_by_stream(d, ev.stream);
        if (!c)
            continue;
        if (ev.type == CB_MSG_DECODE)
            switch_to_decode(c, CB_CLOSE_REQUESTED);
        else if (ev.type == CB_MSG_REPLAY)
            replay(c);
    }
}

void cb_emit(cb_context *c, uint32_t seq, VASurfaceID surface, unsigned flags, const uint8_t *data,
             size_t len, unsigned w, unsigned h)
{
    cb_driver *d = c->drv;
    gop_add(c, seq, surface, flags, data, len, w, h);
    if (c->mode == CB_MODE_PASSTHROUGH) {
        if (d->sink && cb_sink_frame(d->sink, c->stream, seq, surface, flags, w, h, data, len))
            sink_failed(d);
    } else if (c->local) {
        cb_local_decode(c->local, seq, data, len);
    }
}

/* The rebuild cannot express this stream: every later vaEndPicture fails, so
 * the app falls back to its own software decoder. */
void cb_unsupported(cb_context *c, const char *why)
{
    if (c->unsupported)
        return;
    cb_log("stream %u (%s): cannot rebuild: %s", c->stream, c->codec->name, why);
    c->unsupported = 1;
    if (c->mode == CB_MODE_PASSTHROUGH) {
        c->mode = CB_MODE_DECODE;
        if (c->drv->sink && cb_sink_close_stream(c->drv->sink, c->stream, CB_CLOSE_UNSUPPORTED))
            sink_failed(c->drv);
    }
}

/* The app is about to use a surface's pixels (sync, export, read back). In local
 * decoding, a picture the codec is still holding back is decoded now. */
static void need_pixels(cb_driver *d, cb_surface *s, int readback)
{
    cb_context *c = cb_obj(d, CB_OBJ_CONTEXT, s->owner);
    if (!c)
        return;
    if (readback && c->mode == CB_MODE_PASSTHROUGH && s->mark >= 0)
        switch_to_decode(c, CB_CLOSE_READBACK);
    if (c->mode == CB_MODE_DECODE && c->local && c->codec->provisional && s->mark >= 0) {
        cb_buf b = { 0 };
        uint32_t seq;
        if (c->codec->provisional(c, &b, &seq) == 0 && seq == s->seq && b.len)
            cb_local_decode(c->local, seq, b.data, b.len);
        cb_buf_free(&b);
    }
}

/* ---- Contexts ------------------------------------------------------------- */

static VAStatus create_context(VADriverContextP ctx, VAConfigID config, int w, int h, int flag,
                               VASurfaceID *targets, int ntargets, VAContextID *out)
{
    (void)flag;
    (void)targets;
    (void)ntargets;
    cb_driver *d = DRV(ctx);
    LOCK(d);
    cb_config *cfg = cb_obj(d, CB_OBJ_CONFIG, config);
    if (!cfg) {
        UNLOCK(d);
        return VA_STATUS_ERROR_INVALID_CONFIG;
    }
    int pi = profile_index(cfg->profile);
    cb_context *c = calloc(1, sizeof(*c));
    if (!c || pi < 0) {
        free(c);
        UNLOCK(d);
        return VA_STATUS_ERROR_ALLOCATION_FAILED;
    }
    c->drv = d;
    c->profile = cfg->profile;
    c->codec = profiles[pi].codec;
    c->width = (unsigned)w;
    c->height = (unsigned)h;
    c->state = calloc(1, c->codec->state_size ? c->codec->state_size : 1);
    for (unsigned i = 0; i < CB_SEQ_MAP; i++) {
        c->seq_surface[i] = VA_INVALID_SURFACE;
        c->seq_of[i] = UINT32_MAX;
    }
    c->id = c->state ? obj_add(d, CB_OBJ_CONTEXT, c) : VA_INVALID_ID;
    if (c->id == VA_INVALID_ID) {
        free(c->state);
        free(c);
        UNLOCK(d);
        return VA_STATUS_ERROR_ALLOCATION_FAILED;
    }
    c->stream = ++d->next_stream;
    c->mode = CB_MODE_DECODE;
    if (d->sink && !d->force_decode) {
        unsigned depth = (cfg->rt_format & VA_RT_FORMAT_YUV420_10) ? 10 : 8;
        unsigned tag;
        int mode;
        int r = cb_sink_open_stream(d->sink, c->stream, c->codec->id, 0, (uint8_t)depth, c->width,
                                    c->height, &tag, &mode);
        if (r == 0) {
            c->tag = tag;
            c->mode = mode == CB_MODE_PASSTHROUGH ? CB_MODE_PASSTHROUGH : CB_MODE_DECODE;
        } else if (r == -1 || cb_sink_close_stream(d->sink, c->stream, CB_CLOSE_ERROR)) {
            sink_failed(d);
        }
    }
    if (c->mode == CB_MODE_DECODE) {
        c->local = cb_local_new(c);
        if (!c->local)
            cb_log("stream %u: no local %s decoder", c->stream, c->codec->name);
    }
    cb_log("stream %u: %s %ux%u, %s", c->stream, c->codec->name, c->width, c->height,
           c->mode == CB_MODE_PASSTHROUGH ? "passthrough" : "local decode");
    *out = c->id;
    UNLOCK(d);
    return VA_STATUS_SUCCESS;
}

static void picture_clear(cb_picture *p)
{
    free(p->pp);
    free(p->iq);
    for (unsigned i = 0; i < p->nslices; i++) {
        free(p->slices[i].params);
        free(p->slices[i].data);
    }
    p->pp = p->iq = NULL;
    p->pp_size = p->iq_size = 0;
    p->nslices = 0;
}

static VAStatus destroy_context(VADriverContextP ctx, VAContextID id)
{
    cb_driver *d = DRV(ctx);
    LOCK(d);
    cb_context *c = cb_obj(d, CB_OBJ_CONTEXT, id);
    if (!c) {
        UNLOCK(d);
        return VA_STATUS_ERROR_INVALID_CONTEXT;
    }
    if (c->codec->flush)
        c->codec->flush(c);
    if (c->mode == CB_MODE_PASSTHROUGH && d->sink && cb_sink_close_stream(d->sink, c->stream, CB_CLOSE_APP))
        sink_failed(d);
    obj_remove(d, CB_OBJ_CONTEXT, id);
    UNLOCK(d);
    if (c->codec->fini)
        c->codec->fini(c);
    cb_local_free(c->local);
    picture_clear(&c->pic);
    free(c->pic.slices);
    cb_buf_free(&c->gop);
    free(c->gop_entries);
    free(c->state);
    free(c);
    return VA_STATUS_SUCCESS;
}

/* ---- Buffers ------------------------------------------------------------- */

static VAStatus create_buffer(VADriverContextP ctx, VAContextID context, VABufferType type,
                              unsigned size, unsigned num, void *data, VABufferID *out)
{
    (void)context;
    cb_driver *d = DRV(ctx);
    if (!size || !num || (uint64_t)size * num > (1u << 30))
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    cb_buffer *b = calloc(1, sizeof(*b));
    if (!b)
        return VA_STATUS_ERROR_ALLOCATION_FAILED;
    b->type = type;
    b->elem_size = size;
    b->count = num;
    b->derived = VA_INVALID_SURFACE;
    b->data = malloc((size_t)size * num);
    if (!b->data) {
        free(b);
        return VA_STATUS_ERROR_ALLOCATION_FAILED;
    }
    if (data)
        memcpy(b->data, data, (size_t)size * num);
    LOCK(d);
    *out = obj_add(d, CB_OBJ_BUFFER, b);
    UNLOCK(d);
    if (*out == VA_INVALID_ID) {
        free(b->data);
        free(b);
        return VA_STATUS_ERROR_ALLOCATION_FAILED;
    }
    return VA_STATUS_SUCCESS;
}

static VAStatus buffer_set_num_elements(VADriverContextP ctx, VABufferID id, unsigned num)
{
    cb_driver *d = DRV(ctx);
    LOCK(d);
    cb_buffer *b = cb_obj(d, CB_OBJ_BUFFER, id);
    VAStatus st = VA_STATUS_SUCCESS;
    if (!b)
        st = VA_STATUS_ERROR_INVALID_BUFFER;
    else if (num > b->count)
        st = VA_STATUS_ERROR_INVALID_PARAMETER;
    else
        b->count = num;
    UNLOCK(d);
    return st;
}

static VAStatus map_buffer(VADriverContextP ctx, VABufferID id, void **p)
{
    cb_driver *d = DRV(ctx);
    LOCK(d);
    cb_buffer *b = cb_obj(d, CB_OBJ_BUFFER, id);
    if (!b) {
        UNLOCK(d);
        return VA_STATUS_ERROR_INVALID_BUFFER;
    }
    if (b->derived != VA_INVALID_SURFACE) {
        cb_surface *s = cb_get_surface(d, b->derived);
        if (!s) {
            UNLOCK(d);
            return VA_STATUS_ERROR_INVALID_SURFACE;
        }
        need_pixels(d, s, 1);
        cb_surface_begin_cpu(s);
    }
    b->mapped = 1;
    *p = b->data;
    UNLOCK(d);
    return VA_STATUS_SUCCESS;
}

static VAStatus unmap_buffer(VADriverContextP ctx, VABufferID id)
{
    cb_driver *d = DRV(ctx);
    LOCK(d);
    cb_buffer *b = cb_obj(d, CB_OBJ_BUFFER, id);
    if (b && b->mapped && b->derived != VA_INVALID_SURFACE) {
        cb_surface *s = cb_get_surface(d, b->derived);
        if (s)
            cb_surface_end_cpu(s);
    }
    if (b)
        b->mapped = 0;
    UNLOCK(d);
    return b ? VA_STATUS_SUCCESS : VA_STATUS_ERROR_INVALID_BUFFER;
}

static VAStatus destroy_buffer(VADriverContextP ctx, VABufferID id)
{
    cb_driver *d = DRV(ctx);
    LOCK(d);
    cb_buffer *b = cb_obj(d, CB_OBJ_BUFFER, id);
    obj_remove(d, CB_OBJ_BUFFER, id);
    UNLOCK(d);
    if (!b)
        return VA_STATUS_ERROR_INVALID_BUFFER;
    if (b->derived == VA_INVALID_SURFACE)
        free(b->data);
    free(b);
    return VA_STATUS_SUCCESS;
}

static VAStatus buffer_info(VADriverContextP ctx, VABufferID id, VABufferType *type, unsigned *size,
                            unsigned *num)
{
    cb_driver *d = DRV(ctx);
    LOCK(d);
    cb_buffer *b = cb_obj(d, CB_OBJ_BUFFER, id);
    if (b) {
        *type = b->type;
        *size = b->elem_size;
        *num = b->count;
    }
    UNLOCK(d);
    return b ? VA_STATUS_SUCCESS : VA_STATUS_ERROR_INVALID_BUFFER;
}

/* ---- Pictures ------------------------------------------------------------- */

static VAStatus begin_picture(VADriverContextP ctx, VAContextID id, VASurfaceID target)
{
    cb_driver *d = DRV(ctx);
    LOCK(d);
    cb_context *c = cb_obj(d, CB_OBJ_CONTEXT, id);
    cb_surface *s = cb_get_surface(d, target);
    if (!c || !s) {
        UNLOCK(d);
        return c ? VA_STATUS_ERROR_INVALID_SURFACE : VA_STATUS_ERROR_INVALID_CONTEXT;
    }
    picture_clear(&c->pic);
    c->pic.target = target;
    c->in_picture = 1;
    UNLOCK(d);
    return VA_STATUS_SUCCESS;
}

static void *dup_mem(const void *p, size_t n)
{
    void *q = malloc(n ? n : 1);
    if (q)
        memcpy(q, p, n);
    return q;
}

static VAStatus render_picture(VADriverContextP ctx, VAContextID id, VABufferID *buffers, int n)
{
    cb_driver *d = DRV(ctx);
    VAStatus st = VA_STATUS_SUCCESS;
    LOCK(d);
    cb_context *c = cb_obj(d, CB_OBJ_CONTEXT, id);
    if (!c || !c->in_picture) {
        UNLOCK(d);
        return c ? VA_STATUS_ERROR_OPERATION_FAILED : VA_STATUS_ERROR_INVALID_CONTEXT;
    }
    cb_picture *p = &c->pic;
    for (int i = 0; i < n && st == VA_STATUS_SUCCESS; i++) {
        cb_buffer *b = cb_obj(d, CB_OBJ_BUFFER, buffers[i]);
        if (!b) {
            st = VA_STATUS_ERROR_INVALID_BUFFER;
            break;
        }
        size_t size = (size_t)b->elem_size * b->count;
        switch (b->type) {
        case VAPictureParameterBufferType:
            free(p->pp);
            p->pp = dup_mem(b->data, size);
            p->pp_size = size;
            break;
        case VAIQMatrixBufferType:
            free(p->iq);
            p->iq = dup_mem(b->data, size);
            p->iq_size = size;
            break;
        case VASliceParameterBufferType:
        case VASliceDataBufferType: {
            /* Parameter and data buffers pair up in order, whichever comes first
             * (FFmpeg sends parameters first, Chromium's AV1 sends data first). */
            int is_data = b->type == VASliceDataBufferType;
            cb_slice *sl = NULL;
            for (unsigned k = 0; k < p->nslices && !sl; k++)
                if (is_data ? !p->slices[k].data : !p->slices[k].params)
                    sl = &p->slices[k];
            if (!sl) {
                if (p->nslices == p->cap) {
                    unsigned cap = p->cap ? p->cap * 2 : 16;
                    cb_slice *more = realloc(p->slices, sizeof(*more) * cap);
                    if (!more) {
                        st = VA_STATUS_ERROR_ALLOCATION_FAILED;
                        break;
                    }
                    p->slices = more;
                    p->cap = cap;
                }
                sl = &p->slices[p->nslices++];
                *sl = (cb_slice){ 0 };
            }
            if (is_data) {
                sl->data = dup_mem(b->data, size);
                sl->data_size = size;
            } else {
                sl->params = dup_mem(b->data, size);
                sl->count = b->count;
                sl->elem_size = b->elem_size;
            }
            break;
        }
        case VAEncryptionParameterBufferType:
        case VAProtectedSessionExecuteBufferType: st = VA_STATUS_ERROR_UNIMPLEMENTED; break;
        default: break; /* VP8 probabilities, Huffman tables: not for our codecs */
        }
    }
    UNLOCK(d);
    return st;
}

static VAStatus end_picture(VADriverContextP ctx, VAContextID id)
{
    cb_driver *d = DRV(ctx);
    LOCK(d);
    cb_context *c = cb_obj(d, CB_OBJ_CONTEXT, id);
    if (!c || !c->in_picture) {
        UNLOCK(d);
        return c ? VA_STATUS_ERROR_OPERATION_FAILED : VA_STATUS_ERROR_INVALID_CONTEXT;
    }
    c->in_picture = 0;
    poll_sink(d);
    cb_picture *p = &c->pic;
    cb_surface *s = cb_get_surface(d, p->target);
    VAStatus st = VA_STATUS_SUCCESS;
    for (unsigned i = 0; i < p->nslices; i++)
        if (!p->slices[i].data || !p->slices[i].params)
            st = VA_STATUS_ERROR_INVALID_BUFFER;
    if (!s)
        st = VA_STATUS_ERROR_INVALID_SURFACE;
    if (!p->pp)
        st = VA_STATUS_ERROR_INVALID_PARAMETER;
    if (c->unsupported)
        st = VA_STATUS_ERROR_DECODING_ERROR;
    if (st == VA_STATUS_SUCCESS) {
        uint32_t seq = c->next_seq++;
        cb_surface *shown = s;
        if (c->codec->display) {
            cb_surface *other = cb_get_surface(d, c->codec->display(c, p));
            if (other)
                shown = other;
        }
        c->seq_surface[seq % CB_SEQ_MAP] = shown->id;
        c->seq_of[seq % CB_SEQ_MAP] = seq;
        for (cb_surface *t = s; t; t = t == shown ? NULL : shown) {
            t->owner = c->id;
            t->seq = seq;
            if (c->mode == CB_MODE_PASSTHROUGH)
                cb_surface_mark(t, c->tag, seq);
            else
                t->mark = (int)((c->tag & 63) << 6 | (seq & 63)); /* no pixels until decoded */
        }
        int r = c->codec->picture(c, p, seq);
        if (r == CB_UNSUPPORTED || c->unsupported) {
            cb_unsupported(c, "picture");
            st = VA_STATUS_ERROR_DECODING_ERROR;
        } else if (r < 0) {
            st = VA_STATUS_ERROR_DECODING_ERROR;
        }
    }
    picture_clear(p);
    UNLOCK(d);
    return st;
}

static VAStatus sync_surface(VADriverContextP ctx, VASurfaceID id)
{
    cb_driver *d = DRV(ctx);
    LOCK(d);
    cb_surface *s = cb_get_surface(d, id);
    if (s)
        need_pixels(d, s, 0);
    UNLOCK(d);
    return s ? VA_STATUS_SUCCESS : VA_STATUS_ERROR_INVALID_SURFACE;
}

static VAStatus sync_surface2(VADriverContextP ctx, VASurfaceID id, uint64_t timeout)
{
    (void)timeout;
    return sync_surface(ctx, id);
}

static VAStatus query_surface_status(VADriverContextP ctx, VASurfaceID id, VASurfaceStatus *status)
{
    cb_driver *d = DRV(ctx);
    LOCK(d);
    cb_surface *s = cb_get_surface(d, id);
    UNLOCK(d);
    if (!s)
        return VA_STATUS_ERROR_INVALID_SURFACE;
    *status = VASurfaceReady;
    return VA_STATUS_SUCCESS;
}

static VAStatus query_surface_error(VADriverContextP ctx, VASurfaceID id, VAStatus error, void **info)
{
    (void)ctx;
    (void)id;
    (void)error;
    *info = NULL;
    return VA_STATUS_SUCCESS;
}

static VAStatus export_surface_handle(VADriverContextP ctx, VASurfaceID id, uint32_t mem_type,
                                      uint32_t flags, void *descriptor)
{
    cb_driver *d = DRV(ctx);
    LOCK(d);
    cb_surface *s = cb_get_surface(d, id);
    if (!s) {
        UNLOCK(d);
        return VA_STATUS_ERROR_INVALID_SURFACE;
    }
    need_pixels(d, s, 0);
    VAStatus st = cb_surface_export(s, mem_type, flags, descriptor);
    if (st == VA_STATUS_SUCCESS && !s->announced && d->sink) {
        s->announced = 1;
        if (cb_sink_surface(d->sink, s->id, s->dev, s->ino))
            sink_failed(d);
    }
    UNLOCK(d);
    return st;
}

/* ---- Images: readback ---------------------------------------------------- */

static const VAImageFormat image_formats[] = {
    { VA_FOURCC_NV12, VA_LSB_FIRST, 12, 0, 0, 0, 0, 0, { 0 } },
    { VA_FOURCC_P010, VA_LSB_FIRST, 24, 0, 0, 0, 0, 0, { 0 } },
};

static VAStatus query_image_formats(VADriverContextP ctx, VAImageFormat *list, int *num)
{
    (void)ctx;
    memcpy(list, image_formats, sizeof(image_formats));
    *num = (int)(sizeof(image_formats) / sizeof(image_formats[0]));
    return VA_STATUS_SUCCESS;
}

static VAStatus new_image(cb_driver *d, const VAImageFormat *fmt, unsigned w, unsigned h,
                          cb_surface *derived, VAImage *out)
{
    if (fmt->fourcc != VA_FOURCC_NV12 && fmt->fourcc != VA_FOURCC_P010)
        return VA_STATUS_ERROR_INVALID_IMAGE_FORMAT;
    cb_image *img = calloc(1, sizeof(*img));
    cb_buffer *b = calloc(1, sizeof(*b));
    if (!img || !b) {
        free(img);
        free(b);
        return VA_STATUS_ERROR_ALLOCATION_FAILED;
    }
    VAImage *im = &img->image;
    unsigned bps = fmt->fourcc == VA_FOURCC_P010 ? 2 : 1;
    im->format = *fmt;
    im->width = (uint16_t)w;
    im->height = (uint16_t)h;
    im->num_planes = 2;
    b->type = VAImageBufferType;
    b->derived = VA_INVALID_SURFACE;
    if (derived) {
        im->pitches[0] = im->pitches[1] = derived->pitch;
        im->offsets[1] = (uint32_t)derived->uv_offset;
        im->data_size = (uint32_t)derived->size;
        b->data = derived->map;
        b->derived = derived->id;
    } else {
        unsigned pitch = (w * bps + 63) & ~63u;
        im->pitches[0] = im->pitches[1] = pitch;
        im->offsets[1] = pitch * h;
        im->data_size = pitch * h + pitch * ((h + 1) / 2);
        b->data = malloc(im->data_size);
        if (!b->data) {
            free(img);
            free(b);
            return VA_STATUS_ERROR_ALLOCATION_FAILED;
        }
    }
    b->elem_size = im->data_size;
    b->count = 1;
    img->derived = b->derived;
    im->buf = obj_add(d, CB_OBJ_BUFFER, b);
    im->image_id = obj_add(d, CB_OBJ_IMAGE, img);
    if (im->buf == VA_INVALID_ID || im->image_id == VA_INVALID_ID) {
        obj_remove(d, CB_OBJ_BUFFER, im->buf);
        obj_remove(d, CB_OBJ_IMAGE, im->image_id);
        if (!derived)
            free(b->data);
        free(b);
        free(img);
        return VA_STATUS_ERROR_ALLOCATION_FAILED;
    }
    *out = *im;
    return VA_STATUS_SUCCESS;
}

static VAStatus create_image(VADriverContextP ctx, VAImageFormat *fmt, int w, int h, VAImage *out)
{
    cb_driver *d = DRV(ctx);
    if (w <= 0 || h <= 0 || w > MAX_SIZE || h > MAX_SIZE)
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    LOCK(d);
    VAStatus st = new_image(d, fmt, (unsigned)w, (unsigned)h, NULL, out);
    UNLOCK(d);
    return st;
}

static VAStatus derive_image(VADriverContextP ctx, VASurfaceID id, VAImage *out)
{
    cb_driver *d = DRV(ctx);
    LOCK(d);
    cb_surface *s = cb_get_surface(d, id);
    VAStatus st = VA_STATUS_ERROR_INVALID_SURFACE;
    if (s) {
        const VAImageFormat *fmt = &image_formats[s->fourcc == VA_FOURCC_P010 ? 1 : 0];
        st = new_image(d, fmt, s->width, s->height, s, out);
    }
    UNLOCK(d);
    return st;
}

static VAStatus destroy_image(VADriverContextP ctx, VAImageID id)
{
    cb_driver *d = DRV(ctx);
    LOCK(d);
    cb_image *img = cb_obj(d, CB_OBJ_IMAGE, id);
    obj_remove(d, CB_OBJ_IMAGE, id);
    UNLOCK(d);
    if (!img)
        return VA_STATUS_ERROR_INVALID_IMAGE;
    destroy_buffer(ctx, img->image.buf);
    free(img);
    return VA_STATUS_SUCCESS;
}

static VAStatus set_image_palette(VADriverContextP ctx, VAImageID id, unsigned char *palette)
{
    (void)ctx;
    (void)id;
    (void)palette;
    return VA_STATUS_ERROR_UNIMPLEMENTED;
}

/* Copies a rectangle between a surface and an image of the same format. */
static VAStatus copy_rect(cb_driver *d, cb_surface *s, cb_image *img, int sx, int sy, int ix, int iy,
                          unsigned w, unsigned h, int to_image)
{
    VAImage *im = &img->image;
    cb_buffer *b = cb_obj(d, CB_OBJ_BUFFER, im->buf);
    if (!b)
        return VA_STATUS_ERROR_INVALID_IMAGE;
    if (im->format.fourcc != s->fourcc)
        return VA_STATUS_ERROR_INVALID_IMAGE_FORMAT;
    if (sx < 0 || sy < 0 || ix < 0 || iy < 0 || sx + w > s->width || sy + h > s->height ||
        ix + w > im->width || iy + h > im->height)
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    unsigned bps = s->bps;
    cb_surface_begin_cpu(s);
    for (unsigned plane = 0; plane < 2; plane++) {
        unsigned rows = plane ? (h + 1) / 2 : h;
        unsigned sy0 = plane ? (unsigned)sy / 2 : (unsigned)sy, iy0 = plane ? (unsigned)iy / 2 : (unsigned)iy;
        unsigned sx0 = plane ? (unsigned)sx & ~1u : (unsigned)sx, ix0 = plane ? (unsigned)ix & ~1u : (unsigned)ix;
        size_t bytes = (size_t)(plane ? ((w + 1) & ~1u) : w) * bps;
        uint8_t *sp = s->map + (plane ? s->uv_offset : 0);
        uint8_t *ip = b->data + im->offsets[plane];
        for (unsigned y = 0; y < rows; y++) {
            uint8_t *a = sp + (size_t)(sy0 + y) * s->pitch + sx0 * bps;
            uint8_t *c = ip + (size_t)(iy0 + y) * im->pitches[plane] + ix0 * bps;
            if (to_image)
                memcpy(c, a, bytes);
            else
                memcpy(a, c, bytes);
        }
    }
    cb_surface_end_cpu(s);
    return VA_STATUS_SUCCESS;
}

static VAStatus get_image(VADriverContextP ctx, VASurfaceID sid, int x, int y, unsigned w, unsigned h,
                          VAImageID iid)
{
    cb_driver *d = DRV(ctx);
    LOCK(d);
    cb_surface *s = cb_get_surface(d, sid);
    cb_image *img = cb_obj(d, CB_OBJ_IMAGE, iid);
    VAStatus st;
    if (!s)
        st = VA_STATUS_ERROR_INVALID_SURFACE;
    else if (!img)
        st = VA_STATUS_ERROR_INVALID_IMAGE;
    else {
        need_pixels(d, s, 1);
        st = copy_rect(d, s, img, x, y, 0, 0, w, h, 1);
    }
    UNLOCK(d);
    return st;
}

static VAStatus put_image(VADriverContextP ctx, VASurfaceID sid, VAImageID iid, int sx, int sy,
                          unsigned sw, unsigned sh, int dx, int dy, unsigned dw, unsigned dh)
{
    cb_driver *d = DRV(ctx);
    if (sw != dw || sh != dh)
        return VA_STATUS_ERROR_UNIMPLEMENTED; /* no scaling */
    LOCK(d);
    cb_surface *s = cb_get_surface(d, sid);
    cb_image *img = cb_obj(d, CB_OBJ_IMAGE, iid);
    VAStatus st;
    if (!s)
        st = VA_STATUS_ERROR_INVALID_SURFACE;
    else if (!img)
        st = VA_STATUS_ERROR_INVALID_IMAGE;
    else {
        st = copy_rect(d, s, img, dx, dy, sx, sy, dw, dh, 0);
        if (st == VA_STATUS_SUCCESS)
            s->mark = -1;
    }
    UNLOCK(d);
    return st;
}

/* ---- What the driver does not do ---------------------------------------- */

static VAStatus unimplemented(void) { return VA_STATUS_ERROR_UNIMPLEMENTED; }
#define UNIMPL(f) ((__typeof__(f))(void (*)(void))unimplemented)

static VAStatus query_subpicture_formats(VADriverContextP ctx, VAImageFormat *list, unsigned *flags,
                                         unsigned *num)
{
    (void)ctx;
    (void)list;
    (void)flags;
    *num = 0;
    return VA_STATUS_SUCCESS;
}

static VAStatus query_display_attributes(VADriverContextP ctx, VADisplayAttribute *list, int *num)
{
    (void)ctx;
    (void)list;
    *num = 0;
    return VA_STATUS_SUCCESS;
}

/* ---- Init ---------------------------------------------------------------- */

static VAStatus terminate(VADriverContextP ctx)
{
    cb_driver *d = DRV(ctx);
    for (int k = CB_OBJ_IMAGE; k >= 0; k--) {
        for (unsigned i = 0; i < d->nobjs[k]; i++) {
            void *o = d->objs[k][i];
            if (!o)
                continue;
            unsigned id = obj_id(k, i);
            switch (k) {
            case CB_OBJ_IMAGE: destroy_image(ctx, id); break;
            case CB_OBJ_BUFFER: destroy_buffer(ctx, id); break;
            case CB_OBJ_CONTEXT: destroy_context(ctx, id); break;
            case CB_OBJ_SURFACE: destroy_surfaces(ctx, &id, 1); break;
            case CB_OBJ_CONFIG: destroy_config(ctx, id); break;
            }
        }
        free(d->objs[k]);
    }
    cb_sink_close(d->sink);
    if (d->udmabuf >= 0)
        close(d->udmabuf);
    pthread_mutex_destroy(&d->lock);
    free(d);
    ctx->pDriverData = NULL;
    return VA_STATUS_SUCCESS;
}

__attribute__((visibility("default"))) VAStatus __vaDriverInit_1_0(VADriverContextP ctx);

VAStatus __vaDriverInit_1_0(VADriverContextP ctx)
{
    cb_driver *d = calloc(1, sizeof(*d));
    if (!d)
        return VA_STATUS_ERROR_ALLOCATION_FAILED;
    pthread_mutex_init(&d->lock, NULL);
    const char *mode = getenv("CABOOSE_VA_MODE");
    d->force_decode = mode && strcmp(mode, "decode") == 0;
    d->sink = cb_sink_open();
    if (!d->sink && !d->force_decode) {
        /* No compositor to forward to: let the app decode the way it would
         * without a hardware decoder. */
        cb_log("no video socket; not initialising (CABOOSE_VA_MODE=decode decodes locally)");
        pthread_mutex_destroy(&d->lock);
        free(d);
        return VA_STATUS_ERROR_UNKNOWN;
    }
    d->udmabuf = open("/dev/udmabuf", O_RDWR | O_CLOEXEC);
    if (d->udmabuf < 0)
        cb_log("/dev/udmabuf unavailable: surfaces cannot be exported as dmabufs");
    ctx->pDriverData = d;
    ctx->version_major = VA_MAJOR_VERSION;
    ctx->version_minor = VA_MINOR_VERSION;
    ctx->max_profiles = (int)NPROFILES;
    ctx->max_entrypoints = 1;
    ctx->max_attributes = 4;
    ctx->max_image_formats = (int)(sizeof(image_formats) / sizeof(image_formats[0]));
    ctx->max_subpic_formats = 1;
    ctx->max_display_attributes = 1;
    ctx->str_vendor = "Caboose codec passthrough " CABOOSE_VA_VERSION;

    struct VADriverVTable *v = ctx->vtable;
    v->vaTerminate = terminate;
    v->vaQueryConfigProfiles = query_profiles;
    v->vaQueryConfigEntrypoints = query_entrypoints;
    v->vaGetConfigAttributes = get_config_attributes;
    v->vaCreateConfig = create_config;
    v->vaDestroyConfig = destroy_config;
    v->vaQueryConfigAttributes = query_config_attributes;
    v->vaCreateSurfaces = create_surfaces;
    v->vaCreateSurfaces2 = create_surfaces2;
    v->vaDestroySurfaces = destroy_surfaces;
    v->vaQuerySurfaceAttributes = query_surface_attributes;
    v->vaCreateContext = create_context;
    v->vaDestroyContext = destroy_context;
    v->vaCreateBuffer = create_buffer;
    v->vaBufferSetNumElements = buffer_set_num_elements;
    v->vaMapBuffer = map_buffer;
    v->vaUnmapBuffer = unmap_buffer;
    v->vaDestroyBuffer = destroy_buffer;
    v->vaBufferInfo = buffer_info;
    v->vaBeginPicture = begin_picture;
    v->vaRenderPicture = render_picture;
    v->vaEndPicture = end_picture;
    v->vaSyncSurface = sync_surface;
    v->vaSyncSurface2 = sync_surface2;
    v->vaQuerySurfaceStatus = query_surface_status;
    v->vaQuerySurfaceError = query_surface_error;
    v->vaExportSurfaceHandle = export_surface_handle;
    v->vaPutSurface = UNIMPL(v->vaPutSurface);
    v->vaQueryImageFormats = query_image_formats;
    v->vaCreateImage = create_image;
    v->vaDeriveImage = derive_image;
    v->vaDestroyImage = destroy_image;
    v->vaSetImagePalette = set_image_palette;
    v->vaGetImage = get_image;
    v->vaPutImage = put_image;
    v->vaQuerySubpictureFormats = query_subpicture_formats;
    v->vaCreateSubpicture = UNIMPL(v->vaCreateSubpicture);
    v->vaDestroySubpicture = UNIMPL(v->vaDestroySubpicture);
    v->vaSetSubpictureImage = UNIMPL(v->vaSetSubpictureImage);
    v->vaSetSubpictureChromakey = UNIMPL(v->vaSetSubpictureChromakey);
    v->vaSetSubpictureGlobalAlpha = UNIMPL(v->vaSetSubpictureGlobalAlpha);
    v->vaAssociateSubpicture = UNIMPL(v->vaAssociateSubpicture);
    v->vaDeassociateSubpicture = UNIMPL(v->vaDeassociateSubpicture);
    v->vaQueryDisplayAttributes = query_display_attributes;
    v->vaGetDisplayAttributes = UNIMPL(v->vaGetDisplayAttributes);
    v->vaSetDisplayAttributes = UNIMPL(v->vaSetDisplayAttributes);
    v->vaLockSurface = UNIMPL(v->vaLockSurface);
    v->vaUnlockSurface = UNIMPL(v->vaUnlockSurface);
    return VA_STATUS_SUCCESS;
}
