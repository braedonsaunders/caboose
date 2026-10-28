/* VP9: VA slice data is the whole frame (uncompressed header, compressed header
 * and tiles), so the frame passes through untouched.
 *
 * One thing is missing: apps show a hidden frame (an alt-ref) later with
 * show_existing_frame, which never reaches a VA driver, and a hidden frame may
 * also never be shown. So a hidden frame is sent as a superframe with a one-byte
 * show_existing_frame of a slot it was stored in appended, flagged
 * CB_FRAME_HIDDEN: the client decodes and keeps the picture, and presents it
 * only if the app shows it (the marker carries its sequence number). */
#include "cbva.h"

#include <va/va_dec_vp9.h>

typedef struct {
    cb_buf out;
} vp9_state;

/* refresh_frame_flags from the uncompressed header, or -1. */
static int refresh_flags(const uint8_t *data, size_t size, unsigned *profile_out)
{
    cb_br r;
    cb_br_init(&r, data, size);
    if (cb_br_get(&r, 2) != 2)
        return -1;
    unsigned low = cb_br_get(&r, 1), high = cb_br_get(&r, 1);
    unsigned profile = (high << 1) | low;
    *profile_out = profile;
    if (profile == 3)
        cb_br_get(&r, 1);
    if (cb_br_get(&r, 1)) /* show_existing_frame */
        return -1;
    unsigned frame_type = cb_br_get(&r, 1);
    unsigned show = cb_br_get(&r, 1);
    unsigned error_res = cb_br_get(&r, 1);
    if (frame_type == 0)
        return 0xff;
    unsigned intra_only = show ? 0 : cb_br_get(&r, 1);
    if (!error_res)
        cb_br_get(&r, 2);
    if (intra_only) {
        if (cb_br_get(&r, 24) != 0x498342)
            return -1;
        if (profile > 0) {
            if (profile >= 2)
                cb_br_get(&r, 1);
            unsigned cs = cb_br_get(&r, 3);
            if (cs != 7) {
                cb_br_get(&r, 1);
                if (profile == 1 || profile == 3)
                    cb_br_get(&r, 3);
            } else if (profile == 1 || profile == 3) {
                cb_br_get(&r, 1);
            }
        }
    }
    int flags = (int)cb_br_get(&r, 8);
    return r.overrun ? -1 : flags;
}

static int vp9_picture(cb_context *c, const cb_picture *p, uint32_t seq)
{
    vp9_state *st = c->state;
    if (p->pp_size < sizeof(VADecPictureParameterBufferVP9) || p->nslices != 1 || p->slices[0].count != 1 ||
        p->slices[0].elem_size < sizeof(VASliceParameterBufferVP9))
        return -1;
    const VADecPictureParameterBufferVP9 *pp = p->pp;
    const VASliceParameterBufferVP9 *sp = p->slices[0].params;
    if ((size_t)sp->slice_data_offset + sp->slice_data_size > p->slices[0].data_size)
        return -1;
    const uint8_t *frame = p->slices[0].data + sp->slice_data_offset;
    size_t size = sp->slice_data_size;
    unsigned flags = pp->pic_fields.bits.frame_type == 0 ? CB_FRAME_KEY : 0;
    if (pp->pic_fields.bits.show_frame) {
        cb_emit(c, seq, p->target, flags, frame, size, pp->frame_width, pp->frame_height);
        return 0;
    }
    unsigned profile = 0;
    int refresh = refresh_flags(frame, size, &profile);
    if (refresh <= 0) {
        cb_emit(c, seq, p->target, flags | CB_FRAME_HIDDEN, frame, size, pp->frame_width, pp->frame_height);
        return 0;
    }
    unsigned slot = (unsigned)__builtin_ctz((unsigned)refresh);
    /* frame_marker, profile bits, [reserved], show_existing_frame = 1, slot */
    uint8_t show[2];
    size_t show_len = 1;
    if (profile == 3) {
        uint16_t bits = (uint16_t)(0x2u << 7 | 3u << 5 | 0u << 4 | 1u << 3 | slot) << 7;
        show[0] = (uint8_t)(bits >> 8);
        show[1] = (uint8_t)bits;
        show_len = 2;
    } else {
        show[0] = (uint8_t)(0x80 | (profile & 1) << 5 | (profile >> 1) << 4 | 1 << 3 | slot);
    }
    cb_buf_reset(&st->out);
    cb_buf_append(&st->out, frame, size);
    cb_buf_append(&st->out, show, show_len);
    uint8_t marker = 0xc0 | 3 << 3 | 1; /* 4-byte sizes, two frames */
    cb_buf_u8(&st->out, marker);
    cb_buf_le32(&st->out, (uint32_t)size);
    cb_buf_le32(&st->out, (uint32_t)show_len);
    cb_buf_u8(&st->out, marker);
    if (st->out.oom)
        return -1;
    cb_emit(c, seq, p->target, flags | CB_FRAME_HIDDEN, st->out.data, st->out.len, pp->frame_width,
            pp->frame_height);
    return 0;
}

static void vp9_fini(cb_context *c)
{
    vp9_state *st = c->state;
    cb_buf_free(&st->out);
}

const cb_codec cb_codec_vp9 = {
    .name = "vp9",
    .id = CB_CODEC_VP9,
    .state_size = sizeof(vp9_state),
    .picture = vp9_picture,
    .fini = vp9_fini,
};
