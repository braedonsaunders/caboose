/* HEVC: rebuild the access unit from VA buffers.
 *
 * VA slice data is each slice segment's whole NAL unit, but VA carries none of
 * the parameter sets, and the slice headers lean on them. The VPS, SPS and PPS
 * are rebuilt from VAPictureParameterBufferHEVC and the IQ matrix and sent at
 * every IRAP picture and whenever their content changes. They decode the same
 * but are not byte-identical: Main or Main 10, Main tier, the lowest level that
 * fits the picture size and DPB (at the sublevel that allows 60 frames per
 * second), seven temporal sub-layers declared so any TemporalId is legal,
 * scaling lists and tile sizes explicit in the PPS, and no VUI or conformance
 * window (VA does not carry the crop). VA has the reorder depth only when it is
 * zero; otherwise it is declared as deep as the DPB, which keeps output order
 * and only delays output.
 *
 * What VA cannot give back is the SPS's list of short-term reference picture
 * sets (and of long-term candidates), which slice headers may index. So the
 * rebuilt SPS has none, and every slice segment header with an RPS is rewritten
 * with it coded inline: the header is parsed to byte_alignment() (every value it
 * depends on is in the picture parameters); the short-term RPS is coded from
 * VA's ReferenceFrames (POC deltas to the current picture, used by it when
 * flagged ST_CURR_BEFORE/AFTER); long-term entries taken from the SPS become
 * explicit, and long-term entries get their POC MSB coded where possible (see
 * recode_lt()); every other header bit is copied as is. The slice data bytes
 * follow untouched, so entry point offsets stay valid. IDR slices and dependent
 * slice segments have no RPS and pass through.
 *
 * Output can differ from the original, decoding cannot: no_output_of_prior_pics_flag
 * is cleared, because which earlier pictures it drops depends on the reorder
 * depth we do not reproduce. The client gets every picture and presents the ones
 * the app shows. A CRA picture that the app decoded as the start of a sequence
 * (POC MSB reset after a seek, or after an end of sequence VA does not see) is
 * sent as BLA, so the client derives the same POC and skips the same leading
 * pictures.
 *
 * Not expressible from VA, so the stream is refused (the app falls back to
 * software decoding): anything but 4:2:0 at 8 or 10 bits, multi-layer streams,
 * partial slice data, an inline RPS predicted from the SPS's sets when the app
 * does not say how long it is (st_rps_bits), long-term pictures from the SPS
 * candidate list that VA's long-term references do not identify unambiguously,
 * and slice headers whose reference counts disagree with VA's references. */
#include "cbva.h"

#include <string.h>

#define MAX_PPS 64
#define MAX_LT 32
#define SUB_LAYERS 7 /* declared in the VPS and SPS */

enum {
    NAL_RASL_R = 9,
    NAL_BLA_W_LP = 16,
    NAL_IDR_W_RADL = 19,
    NAL_IDR_N_LP = 20,
    NAL_CRA = 21,
    NAL_VPS = 32,
    NAL_SPS = 33,
    NAL_PPS = 34,
};

typedef struct {
    cb_buf vps, sps, pps[MAX_PPS]; /* last emitted RBSPs */
    cb_buf au, vcl, rbsp, nal;     /* scratch */
    int have_prev;
    int32_t prev_tid0_poc; /* POC of the last TemporalId 0 picture that anchors POC derivation */
} hevc_state;

/* The current picture's reference pictures, from VA's ReferenceFrames. */
typedef struct {
    int32_t poc;
    unsigned nneg, npos, nlt;
    int32_t neg[16], pos[16], lt_poc[16]; /* neg: POC deltas, closest first; lt: POCs */
    uint8_t neg_used[16], pos_used[16], lt_used[16];
    unsigned curr_st, curr_lt; /* how many the current picture uses */
} refs;

/* A slice header's long-term section. */
typedef struct {
    unsigned n, nsps; /* entries; the first nsps are lt_idx_sps */
    uint32_t lsb[MAX_LT], cycle[MAX_LT]; /* poc_lsb_lt, delta_poc_msb_cycle_lt */
    uint8_t used[MAX_LT], msb[MAX_LT];
} lt_set;

static unsigned ceil_log2(unsigned v)
{
    unsigned n = 0;
    while (n < 32 && (1ull << n) < v)
        n++;
    return n;
}

static int same(const cb_buf *a, const cb_buf *b)
{
    return a->len == b->len && (!a->len || memcmp(a->data, b->data, a->len) == 0);
}

static void put_nal(cb_buf *au, unsigned type, const cb_buf *rbsp)
{
    static const uint8_t start[4] = { 0, 0, 0, 1 };
    cb_buf_append(au, start, 4);
    cb_buf_u8(au, (uint8_t)(type << 1));
    cb_buf_u8(au, 1); /* nuh_layer_id 0, TemporalId 0 */
    cb_nal_escape(au, rbsp->data, rbsp->len);
}

/* --- Parameter sets ------------------------------------------------------- */

static unsigned pick_level(unsigned w, unsigned h, unsigned dpb)
{
    static const struct {
        uint8_t idc;
        uint32_t max_ps; /* MaxLumaPs, Table A.8 */
    } levels[] = {
        { 30, 36864 },     { 60, 122880 },    { 63, 245760 },     { 90, 552960 },
        { 93, 983040 },    { 123, 2228224 },  { 153, 8912896 },   { 183, 35651584 },
    };
    uint64_t ps = (uint64_t)w * h;
    for (unsigned i = 0; i < sizeof(levels) / sizeof(levels[0]); i++) {
        uint64_t max = levels[i].max_ps;
        if (ps > max || (uint64_t)w * w > 8 * max || (uint64_t)h * h > 8 * max)
            continue;
        unsigned max_dpb = ps <= max / 4 ? 16 : ps <= max / 2 ? 12 : ps <= max * 3 / 4 ? 8 : 6;
        if (dpb <= max_dpb)
            return levels[i].idc;
    }
    return 186; /* 6.2 */
}

