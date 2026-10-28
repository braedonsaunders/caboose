/* H.264: rebuild the access unit from VA buffers.
 *
 * VA slice data is each slice's whole NAL unit (header, slice header and data),
 * so slices pass through untouched. What VA does not carry is the parameter
 * sets: the SPS and PPS are rebuilt from VAPictureParameterBufferH264 and the
 * IQ matrix. A few PPS fields exist only in the bitstream; they are recovered
 * from the slice headers (the PPS id, and the default reference counts, from the
 * slices that do not override them). The rebuilt sets decode identically but
 * are not byte-identical: profile is High (or High 10), level is the lowest that
 * fits, scaling lists are explicit in the PPS, and there is no VUI.
 *
 * Not expressible from VA, so the stream is refused (the app falls back to
 * software decoding): pic_order_cnt_type 1, slice groups (FMO), 4:2:2/4:4:4. */
#include "cbva.h"

#include <stdlib.h>
#include <string.h>

typedef struct {
    cb_buf sps;       /* last emitted SPS RBSP */
    cb_buf pps[256];  /* last emitted PPS RBSP per id */
    int16_t l0[256], l1[256]; /* learned num_ref_idx_lX_default_active_minus1, -1 unknown */
    int init;
    cb_buf au, rbsp;
} h264_state;

static const uint8_t zigzag4[16] = { 0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15 };
static const uint8_t zigzag8[64] = {
    0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,  12, 19, 26, 33, 40, 48,
    41, 34, 27, 20, 13, 6,  7,  14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23,
    30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
};

typedef struct {
    const uint8_t *nal; /* NAL unit, header byte first */
    size_t size;
    unsigned type, ref_idc, slice_type, pps_id;
    int override, l0, l1;
} slice_info;

static const struct {
    unsigned level, max_fs, max_dpb_mbs;
} levels[] = {
    { 30, 1620, 8100 },     { 31, 3600, 18000 },    { 32, 5120, 20480 },    { 40, 8192, 32768 },
    { 42, 8704, 34816 },    { 50, 22080, 110400 },  { 51, 36864, 184320 },  { 60, 139264, 696320 },
    { 62, 139264, 696320 },
};

/* The lowest level that fits the picture and its references, and its DPB size. */
static unsigned pick_level(unsigned frame_mbs, unsigned refs, unsigned *dpb_frames)
{
    unsigned i = 0, n = sizeof(levels) / sizeof(levels[0]);
    while (i + 1 < n && (frame_mbs > levels[i].max_fs || refs * frame_mbs > levels[i].max_dpb_mbs))
        i++;
    unsigned dpb = levels[i].max_dpb_mbs / frame_mbs;
    *dpb_frames = dpb > 16 ? 16 : dpb < refs ? refs : dpb;
    return levels[i].level;
}

