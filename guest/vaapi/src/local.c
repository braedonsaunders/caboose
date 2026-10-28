/* Local decoding: the fallback when passthrough cannot serve a stream (the app
 * reads pixels back, the compositor cannot bind or the client cannot decode
 * it). The rebuilt bitstream goes through libavcodec's software decoders and the
 * pixels land in the app's surfaces, so the app sees an ordinary decoder and the
 * compositor sees ordinary video (layers 2 and 3).
 *
 * Pixels are taken from the decoder's own picture buffer as soon as a picture is
 * decoded, not when libavcodec would output it after reordering: the app may
 * read a surface back before our decoder's reorder delay has passed. */
#include "cbva.h"

#include <libavcodec/avcodec.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <string.h>

struct cb_local {
    cb_context *ctx;
    AVCodecContext *av;
    AVPacket *pkt;
    AVFrame *frame;
    uint32_t current_seq;
    int have_current;
    /* The picture buffer the decoder allocated for the packet being decoded, and
     * the last one (an H.264 second field decodes into its first field's). */
    AVFrame *pending, *last;
    int dav1d, h264;
};

static int get_buffer(AVCodecContext *av, AVFrame *f, int flags)
{
    cb_local *l = av->opaque;
    int r = avcodec_default_get_buffer2(av, f, flags);
    if (r == 0 && l->have_current && !l->pending) {
        l->pending = av_frame_alloc();
        if (l->pending) {
            /* A second reference keeps the planes alive past this decode call. */
            if (av_frame_ref(l->pending, f) < 0)
                av_frame_free(&l->pending);
            else
                l->pending->pts = l->current_seq;
        }
    }
    return r;
}

cb_local *cb_local_new(cb_context *c)
{
    enum AVCodecID id;
    const char *name = NULL;
    switch (c->codec->id) {
    case CB_CODEC_H264: id = AV_CODEC_ID_H264; break;
    case CB_CODEC_HEVC: id = AV_CODEC_ID_HEVC; break;
    case CB_CODEC_VP9: id = AV_CODEC_ID_VP9; break;
    case CB_CODEC_AV1: id = AV_CODEC_ID_AV1; name = "libdav1d"; break;
    default: return NULL;
    }
    const AVCodec *codec = name ? avcodec_find_decoder_by_name(name) : avcodec_find_decoder(id);
    if (!codec)
        return NULL;
    cb_local *l = calloc(1, sizeof(*l));
    if (!l)
        return NULL;
    l->ctx = c;
    l->dav1d = name != NULL;
    l->h264 = id == AV_CODEC_ID_H264;
    l->av = avcodec_alloc_context3(codec);
    l->pkt = av_packet_alloc();
    l->frame = av_frame_alloc();
    if (!l->av || !l->pkt || !l->frame)
        goto fail;
    l->av->opaque = l;
    l->av->get_buffer2 = get_buffer;
    /* Slice threads finish inside each decode call; frame threads would not. */
    l->av->thread_type = FF_THREAD_SLICE;
    l->av->thread_count = 0;
    l->av->flags2 |= AV_CODEC_FLAG2_SHOW_ALL;
    AVDictionary *opts = NULL;
    if (l->dav1d)
        av_dict_set(&opts, "max_frame_delay", "1", 0);
    int r = avcodec_open2(l->av, codec, &opts);
    av_dict_free(&opts);
    if (r < 0)
        goto fail;
    return l;
fail:
    cb_local_free(l);
    return NULL;
}

void cb_local_free(cb_local *l)
{
    if (!l)
        return;
    av_frame_free(&l->pending);
    av_frame_free(&l->last);
    av_frame_free(&l->frame);
    av_packet_free(&l->pkt);
    avcodec_free_context(&l->av);
    free(l);
}

static VASurfaceID surface_for(cb_context *c, uint32_t seq)
{
    unsigned i = seq % CB_SEQ_MAP;
    return c->seq_of[i] == seq ? c->seq_surface[i] : VA_INVALID_SURFACE;
}