/* profile_tier_level(1, SUB_LAYERS - 1) */
static void write_ptl(cb_bw *w, unsigned profile, unsigned level)
{
    cb_bw_put(w, 2, 0); /* general_profile_space */
    cb_bw_flag(w, 0);   /* general_tier_flag: Main */
    cb_bw_put(w, 5, profile);
    /* general_profile_compatibility_flag[32]: a Main stream is a Main 10 stream too. */
    uint32_t compat = 1u << (31 - profile);
    if (profile == 1)
        compat |= 1u << (31 - 2);
    cb_bw_put(w, 32, compat);
    cb_bw_put(w, 4, 0);  /* progressive/interlaced source, non-packed, frame-only: unknown */
    cb_bw_put(w, 44, 0); /* general_reserved_zero_43bits, general_inbld_flag */
    cb_bw_put(w, 8, level);
    /* sub_layer_profile_present_flag/sub_layer_level_present_flag, then
     * reserved_zero_2bits up to eight sub-layers: all zero. */
    cb_bw_put(w, 16, 0);
}

static void write_vps(cb_buf *out, unsigned profile, unsigned level, unsigned dpb_minus1, unsigned reorder)
{
    cb_bw w;
    cb_bw_init(&w, out);
    cb_bw_put(&w, 4, 0); /* vps_video_parameter_set_id */
    cb_bw_put(&w, 2, 3); /* vps_base_layer_internal_flag, vps_base_layer_available_flag */
    cb_bw_put(&w, 6, 0); /* vps_max_layers_minus1 */
    cb_bw_put(&w, 3, SUB_LAYERS - 1);
    cb_bw_flag(&w, 0); /* vps_temporal_id_nesting_flag */
    cb_bw_put(&w, 16, 0xffff);
    write_ptl(&w, profile, level);
    cb_bw_flag(&w, 0); /* vps_sub_layer_ordering_info_present_flag: one set for all */
    cb_bw_ue(&w, dpb_minus1);
    cb_bw_ue(&w, reorder);
    cb_bw_ue(&w, 0);          /* vps_max_latency_increase_plus1: no limit */
    cb_bw_put(&w, 6, 0);      /* vps_max_layer_id */
    cb_bw_ue(&w, 0);          /* vps_num_layer_sets_minus1 */
    cb_bw_flag(&w, 0);        /* vps_timing_info_present_flag */
    cb_bw_flag(&w, 0);        /* vps_extension_flag */
    cb_bw_trailing(&w);
}

static void write_sps(cb_buf *out, const VAPictureParameterBufferHEVC *pp, unsigned profile, unsigned level,
                      unsigned reorder)
{
    cb_bw w;
    cb_bw_init(&w, out);
    cb_bw_put(&w, 4, 0); /* sps_video_parameter_set_id */
    cb_bw_put(&w, 3, SUB_LAYERS - 1);
    cb_bw_flag(&w, 0); /* sps_temporal_id_nesting_flag */
    write_ptl(&w, profile, level);
    cb_bw_ue(&w, 0); /* sps_seq_parameter_set_id */
    cb_bw_ue(&w, pp->pic_fields.bits.chroma_format_idc);
    cb_bw_ue(&w, pp->pic_width_in_luma_samples);
    cb_bw_ue(&w, pp->pic_height_in_luma_samples);
    cb_bw_flag(&w, 0); /* conformance_window_flag: VA does not carry the crop */
    cb_bw_ue(&w, pp->bit_depth_luma_minus8);
    cb_bw_ue(&w, pp->bit_depth_chroma_minus8);
    cb_bw_ue(&w, pp->log2_max_pic_order_cnt_lsb_minus4);
    cb_bw_flag(&w, 0); /* sps_sub_layer_ordering_info_present_flag */
    cb_bw_ue(&w, pp->sps_max_dec_pic_buffering_minus1);
    cb_bw_ue(&w, reorder);
    cb_bw_ue(&w, 0);                                     /* sps_max_latency_increase_plus1 */
    cb_bw_ue(&w, pp->log2_min_luma_coding_block_size_minus3);
    cb_bw_ue(&w, pp->log2_diff_max_min_luma_coding_block_size);
    cb_bw_ue(&w, pp->log2_min_transform_block_size_minus2);
    cb_bw_ue(&w, pp->log2_diff_max_min_transform_block_size);
    cb_bw_ue(&w, pp->max_transform_hierarchy_depth_inter);
    cb_bw_ue(&w, pp->max_transform_hierarchy_depth_intra);
    cb_bw_flag(&w, pp->pic_fields.bits.scaling_list_enabled_flag);
    if (pp->pic_fields.bits.scaling_list_enabled_flag)
        cb_bw_flag(&w, 0); /* sps_scaling_list_data_present_flag: lists go in the PPS */
    cb_bw_flag(&w, pp->pic_fields.bits.amp_enabled_flag);
    cb_bw_flag(&w, pp->slice_parsing_fields.bits.sample_adaptive_offset_enabled_flag);
    cb_bw_flag(&w, pp->pic_fields.bits.pcm_enabled_flag);
    if (pp->pic_fields.bits.pcm_enabled_flag) {
        cb_bw_put(&w, 4, pp->pcm_sample_bit_depth_luma_minus1);
        cb_bw_put(&w, 4, pp->pcm_sample_bit_depth_chroma_minus1);
        cb_bw_ue(&w, pp->log2_min_pcm_luma_coding_block_size_minus3);
        cb_bw_ue(&w, pp->log2_diff_max_min_pcm_luma_coding_block_size);
        cb_bw_flag(&w, pp->pic_fields.bits.pcm_loop_filter_disabled_flag);
    }
    cb_bw_ue(&w, 0); /* num_short_term_ref_pic_sets: slices code theirs inline */
    cb_bw_flag(&w, pp->slice_parsing_fields.bits.long_term_ref_pics_present_flag);
    if (pp->slice_parsing_fields.bits.long_term_ref_pics_present_flag)
        cb_bw_ue(&w, 0); /* num_long_term_ref_pics_sps */
    cb_bw_flag(&w, pp->slice_parsing_fields.bits.sps_temporal_mvp_enabled_flag);
    cb_bw_flag(&w, pp->pic_fields.bits.strong_intra_smoothing_enabled_flag);
    cb_bw_flag(&w, 0); /* vui_parameters_present_flag */
    cb_bw_flag(&w, 0); /* sps_extension_present_flag */
    cb_bw_trailing(&w);
}