static void write_sps(cb_buf *out, const VAPictureParameterBufferH264 *pp)
{
    cb_bw w;
    cb_bw_init(&w, out);
    unsigned depth = pp->bit_depth_luma_minus8;
    unsigned wmbs = pp->picture_width_in_mbs_minus1 + 1u;
    unsigned hmbs = pp->picture_height_in_mbs_minus1 + 1u;
    unsigned frame_mbs_only = pp->seq_fields.bits.frame_mbs_only_flag;
    unsigned dpb;
    unsigned level = pick_level(wmbs * hmbs, pp->num_ref_frames ? pp->num_ref_frames : 1, &dpb);
    cb_bw_put(&w, 8, depth ? 110 : 100);
    cb_bw_put(&w, 8, 0); /* constraint_set flags, reserved */
    cb_bw_put(&w, 8, level);
    cb_bw_ue(&w, 0); /* seq_parameter_set_id */
    cb_bw_ue(&w, pp->seq_fields.bits.chroma_format_idc);
    cb_bw_ue(&w, pp->bit_depth_luma_minus8);
    cb_bw_ue(&w, pp->bit_depth_chroma_minus8);
    cb_bw_flag(&w, 0); /* qpprime_y_zero_transform_bypass_flag */
    cb_bw_flag(&w, 0); /* seq_scaling_matrix_present_flag: lists go in the PPS */
    cb_bw_ue(&w, pp->seq_fields.bits.log2_max_frame_num_minus4);
    cb_bw_ue(&w, pp->seq_fields.bits.pic_order_cnt_type);
    if (pp->seq_fields.bits.pic_order_cnt_type == 0)
        cb_bw_ue(&w, pp->seq_fields.bits.log2_max_pic_order_cnt_lsb_minus4);
    cb_bw_ue(&w, pp->num_ref_frames);
    cb_bw_flag(&w, pp->seq_fields.bits.gaps_in_frame_num_value_allowed_flag);
    cb_bw_ue(&w, wmbs - 1);
    cb_bw_ue(&w, hmbs / (2 - frame_mbs_only) - 1);
    cb_bw_flag(&w, frame_mbs_only);
    if (!frame_mbs_only)
        cb_bw_flag(&w, pp->seq_fields.bits.mb_adaptive_frame_field_flag);
    cb_bw_flag(&w, pp->seq_fields.bits.direct_8x8_inference_flag);
    cb_bw_flag(&w, 0); /* frame_cropping_flag: VA does not carry the crop */
    /* VUI with only bitstream_restriction: VA does not say how far pictures are
     * reordered, so declare the whole DPB. Decoders that infer the reorder depth
     * instead may drop pictures they first output too early. */
    cb_bw_flag(&w, 1);
    cb_bw_put(&w, 8, 0); /* aspect ratio, overscan, video signal, chroma loc, timing, hrd x2, pic_struct */
    cb_bw_flag(&w, 1); /* bitstream_restriction_flag */
    cb_bw_flag(&w, 1); /* motion_vectors_over_pic_boundaries_flag */
    cb_bw_ue(&w, 0);   /* max_bytes_per_pic_denom */
    cb_bw_ue(&w, 0);   /* max_bits_per_mb_denom */
    cb_bw_ue(&w, 15);  /* log2_max_mv_length_horizontal */
    cb_bw_ue(&w, 15);  /* log2_max_mv_length_vertical */
    cb_bw_ue(&w, dpb); /* max_num_reorder_frames */
    cb_bw_ue(&w, dpb); /* max_dec_frame_buffering */
    cb_bw_trailing(&w);
}

static int flat(const uint8_t *list, unsigned n)
{
    for (unsigned i = 0; i < n; i++)
        if (list[i] != 16)
            return 0;
    return 1;
}

static void scaling_list(cb_bw *w, const uint8_t *raster, const uint8_t *scan, unsigned n)
{
    int last = 8;
    for (unsigned j = 0; j < n; j++) {
        int v = raster[scan[j]];
        int delta = v - last;
        if (delta > 127)
            delta -= 256;
        if (delta < -128)
            delta += 256;
        cb_bw_se(w, delta);
        last = v;
    }
}

static void write_pps(cb_buf *out, const VAPictureParameterBufferH264 *pp, const VAIQMatrixBufferH264 *iq,
                      unsigned id, unsigned l0, unsigned l1)
{
    cb_bw w;
    cb_bw_init(&w, out);
    cb_bw_ue(&w, id);
    cb_bw_ue(&w, 0);
    cb_bw_flag(&w, pp->pic_fields.bits.entropy_coding_mode_flag);
    cb_bw_flag(&w, pp->pic_fields.bits.pic_order_present_flag);
    cb_bw_ue(&w, 0); /* num_slice_groups_minus1 */
    cb_bw_ue(&w, l0);
    cb_bw_ue(&w, l1);
    cb_bw_flag(&w, pp->pic_fields.bits.weighted_pred_flag);
    cb_bw_put(&w, 2, pp->pic_fields.bits.weighted_bipred_idc);
    /* FFmpeg, the only VA user that decodes High 10 H.264, passes these with
     * QpBdOffset added (its init_qp - 26); for 8-bit there is no difference. */
    int offset = 6 * (int)pp->bit_depth_luma_minus8;
    cb_bw_se(&w, pp->pic_init_qp_minus26 - offset);
    cb_bw_se(&w, pp->pic_init_qs_minus26 - offset);
    cb_bw_se(&w, pp->chroma_qp_index_offset);
    cb_bw_flag(&w, pp->pic_fields.bits.deblocking_filter_control_present_flag);
    cb_bw_flag(&w, pp->pic_fields.bits.constrained_intra_pred_flag);
    cb_bw_flag(&w, pp->pic_fields.bits.redundant_pic_cnt_present_flag);
    int t8 = pp->pic_fields.bits.transform_8x8_mode_flag;
    int lists = 0;
    if (iq) {
        for (unsigned i = 0; i < 6; i++)
            lists |= !flat(iq->ScalingList4x4[i], 16);
        for (unsigned i = 0; i < 2 && t8; i++)
            lists |= !flat(iq->ScalingList8x8[i], 64);
    }
    if (t8 || lists || pp->second_chroma_qp_index_offset != pp->chroma_qp_index_offset) {
        cb_bw_flag(&w, t8);
        cb_bw_flag(&w, lists);
        if (lists) {
            for (unsigned i = 0; i < 6; i++) {
                cb_bw_flag(&w, 1);
                scaling_list(&w, iq->ScalingList4x4[i], zigzag4, 16);
            }
            for (unsigned i = 0; i < 2 && t8; i++) {
                cb_bw_flag(&w, 1);
                scaling_list(&w, iq->ScalingList8x8[i], zigzag8, 64);
            }
        }
        cb_bw_se(&w, pp->second_chroma_qp_index_offset);
    }
    cb_bw_trailing(&w);
}