/* Copies a planar 4:2:0 (or grey) picture into an NV12 / P010 surface. */
static void store(cb_context *c, const AVFrame *f, uint32_t seq)
{
    VASurfaceID id = surface_for(c, seq);
    cb_surface *s = id == VA_INVALID_SURFACE ? NULL : cb_get_surface(c->drv, id);
    if (!s || s->owner != c->id || s->seq != seq)
        return; /* the app has reused that surface for a later frame */
    const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(f->format);
    if (!d || (d->flags & AV_PIX_FMT_FLAG_RGB) || d->comp[0].depth > 16)
        return;
    int depth = d->comp[0].depth, bytes = depth > 8 ? 2 : 1;
    int grey = d->nb_components == 1;
    unsigned w = (unsigned)f->width < s->width ? (unsigned)f->width : s->width;
    unsigned h = (unsigned)f->height < s->height ? (unsigned)f->height : s->height;
    cb_surface_begin_cpu(s);
    for (unsigned y = 0; y < h; y++) {
        const uint8_t *src = f->data[0] + (size_t)y * (size_t)f->linesize[0];
        uint8_t *dst = s->map + (size_t)y * s->pitch;
        if (s->bps == 1 && bytes == 1) {
            memcpy(dst, src, w);
        } else {
            for (unsigned x = 0; x < w; x++) {
                unsigned v = bytes == 1 ? (unsigned)src[x] << 2 : (unsigned)((const uint16_t *)src)[x] << (10 - depth);
                if (s->bps == 1)
                    dst[x] = (uint8_t)(v >> 2);
                else
                    ((uint16_t *)dst)[x] = (uint16_t)(v << 6);
            }
        }
    }
    for (unsigned y = 0; y < (h + 1) / 2; y++) {
        uint8_t *dst = s->map + s->uv_offset + (size_t)y * s->pitch;
        unsigned cy = d->log2_chroma_h ? y : y * 2;
        const uint8_t *u = grey ? NULL : f->data[1] + (size_t)cy * (size_t)f->linesize[1];
        const uint8_t *v = grey ? NULL : f->data[2] + (size_t)cy * (size_t)f->linesize[2];
        for (unsigned x = 0; x < (w + 1) / 2; x++) {
            unsigned cx = d->log2_chroma_w ? x : x * 2;
            unsigned uu = 512, vv = 512;
            if (!grey) {
                uu = bytes == 1 ? (unsigned)u[cx] << 2 : (unsigned)((const uint16_t *)u)[cx] << (10 - depth);
                vv = bytes == 1 ? (unsigned)v[cx] << 2 : (unsigned)((const uint16_t *)v)[cx] << (10 - depth);
            }
            if (s->bps == 1) {
                dst[2 * x] = (uint8_t)(uu >> 2);
                dst[2 * x + 1] = (uint8_t)(vv >> 2);
            } else {
                ((uint16_t *)dst)[2 * x] = (uint16_t)(uu << 6);
                ((uint16_t *)dst)[2 * x + 1] = (uint16_t)(vv << 6);
            }
        }
    }
    cb_surface_end_cpu(s);
    s->mark = -1;
}

void cb_local_decode(cb_local *l, uint32_t seq, const uint8_t *data, size_t len)
{
    if (av_new_packet(l->pkt, (int)len) < 0)
        return;
    memcpy(l->pkt->data, data, len);
    l->pkt->pts = seq;
    l->current_seq = seq;
    l->have_current = 1;
    int r = avcodec_send_packet(l->av, l->pkt);
    av_packet_unref(l->pkt);
    l->have_current = 0;
    if (r < 0 && r != AVERROR(EAGAIN))
        cb_log("local decode of frame %u failed: %s", seq, av_err2str(r));
    /* The decoded picture, before reordering (H.264, HEVC, VP9). */
    if (l->pending) {
        store(l->ctx, l->pending, seq);
        av_frame_free(&l->last);
        l->last = l->pending;
        l->pending = NULL;
    } else if (l->h264 && l->last && r >= 0) {
        store(l->ctx, l->last, seq);
    }
    /* Output frames: dav1d's pictures (its own buffers), and every decoder's
     * output must be drained so buffers are recycled. */
    while (avcodec_receive_frame(l->av, l->frame) == 0) {
        if (l->dav1d && l->frame->pts != AV_NOPTS_VALUE)
            store(l->ctx, l->frame, (uint32_t)l->frame->pts);
        av_frame_unref(l->frame);
    }
}