/* Raster positions of the up-right diagonal scan of an n x n block (6.5.3). */
static void diag_scan(unsigned n, uint8_t *pos)
{
    unsigned i = 0;
    for (unsigned d = 0; i < n * n; d++)
        for (unsigned x = 0; x <= d; x++)
            if (x < n && d - x < n)
                pos[i++] = (uint8_t)((d - x) * n + x);
}

/* scaling_list_data() with every list explicit. VA holds the lists in raster
 * order (libavcodec fills them so, despite the header's wording), with the DC
 * values apart, and only matrixId 0 and 3 at 32x32 (4:2:0). */
static void write_scaling_lists(cb_bw *w, const VAIQMatrixBufferHEVC *iq)
{
    uint8_t scan4[16], scan8[64];
    diag_scan(4, scan4);
    diag_scan(8, scan8);
    for (unsigned size = 0; size < 4; size++) {
        for (unsigned m = 0; m < 6; m += size == 3 ? 3 : 1) {
            const uint8_t *list = size == 0   ? iq->ScalingList4x4[m]
                                  : size == 1 ? iq->ScalingList8x8[m]
                                  : size == 2 ? iq->ScalingList16x16[m]
                                              : iq->ScalingList32x32[m / 3];
            cb_bw_flag(w, 1); /* scaling_list_pred_mode_flag */
            int last = 8;
            if (size >= 2) {
                last = size == 2 ? iq->ScalingListDC16x16[m] : iq->ScalingListDC32x32[m / 3];
                cb_bw_se(w, last - 8); /* scaling_list_dc_coef_minus8 */
            }
            for (unsigned j = 0; j < (size ? 64u : 16u); j++) {
                int v = list[size ? scan8[j] : scan4[j]];
                int delta = v - last;
                if (delta > 127)
                    delta -= 256;
                if (delta < -128)
                    delta += 256;
                cb_bw_se(w, delta); /* scaling_list_delta_coef */
                last = v;
            }
        }
    }
}

static void write_pps(cb_buf *out, const VAPictureParameterBufferHEVC *pp, const VAIQMatrixBufferHEVC *iq,
                      unsigned id)
{
    cb_bw w;
    cb_bw_init(&w, out);
    cb_bw_ue(&w, id);
    cb_bw_ue(&w, 0); /* pps_seq_parameter_set_id */
    cb_bw_flag(&w, pp->slice_parsing_fields.bits.dependent_slice_segments_enabled_flag);
    cb_bw_flag(&w, pp->slice_parsing_fields.bits.output_flag_present_flag);
    cb_bw_put(&w, 3, pp->num_extra_slice_header_bits);
    cb_bw_flag(&w, pp->pic_fields.bits.sign_data_hiding_enabled_flag);
    cb_bw_flag(&w, pp->slice_parsing_fields.bits.cabac_init_present_flag);
    cb_bw_ue(&w, pp->num_ref_idx_l0_default_active_minus1);
    cb_bw_ue(&w, pp->num_ref_idx_l1_default_active_minus1);
    cb_bw_se(&w, pp->init_qp_minus26);
    cb_bw_flag(&w, pp->pic_fields.bits.constrained_intra_pred_flag);
    cb_bw_flag(&w, pp->pic_fields.bits.transform_skip_enabled_flag);
    cb_bw_flag(&w, pp->pic_fields.bits.cu_qp_delta_enabled_flag);
    if (pp->pic_fields.bits.cu_qp_delta_enabled_flag)
        cb_bw_ue(&w, pp->diff_cu_qp_delta_depth);
    cb_bw_se(&w, pp->pps_cb_qp_offset);
    cb_bw_se(&w, pp->pps_cr_qp_offset);
    cb_bw_flag(&w, pp->slice_parsing_fields.bits.pps_slice_chroma_qp_offsets_present_flag);
    cb_bw_flag(&w, pp->pic_fields.bits.weighted_pred_flag);
    cb_bw_flag(&w, pp->pic_fields.bits.weighted_bipred_flag);
    cb_bw_flag(&w, pp->pic_fields.bits.transquant_bypass_enabled_flag);
    cb_bw_flag(&w, pp->pic_fields.bits.tiles_enabled_flag);
    cb_bw_flag(&w, pp->pic_fields.bits.entropy_coding_sync_enabled_flag);
    if (pp->pic_fields.bits.tiles_enabled_flag) {
        cb_bw_ue(&w, pp->num_tile_columns_minus1);
        cb_bw_ue(&w, pp->num_tile_rows_minus1);
        cb_bw_flag(&w, 0); /* uniform_spacing_flag: VA gives every size */
        for (unsigned i = 0; i < pp->num_tile_columns_minus1; i++)
            cb_bw_ue(&w, pp->column_width_minus1[i]);
        for (unsigned i = 0; i < pp->num_tile_rows_minus1; i++)
            cb_bw_ue(&w, pp->row_height_minus1[i]);
        cb_bw_flag(&w, pp->pic_fields.bits.loop_filter_across_tiles_enabled_flag);
    }
    cb_bw_flag(&w, pp->pic_fields.bits.pps_loop_filter_across_slices_enabled_flag);
    cb_bw_flag(&w, 1); /* deblocking_filter_control_present_flag */
    cb_bw_flag(&w, pp->slice_parsing_fields.bits.deblocking_filter_override_enabled_flag);
    cb_bw_flag(&w, pp->slice_parsing_fields.bits.pps_disable_deblocking_filter_flag);
    if (!pp->slice_parsing_fields.bits.pps_disable_deblocking_filter_flag) {
        cb_bw_se(&w, pp->pps_beta_offset_div2);
        cb_bw_se(&w, pp->pps_tc_offset_div2);
    }
    cb_bw_flag(&w, iq != NULL); /* pps_scaling_list_data_present_flag */
    if (iq)
        write_scaling_lists(&w, iq);
    cb_bw_flag(&w, pp->slice_parsing_fields.bits.lists_modification_present_flag);
    cb_bw_ue(&w, pp->log2_parallel_merge_level_minus2);
    cb_bw_flag(&w, pp->slice_parsing_fields.bits.slice_segment_header_extension_present_flag);
    cb_bw_flag(&w, 0); /* pps_extension_present_flag */
    cb_bw_trailing(&w);
}