/* Reads the slice header up to the reference count override. */
static int parse_slice(const VAPictureParameterBufferH264 *pp, const VASliceParameterBufferH264 *sp,
                       slice_info *si)
{
    uint8_t rbsp[96];
    size_t n = si->size < sizeof(rbsp) ? si->size : sizeof(rbsp);
    n = cb_nal_unescape(rbsp, si->nal, n);
    cb_br r;
    cb_br_init(&r, rbsp, n);
    if (cb_br_get(&r, 1))
        return -1;
    si->ref_idc = cb_br_get(&r, 2);
    si->type = cb_br_get(&r, 5);
    if (si->type != 1 && si->type != 5)
        return -1;
    cb_br_ue(&r); /* first_mb_in_slice */
    si->slice_type = cb_br_ue(&r) % 5;
    si->pps_id = cb_br_ue(&r);
    if (si->pps_id > 255)
        return -1;
    cb_br_get(&r, pp->seq_fields.bits.log2_max_frame_num_minus4 + 4u);
    int field = 0;
    if (!pp->seq_fields.bits.frame_mbs_only_flag) {
        field = cb_br_flag(&r);
        if (field)
            cb_br_flag(&r);
    }
    if (si->type == 5)
        cb_br_ue(&r);
    if (pp->seq_fields.bits.pic_order_cnt_type == 0) {
        cb_br_get(&r, pp->seq_fields.bits.log2_max_pic_order_cnt_lsb_minus4 + 4u);
        if (pp->pic_fields.bits.pic_order_present_flag && !field)
            cb_br_se(&r);
    } else if (pp->seq_fields.bits.pic_order_cnt_type == 1 && !pp->seq_fields.bits.delta_pic_order_always_zero_flag) {
        cb_br_se(&r);
        if (pp->pic_fields.bits.pic_order_present_flag && !field)
            cb_br_se(&r);
    }
    if (pp->pic_fields.bits.redundant_pic_cnt_present_flag)
        cb_br_ue(&r);
    si->override = 0;
    if (si->slice_type == 1) /* B */
        cb_br_flag(&r);
    if (si->slice_type == 0 || si->slice_type == 1 || si->slice_type == 3)
        si->override = cb_br_flag(&r);
    si->l0 = sp->num_ref_idx_l0_active_minus1;
    si->l1 = sp->num_ref_idx_l1_active_minus1;
    return r.overrun ? -1 : 0;
}

static void put_nal(cb_buf *au, uint8_t header, const cb_buf *rbsp)
{
    static const uint8_t start[4] = { 0, 0, 0, 1 };
    cb_buf_append(au, start, 4);
    cb_buf_u8(au, header);
    cb_nal_escape(au, rbsp->data, rbsp->len);
}

static int same(const cb_buf *a, const cb_buf *b)
{
    return a->len == b->len && (!a->len || memcmp(a->data, b->data, a->len) == 0);
}