/* --- Reference picture sets ----------------------------------------------- */

static int collect_refs(const VAPictureParameterBufferHEVC *pp, refs *rf)
{
    memset(rf, 0, sizeof(*rf));
    rf->poc = pp->CurrPic.pic_order_cnt;
    for (unsigned i = 0; i < 15; i++) {
        const VAPictureHEVC *ref = &pp->ReferenceFrames[i];
        if ((ref->flags & VA_PICTURE_HEVC_INVALID) || ref->picture_id == VA_INVALID_SURFACE)
            continue;
        if (ref->flags & VA_PICTURE_HEVC_LONG_TERM_REFERENCE) {
            int used = !!(ref->flags & VA_PICTURE_HEVC_RPS_LT_CURR);
            rf->lt_poc[rf->nlt] = ref->pic_order_cnt;
            rf->lt_used[rf->nlt++] = (uint8_t)used;
            rf->curr_lt += (unsigned)used;
            continue;
        }
        int used = !!(ref->flags & (VA_PICTURE_HEVC_RPS_ST_CURR_BEFORE | VA_PICTURE_HEVC_RPS_ST_CURR_AFTER));
        int32_t d = ref->pic_order_cnt - rf->poc;
        /* Insert in RPS order: negative deltas decreasing, positive increasing. */
        int32_t *list = d < 0 ? rf->neg : rf->pos;
        uint8_t *flags = d < 0 ? rf->neg_used : rf->pos_used;
        unsigned *n = d < 0 ? &rf->nneg : &rf->npos;
        unsigned k = *n;
        while (k > 0 && (d < 0 ? list[k - 1] < d : list[k - 1] > d)) {
            list[k] = list[k - 1];
            flags[k] = flags[k - 1];
            k--;
        }
        if (d == 0 || (k > 0 && list[k - 1] == d))
            return -1; /* the current POC, or two pictures with one POC */
        list[k] = d;
        flags[k] = (uint8_t)used;
        (*n)++;
        rf->curr_st += (unsigned)used;
    }
    return 0;
}

/* st_ref_pic_set(0): explicit deltas, no inter-RPS prediction. */
static void write_st_rps(cb_bw *w, const refs *rf)
{
    cb_bw_ue(w, rf->nneg);
    cb_bw_ue(w, rf->npos);
    int32_t prev = 0;
    for (unsigned i = 0; i < rf->nneg; i++) {
        cb_bw_ue(w, (uint32_t)(prev - rf->neg[i] - 1)); /* delta_poc_s0_minus1 */
        cb_bw_flag(w, rf->neg_used[i]);
        prev = rf->neg[i];
    }
    prev = 0;
    for (unsigned i = 0; i < rf->npos; i++) {
        cb_bw_ue(w, (uint32_t)(rf->pos[i] - prev - 1)); /* delta_poc_s1_minus1 */
        cb_bw_flag(w, rf->pos_used[i]);
        prev = rf->pos[i];
    }
}

/* Recodes a slice's long-term entries from VA's long-term references.
 *
 * lt_idx_sps entries become explicit: their pictures are the long-term
 * references that no explicit entry names. That is unambiguous when there is one
 * such entry, or several whose order does not matter (no MSB cycle coded and at
 * most one used by the current picture).
 *
 * Every entry whose picture is known gets its MSB cycle coded, where the chain of
 * cycles allows: an entry coded by POC LSB alone can match a non-reference
 * picture still waiting for output in libavcodec, and our SPS's deeper reorder
 * keeps more of those around than the original's did. DeltaPocMsbCycleLt
 * restarts at the first explicit entry, which no longer exists, so the whole
 * chain is recoded. */
static int recode_lt(lt_set *lt, const refs *rf, unsigned lsb_bits)
{
    uint32_t max = 1u << lsb_bits, abs[MAX_LT];
    int32_t base = rf->poc - (int32_t)((uint32_t)rf->poc & (max - 1)); /* PicOrderCntMsb */
    int32_t poc[MAX_LT];
    uint8_t known[MAX_LT] = { 0 };
    unsigned taken = 0;
    for (unsigned i = 0; i < lt->n; i++)
        abs[i] = lt->cycle[i] + (i == 0 || i == lt->nsps ? 0 : abs[i - 1]);
    for (unsigned i = lt->nsps; i < lt->n; i++) {
        if (lt->msb[i]) {
            poc[i] = base - (int32_t)(abs[i] * max) + (int32_t)lt->lsb[i];
            known[i] = 1;
        }
        unsigned hits = 0, hit = 0;
        for (unsigned k = rf->nlt; k-- > 0;) {
            int match = lt->msb[i] ? rf->lt_poc[k] == poc[i] : ((uint32_t)rf->lt_poc[k] & (max - 1)) == lt->lsb[i];
            if (match && !(taken & 1u << k)) {
                hits++;
                hit = k;
            }
        }
        if (hits)
            taken |= 1u << hit;
        if (hits == 1 && !lt->msb[i]) {
            poc[i] = rf->lt_poc[hit];
            known[i] = 1;
        }
    }
    if (lt->nsps) {
        unsigned cand[16], nc = 0, nused = 0, any_msb = 0;
        for (unsigned k = 0; k < rf->nlt; k++)
            if (!(taken & 1u << k)) {
                cand[nc++] = k;
                nused += rf->lt_used[k];
            }
        for (unsigned i = 0; i < lt->nsps; i++)
            any_msb |= lt->msb[i];
        if (nc != lt->nsps || (lt->nsps > 1 && (any_msb || nused > 1)))
            return CB_UNSUPPORTED;
        for (unsigned i = 0; i < lt->nsps; i++) {
            poc[i] = rf->lt_poc[cand[i]];
            known[i] = 1;
            lt->lsb[i] = (uint32_t)poc[i] & (max - 1);
            lt->used[i] = rf->lt_used[cand[i]];
        }
    }
    /* The cycle each entry needs (-1: not codable), and the smallest one a later
     * entry that already codes its cycle needs. */
    int64_t need[MAX_LT], limit[MAX_LT + 1];
    for (unsigned i = 0; i < lt->n; i++) {
        int64_t d = known[i] ? (int64_t)base - (poc[i] - (int32_t)((uint32_t)poc[i] & (max - 1))) : -1;
        need[i] = d >= 0 ? d / max : -1;
        if (lt->msb[i] && need[i] != abs[i])
            return CB_UNSUPPORTED;
    }
    limit[lt->n] = INT64_MAX;
    for (unsigned i = lt->n; i-- > 0;)
        limit[i] = lt->msb[i] && need[i] < limit[i + 1] ? need[i] : limit[i + 1];
    int64_t prev = 0;
    for (unsigned i = 0; i < lt->n; i++) {
        if (lt->msb[i]) {
            if (need[i] < prev)
                return CB_UNSUPPORTED; /* only possible across the old restart */
        } else if (need[i] < prev || need[i] > limit[i + 1]) {
            continue; /* no cycle coded: DeltaPocMsbCycleLt carries along */
        }
        lt->msb[i] = 1;
        lt->cycle[i] = (uint32_t)(need[i] - prev);
        prev = need[i];
    }
    lt->nsps = 0;
    return 0;
}

/* --- Slices --------------------------------------------------------------- */

static void skip(cb_br *r, size_t bits)
{
    r->pos += bits;
    if (r->pos > r->size * 8)
        r->overrun = 1;
}

static void copy_bits(cb_bw *w, const uint8_t *data, size_t size, size_t from, size_t to)
{
    cb_br r;
    cb_br_init(&r, data, size);
    r.pos = from;
    while (r.pos < to) {
        unsigned n = to - r.pos < 32 ? (unsigned)(to - r.pos) : 32;
        cb_bw_put(w, n, cb_br_get(&r, n));
    }
}

/* pred_weight_table() for 4:2:0. */
static void skip_pred_weights(cb_br *r, unsigned l0, int b, unsigned l1)
{
    cb_br_ue(r); /* luma_log2_weight_denom */
    cb_br_se(r); /* delta_chroma_log2_weight_denom */
    for (int list = 0; list <= b; list++) {
        unsigned n = (list ? l1 : l0) + 1, luma = 0, chroma = 0;
        for (unsigned i = 0; i < n; i++)
            luma |= (unsigned)cb_br_flag(r) << i;
        for (unsigned i = 0; i < n; i++)
            chroma |= (unsigned)cb_br_flag(r) << i;
        for (unsigned i = 0; i < n; i++) {
            if (luma >> i & 1) {
                cb_br_se(r);
                cb_br_se(r);
            }
            for (unsigned j = 0; (chroma >> i & 1) && j < 2; j++) {
                cb_br_se(r);
                cb_br_se(r);
            }
        }
    }
}

/* Escaped offset in `in` of RBSP offset `off`. */
static size_t escaped_offset(const uint8_t *in, size_t n, size_t off)
{
    size_t i = 0, o = 0;
    unsigned zeros = 0;
    for (; i < n && o < off; i++) {
        if (zeros >= 2 && in[i] == 3) {
            zeros = 0;
            continue;
        }
        o++;
        zeros = in[i] ? 0 : zeros + 1;
    }
    return i;
}

/* Appends one slice segment NAL unit (header bytes first) to st->vcl as nal
 * unit type `type`, with its RPS coded inline. Returns 0, -1 for a malformed
 * slice, or CB_UNSUPPORTED. */