static int h264_picture(cb_context *c, const cb_picture *p, uint32_t seq)
{
    h264_state *st = c->state;
    if (!st->init) {
        for (unsigned i = 0; i < 256; i++)
            st->l0[i] = st->l1[i] = -1;
        st->init = 1;
    }
    if (p->pp_size < sizeof(VAPictureParameterBufferH264))
        return -1;
    const VAPictureParameterBufferH264 *pp = p->pp;
    const VAIQMatrixBufferH264 *iq = p->iq_size >= sizeof(VAIQMatrixBufferH264) ? p->iq : NULL;
    if (pp->seq_fields.bits.pic_order_cnt_type == 1)
        return CB_UNSUPPORTED;
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
    if (pp->num_slice_groups_minus1)
        return CB_UNSUPPORTED;
#pragma GCC diagnostic pop
    if (pp->seq_fields.bits.chroma_format_idc > 1)
        return CB_UNSUPPORTED;

    unsigned total = 0;
    for (unsigned i = 0; i < p->nslices; i++)
        total += p->slices[i].count;
    if (!total)
        return -1;
    slice_info *slices = calloc(total, sizeof(*slices));
    if (!slices)
        return -1;
    unsigned n = 0;
    int idr = 0, intra = 1, ret = 0;
    for (unsigned i = 0; i < p->nslices; i++) {
        const cb_slice *sl = &p->slices[i];
        if (sl->elem_size < sizeof(VASliceParameterBufferH264)) {
            ret = -1;
            goto out;
        }
        for (unsigned k = 0; k < sl->count; k++) {
            const VASliceParameterBufferH264 *sp =
                (const void *)((const uint8_t *)sl->params + (size_t)k * sl->elem_size);
            if ((size_t)sp->slice_data_offset + sp->slice_data_size > sl->data_size) {
                ret = -1;
                goto out;
            }
            slice_info *si = &slices[n];
            si->nal = sl->data + sp->slice_data_offset;
            si->size = sp->slice_data_size;
            /* Tolerate a start code in front of the NAL unit. */
            while (si->size > 3 && si->nal[0] == 0 && si->nal[1] == 0 &&
                   (si->nal[2] == 1 || (si->nal[2] == 0 && si->size > 4 && si->nal[3] == 1))) {
                unsigned skip = si->nal[2] == 1 ? 3 : 4;
                si->nal += skip;
                si->size -= skip;
            }
            if (!si->size || parse_slice(pp, sp, si)) {
                ret = -1;
                goto out;
            }
            idr |= si->type == 5;
            intra &= si->slice_type == 2 || si->slice_type == 4;
            if (!si->override && (si->slice_type == 0 || si->slice_type == 1 || si->slice_type == 3))
                st->l0[si->pps_id] = (int16_t)si->l0;
            if (!si->override && si->slice_type == 1)
                st->l1[si->pps_id] = (int16_t)si->l1;
            n++;
        }
    }

    int key = idr || (intra && slices[0].ref_idc);
    cb_buf_reset(&st->au);
    cb_buf_reset(&st->rbsp);
    write_sps(&st->rbsp, pp);
    int sps_new = key || !same(&st->rbsp, &st->sps);
    if (sps_new) {
        put_nal(&st->au, 0x67, &st->rbsp);
        cb_buf_reset(&st->sps);
        cb_buf_append(&st->sps, st->rbsp.data, st->rbsp.len);
    }
    for (unsigned i = 0; i < n; i++) {
        unsigned id = slices[i].pps_id;
        int seen = 0;
        for (unsigned k = 0; k < i; k++)
            seen |= slices[k].pps_id == id;
        if (seen)
            continue;
        cb_buf_reset(&st->rbsp);
        write_pps(&st->rbsp, pp, iq, id, st->l0[id] < 0 ? 0 : (unsigned)st->l0[id],
                  st->l1[id] < 0 ? 0 : (unsigned)st->l1[id]);
        if (sps_new || !same(&st->rbsp, &st->pps[id])) {
            put_nal(&st->au, 0x68, &st->rbsp);
            cb_buf_reset(&st->pps[id]);
            cb_buf_append(&st->pps[id], st->rbsp.data, st->rbsp.len);
        }
    }
    static const uint8_t start[4] = { 0, 0, 0, 1 };
    for (unsigned i = 0; i < n; i++) {
        cb_buf_append(&st->au, start, 4);
        cb_buf_append(&st->au, slices[i].nal, slices[i].size);
    }
    if (st->au.oom) {
        ret = -1;
        goto out;
    }
    cb_emit(c, seq, p->target, key ? CB_FRAME_KEY : 0, st->au.data, st->au.len,
            (pp->picture_width_in_mbs_minus1 + 1u) * 16, (pp->picture_height_in_mbs_minus1 + 1u) * 16);
out:
    free(slices);
    return ret;
}

static void h264_fini(cb_context *c)
{
    h264_state *st = c->state;
    cb_buf_free(&st->sps);
    for (unsigned i = 0; i < 256; i++)
        cb_buf_free(&st->pps[i]);
    cb_buf_free(&st->au);
    cb_buf_free(&st->rbsp);
}

const cb_codec cb_codec_h264 = {
    .name = "h264",
    .id = CB_CODEC_H264,
    .state_size = sizeof(h264_state),
    .picture = h264_picture,
    .fini = h264_fini,
};