static int put_slice(cb_context *c, hevc_state *st, const VAPictureParameterBufferHEVC *pp, const refs *rf,
                     const uint8_t *nal, size_t size, unsigned type, unsigned *pps_id)
{
    static const uint8_t start[4] = { 0, 0, 0, 1 };
    unsigned orig = nal[0] >> 1 & 63;
    unsigned lsb_bits = pp->log2_max_pic_order_cnt_lsb_minus4 + 4u;
    unsigned ctb_log2 = pp->log2_min_luma_coding_block_size_minus3 + 3u + pp->log2_diff_max_min_luma_coding_block_size;
    unsigned ctbs = ((pp->pic_width_in_luma_samples + (1u << ctb_log2) - 1) >> ctb_log2) *
                    ((pp->pic_height_in_luma_samples + (1u << ctb_log2) - 1) >> ctb_log2);

    cb_buf_reset(&st->nal);
    if (cb_buf_reserve(&st->nal, size))
        return -1;
    size_t n = cb_nal_unescape(st->nal.data, nal, size);
    st->nal.data[0] = (uint8_t)((nal[0] & 0x81) | type << 1);
    if (orig >= NAL_BLA_W_LP && orig <= 23)
        st->nal.data[2] &= 0xbf; /* no_output_of_prior_pics_flag (see the top) */
    cb_br r;
    cb_br_init(&r, st->nal.data, n);
    skip(&r, 16); /* nal_unit_header() */
    int first = cb_br_flag(&r);
    if (orig >= NAL_BLA_W_LP && orig <= 23)
        cb_br_flag(&r); /* no_output_of_prior_pics_flag */
    *pps_id = cb_br_ue(&r);
    int dependent = 0;
    if (!first) {
        if (pp->slice_parsing_fields.bits.dependent_slice_segments_enabled_flag)
            dependent = cb_br_flag(&r);
        cb_br_get(&r, ceil_log2(ctbs)); /* slice_segment_address */
    }
    if (r.overrun || *pps_id >= MAX_PPS)
        return -1;
    if (dependent || orig == NAL_IDR_W_RADL || orig == NAL_IDR_N_LP) {
        /* No RPS: the NAL unit passes through. */
        cb_buf_append(&st->vcl, start, 4);
        /* The first three bytes cannot hold an emulation prevention byte. */
        cb_buf_append(&st->vcl, st->nal.data, 3);
        cb_buf_append(&st->vcl, nal + 3, size - 3);
        return 0;
    }

    cb_br_get(&r, pp->num_extra_slice_header_bits); /* slice_reserved_flag[] */
    unsigned slice_type = cb_br_ue(&r);             /* 0 B, 1 P, 2 I */
    if (slice_type > 2)
        return -1;
    int b = slice_type == 0;
    if (pp->slice_parsing_fields.bits.output_flag_present_flag)
        cb_br_flag(&r); /* pic_output_flag */
    cb_br_get(&r, lsb_bits); /* slice_pic_order_cnt_lsb */

    /* The short-term RPS: parsed when inline, to check it against VA's. */
    size_t rps_start = r.pos;
    int st_curr = -1;
    if (!cb_br_flag(&r)) { /* short_term_ref_pic_set_sps_flag */
        size_t set_start = r.pos;
        if (pp->num_short_term_ref_pic_sets && cb_br_flag(&r)) {
            /* inter_ref_pic_set_prediction_flag: predicted from an SPS set VA
             * does not carry, so it is skipped by its size. */
            if (!pp->st_rps_bits) {
                cb_unsupported(c, "inline RPS predicted from the SPS, of unknown size");
                return CB_UNSUPPORTED;
            }
            r.pos = set_start;
            skip(&r, pp->st_rps_bits);
        } else {
            unsigned nneg = cb_br_ue(&r), npos = cb_br_ue(&r);
            if (nneg > 16 || npos > 16)
                return -1;
            st_curr = 0;
            for (unsigned i = 0; i < nneg + npos; i++) {
                cb_br_ue(&r); /* delta_poc_sX_minus1 */
                st_curr += cb_br_flag(&r);
            }
        }
    } else if (pp->num_short_term_ref_pic_sets > 1) {
        cb_br_get(&r, ceil_log2(pp->num_short_term_ref_pic_sets)); /* short_term_ref_pic_set_idx */
    }

    lt_set lt = { 0 };
    if (pp->slice_parsing_fields.bits.long_term_ref_pics_present_flag) {
        lt.nsps = pp->num_long_term_ref_pic_sps ? cb_br_ue(&r) : 0;
        lt.n = lt.nsps + cb_br_ue(&r);
        if (lt.nsps > pp->num_long_term_ref_pic_sps || lt.n < lt.nsps || lt.n > MAX_LT || r.overrun)
            return -1;
        for (unsigned i = 0; i < lt.n; i++) {
            if (i < lt.nsps) {
                cb_br_get(&r, ceil_log2(pp->num_long_term_ref_pic_sps)); /* lt_idx_sps */
            } else {
                lt.lsb[i] = cb_br_get(&r, lsb_bits);
                lt.used[i] = (uint8_t)cb_br_flag(&r);
            }
            lt.msb[i] = (uint8_t)cb_br_flag(&r);
            lt.cycle[i] = lt.msb[i] ? cb_br_ue(&r) : 0;
        }
        if (lt.n && recode_lt(&lt, rf, lsb_bits)) {
            cb_unsupported(c, "long-term pictures that VA's references do not identify");
            return CB_UNSUPPORTED;
        }
    }
    size_t rps_end = r.pos;
    unsigned lt_curr = 0;
    for (unsigned i = 0; i < lt.n; i++)
        lt_curr += lt.used[i];
    if ((st_curr >= 0 && (unsigned)st_curr != rf->curr_st) || lt_curr != rf->curr_lt) {
        cb_unsupported(c, "slice RPS does not match VA's reference pictures");
        return CB_UNSUPPORTED;
    }
    unsigned total_curr = rf->curr_st + rf->curr_lt; /* NumPicTotalCurr */

    /* The rest of the header, parsed only to find its end. */
    int tmvp = pp->slice_parsing_fields.bits.sps_temporal_mvp_enabled_flag ? cb_br_flag(&r) : 0;
    int sao = 0;
    if (pp->slice_parsing_fields.bits.sample_adaptive_offset_enabled_flag) {
        sao = cb_br_flag(&r); /* slice_sao_luma_flag */
        sao |= cb_br_flag(&r); /* slice_sao_chroma_flag */
    }
    if (slice_type != 2) {
        unsigned l0 = pp->num_ref_idx_l0_default_active_minus1, l1 = pp->num_ref_idx_l1_default_active_minus1;
        if (cb_br_flag(&r)) { /* num_ref_idx_active_override_flag */
            l0 = cb_br_ue(&r);
            if (b)
                l1 = cb_br_ue(&r);
        }
        if (l0 > 14 || l1 > 14)
            return -1;
        if (pp->slice_parsing_fields.bits.lists_modification_present_flag && total_curr > 1) {
            unsigned bits = ceil_log2(total_curr);
            if (cb_br_flag(&r))
                skip(&r, (l0 + 1) * bits); /* list_entry_l0 */
            if (b && cb_br_flag(&r))
                skip(&r, (l1 + 1) * bits); /* list_entry_l1 */
        }
        if (b)
            cb_br_flag(&r); /* mvd_l1_zero_flag */
        if (pp->slice_parsing_fields.bits.cabac_init_present_flag)
            cb_br_flag(&r); /* cabac_init_flag */
        if (tmvp) {
            int from_l0 = b ? cb_br_flag(&r) : 1;
            if (from_l0 ? l0 > 0 : l1 > 0)
                cb_br_ue(&r); /* collocated_ref_idx */
        }
        if ((pp->pic_fields.bits.weighted_pred_flag && slice_type == 1) ||
            (pp->pic_fields.bits.weighted_bipred_flag && b))
            skip_pred_weights(&r, l0, b, l1);
        cb_br_ue(&r); /* five_minus_max_num_merge_cand */
    }
    cb_br_se(&r); /* slice_qp_delta */
    if (pp->slice_parsing_fields.bits.pps_slice_chroma_qp_offsets_present_flag) {
        cb_br_se(&r);
        cb_br_se(&r);
    }
    int deblock_off = pp->slice_parsing_fields.bits.pps_disable_deblocking_filter_flag;
    if (pp->slice_parsing_fields.bits.deblocking_filter_override_enabled_flag && cb_br_flag(&r)) {
        deblock_off = cb_br_flag(&r);
        if (!deblock_off) {
            cb_br_se(&r);
            cb_br_se(&r);
        }
    }
    if (pp->pic_fields.bits.pps_loop_filter_across_slices_enabled_flag && (sao || !deblock_off))
        cb_br_flag(&r); /* slice_loop_filter_across_slices_enabled_flag */
    if (pp->pic_fields.bits.tiles_enabled_flag || pp->pic_fields.bits.entropy_coding_sync_enabled_flag) {
        unsigned entries = cb_br_ue(&r);
        if (entries) {
            unsigned len = cb_br_ue(&r) + 1;
            if (len > 32)
                return -1;
            skip(&r, (size_t)entries * len); /* entry_point_offset_minus1[] */
        }
    }
    if (pp->slice_parsing_fields.bits.slice_segment_header_extension_present_flag)
        skip(&r, (size_t)cb_br_ue(&r) * 8);
    size_t align = r.pos;
    if (!cb_br_flag(&r)) /* alignment_bit_equal_to_one */
        return -1;
    while (r.pos & 7)
        if (cb_br_flag(&r))
            return -1;
    if (r.overrun)
        return -1;

    /* Rebuild: the header up to the RPS, the RPS inline, the rest of the
     * header, then the original (escaped) slice data. The header ends in a
     * nonzero byte, so escaping cannot reach across the seam. */
    cb_buf_reset(&st->rbsp);
    cb_bw w;
    cb_bw_init(&w, &st->rbsp);
    copy_bits(&w, st->nal.data, n, 0, rps_start);
    cb_bw_flag(&w, 0); /* short_term_ref_pic_set_sps_flag */
    write_st_rps(&w, rf);
    if (pp->slice_parsing_fields.bits.long_term_ref_pics_present_flag) {
        cb_bw_ue(&w, lt.n); /* num_long_term_pics (no SPS candidates now) */
        for (unsigned i = 0; i < lt.n; i++) {
            cb_bw_put(&w, lsb_bits, lt.lsb[i]);
            cb_bw_flag(&w, lt.used[i]);
            cb_bw_flag(&w, lt.msb[i]);
            if (lt.msb[i])
                cb_bw_ue(&w, lt.cycle[i]);
        }
    }
    copy_bits(&w, st->nal.data, n, rps_end, align);
    cb_bw_trailing(&w); /* byte_alignment() */
    size_t data = escaped_offset(nal, size, r.pos / 8);
    cb_buf_append(&st->vcl, start, 4);
    cb_nal_escape(&st->vcl, st->rbsp.data, st->rbsp.len);
    cb_buf_append(&st->vcl, nal + data, size - data);
    return 0;
}

/* --- Pictures ------------------------------------------------------------- */

static int hevc_picture(cb_context *c, const cb_picture *p, uint32_t seq)
{
    hevc_state *st = c->state;
    if (p->pp_size < sizeof(VAPictureParameterBufferHEVC))
        return -1;
    const VAPictureParameterBufferHEVC *pp = p->pp;
    const VAIQMatrixBufferHEVC *iq = p->iq_size >= sizeof(VAIQMatrixBufferHEVC) ? p->iq : NULL;
    if (!pp->pic_fields.bits.scaling_list_enabled_flag)
        iq = NULL; /* without lists from the app, the defaults apply */
    if (pp->pic_fields.bits.chroma_format_idc != 1 || pp->bit_depth_luma_minus8 > 2 ||
        pp->bit_depth_chroma_minus8 > 2) {
        cb_unsupported(c, "not 4:2:0 at 8 or 10 bits");
        return CB_UNSUPPORTED;
    }
    if (pp->pic_fields.bits.tiles_enabled_flag && (pp->num_tile_columns_minus1 >= 19 || pp->num_tile_rows_minus1 >= 21))
        return -1;
    refs rf;
    if (collect_refs(pp, &rf)) {
        cb_unsupported(c, "reference pictures with clashing POCs");
        return CB_UNSUPPORTED;
    }

    unsigned lsb_bits = pp->log2_max_pic_order_cnt_lsb_minus4 + 4u;
    unsigned pic_type = 0, type = 0, tid = 0, nslices = 0; /* type: as sent */
    uint64_t pps_ids = 0;
    cb_buf_reset(&st->vcl);
    for (unsigned i = 0; i < p->nslices; i++) {
        const cb_slice *sl = &p->slices[i];
        if (sl->elem_size < sizeof(VASliceParameterBufferHEVC))
            return -1;
        for (unsigned k = 0; k < sl->count; k++) {
            const VASliceParameterBufferHEVC *sp =
                (const void *)((const uint8_t *)sl->params + (size_t)k * sl->elem_size);
            if ((size_t)sp->slice_data_offset + sp->slice_data_size > sl->data_size)
                return -1;
            if (sp->slice_data_flag != VA_SLICE_DATA_FLAG_ALL) {
                cb_unsupported(c, "partial slice data");
                return CB_UNSUPPORTED;
            }
            const uint8_t *nal = sl->data + sp->slice_data_offset;
            size_t size = sp->slice_data_size;
            /* Tolerate a start code in front of the NAL unit. */
            while (size > 3 && nal[0] == 0 && nal[1] == 0 &&
                   (nal[2] == 1 || (nal[2] == 0 && size > 4 && nal[3] == 1))) {
                unsigned skip_bytes = nal[2] == 1 ? 3 : 4;
                nal += skip_bytes;
                size -= skip_bytes;
            }
            if (size < 3 || (nal[0] & 0x80))
                return -1;
            if ((nal[0] & 1) || (nal[1] >> 3)) {
                cb_unsupported(c, "nuh_layer_id above 0 (multi-layer HEVC)");
                return CB_UNSUPPORTED;
            }
            unsigned t = nal[0] >> 1 & 63;
            if (t > 21 || (t > 9 && t < 16))
                return -1; /* not a slice */
            if (nslices == 0) {
                type = pic_type = t;
                tid = (nal[1] & 7u) - 1u;
                /* A CRA picture the app decoded as a sequence start (POC MSB reset,
                 * leading pictures dropped) where the client would not: send it
                 * as BLA. Otherwise the client derives POC from earlier pictures. */
                if (type == NAL_CRA && st->have_prev) {
                    uint32_t max = 1u << lsb_bits, lsb = (uint32_t)rf.poc & (max - 1);
                    uint32_t prev_lsb = (uint32_t)st->prev_tid0_poc & (max - 1);
                    int32_t msb = st->prev_tid0_poc - (int32_t)prev_lsb;
                    if (lsb < prev_lsb && prev_lsb - lsb >= max / 2)
                        msb += (int32_t)max;
                    else if (lsb > prev_lsb && lsb - prev_lsb > max / 2)
                        msb -= (int32_t)max;
                    if (msb + (int32_t)lsb != rf.poc)
                        type = NAL_BLA_W_LP;
                }
            } else if (t != pic_type) {
                return -1; /* all slices of a picture have one type */
            }
            unsigned pps_id;
            int r = put_slice(c, st, pp, &rf, nal, size, type, &pps_id);
            if (r)
                return r;
            pps_ids |= 1ull << pps_id;
            nslices++;
        }
    }
    if (!nslices)
        return -1;
    int key = type >= NAL_BLA_W_LP && type <= 23;
    /* prevTid0Pic: TemporalId 0 and not RASL, RADL or a sub-layer non-reference picture. */
    if (tid == 0 && !(type <= NAL_RASL_R && (type >= 6 || !(type & 1)))) {
        st->prev_tid0_poc = rf.poc;
        st->have_prev = 1;
    }

    unsigned profile = c->profile == VAProfileHEVCMain10 || pp->bit_depth_luma_minus8 || pp->bit_depth_chroma_minus8
                           ? 2 : 1;
    unsigned level = pick_level(pp->pic_width_in_luma_samples, pp->pic_height_in_luma_samples,
                                pp->sps_max_dec_pic_buffering_minus1 + 1u);
    cb_buf_reset(&st->au);
    cb_buf_reset(&st->rbsp);
    /* VA has the reorder depth only when it is zero; otherwise the deepest the
     * DPB allows keeps output order (output is just later). */
    unsigned reorder = pp->pic_fields.bits.NoPicReorderingFlag ? 0 : pp->sps_max_dec_pic_buffering_minus1;
    write_vps(&st->rbsp, profile, level, pp->sps_max_dec_pic_buffering_minus1, reorder);
    int fresh = key || !same(&st->rbsp, &st->vps);
    if (fresh) {
        put_nal(&st->au, NAL_VPS, &st->rbsp);
        cb_buf_reset(&st->vps);
        cb_buf_append(&st->vps, st->rbsp.data, st->rbsp.len);
    }
    cb_buf_reset(&st->rbsp);
    write_sps(&st->rbsp, pp, profile, level, reorder);
    if (fresh || !same(&st->rbsp, &st->sps)) {
        fresh = 1;
        put_nal(&st->au, NAL_SPS, &st->rbsp);
        cb_buf_reset(&st->sps);
        cb_buf_append(&st->sps, st->rbsp.data, st->rbsp.len);
    }
    for (unsigned id = 0; id < MAX_PPS; id++) {
        if (!(pps_ids >> id & 1))
            continue;
        cb_buf_reset(&st->rbsp);
        write_pps(&st->rbsp, pp, iq, id);
        if (fresh || !same(&st->rbsp, &st->pps[id])) {
            put_nal(&st->au, NAL_PPS, &st->rbsp);
            cb_buf_reset(&st->pps[id]);
            cb_buf_append(&st->pps[id], st->rbsp.data, st->rbsp.len);
        }
    }
    cb_buf_append(&st->au, st->vcl.data, st->vcl.len);
    if (st->au.oom || st->vcl.oom)
        return -1;
    cb_emit(c, seq, p->target, key ? CB_FRAME_KEY : 0, st->au.data, st->au.len, pp->pic_width_in_luma_samples,
            pp->pic_height_in_luma_samples);
    return 0;
}

static void hevc_fini(cb_context *c)
{
    hevc_state *st = c->state;
    cb_buf_free(&st->vps);
    cb_buf_free(&st->sps);
    for (unsigned i = 0; i < MAX_PPS; i++)
        cb_buf_free(&st->pps[i]);
    cb_buf_free(&st->au);
    cb_buf_free(&st->vcl);
    cb_buf_free(&st->rbsp);
    cb_buf_free(&st->nal);
}

const cb_codec cb_codec_hevc = {
    .name = "hevc",
    .id = CB_CODEC_HEVC,
    .state_size = sizeof(hevc_state),
    .picture = hevc_picture,
    .fini = hevc_fini,
};
