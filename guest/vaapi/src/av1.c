/* AV1: rebuild each temporal unit from VA buffers.
 *
 * VA slice data is the tile data of a tile group, and each
 * VASliceParameterBufferAV1 points at one tile's payload, so tiles pass through
 * untouched. Everything else is rebuilt from VADecPictureParameterBufferAV1 as
 * low-overhead OBUs: a temporal delimiter, a sequence header (at key frames and
 * when it changes), the uncompressed frame header, and one tile group with every
 * tile. The stream decodes identically but is not byte-identical. The sequence
 * header is permissive where VA does not say (superres, restoration, warped
 * motion and reference MVs enabled, screen content tools and integer MVs chosen
 * per frame, 16-bit frame sizes, level 31), so each frame's own flags, copied
 * from VA, decide. Frame headers code everything explicitly: the frame size with
 * an override, the render size equal to it, all loop filter deltas, film grain
 * with update_grain. Global motion is coded relative to the primary reference
 * frame's parameters, so what the decoder's reference slots hold is tracked here.
 *
 * VA does not carry refresh_frame_flags. They show in the next picture's
 * ref_frame_map (the slots that now hold this picture's surface), so each
 * picture is held back until the next one arrives, or the context is destroyed.
 * A shown key frame or a switch frame refreshes every slot and goes out at once.
 * When the driver decodes locally and the app needs a held picture's pixels
 * now, provisional() gives it shown with refresh_frame_flags 0, which changes no
 * decoder state; it is decoded again when emitted.
 *
 * Apps show a hidden frame later with show_existing_frame, which never reaches a
 * VA driver. So a hidden showable frame is followed, in its temporal unit, by a
 * show_existing_frame of a slot it was stored in, and flagged CB_FRAME_HIDDEN:
 * the client decodes and keeps it, and presents it if the app does. A hidden key
 * frame is not shown that way, since showing a key frame resets every slot. When
 * the next picture's slots show the app did it, the same show_existing_frame is
 * sent then; decoding locally, the frame's pixels are decoded at once instead.
 *
 * With film grain, apps decode into one surface (the reference) and present
 * another (current_display_picture), so the picture is tied to that one.
 *
 * Refused (the app falls back to software decoding): profiles 1 and 2 (4:4:4,
 * 4:2:2, 12-bit), monochrome (FFmpeg never sends it, so it is untested),
 * large-scale tile, and reference slots that change in a way the stream does
 * not explain (frames the app decoded without VA). */
#include "cbva.h"

#include <string.h>
#include <va/va_dec_av1.h>

enum { KEY_FRAME, INTER_FRAME, INTRA_ONLY_FRAME, SWITCH_FRAME };
enum { OBU_SEQUENCE_HEADER = 1, OBU_TEMPORAL_DELIMITER = 2, OBU_FRAME_HEADER = 3, OBU_TILE_GROUP = 4 };
enum { IDENTITY, TRANSLATION, ROTZOOM, AFFINE };
#define PRIMARY_REF_NONE 7
#define ALL_FRAMES 0xffu
#define MAX_TILES 4096

/* What a reference slot holds, as far as later headers depend on it. */
typedef struct {
    VASurfaceID surface, shown;
    uint32_t seq;
    uint8_t frame_type, order_hint;
    uint16_t w, h;
    int32_t gm[7][6];
} slot_t;

typedef struct {
    int init;
    slot_t slot[8];
    struct {
        int valid, given; /* given: provisional() has returned it */
        VADecPictureParameterBufferAV1 pp;
        VASurfaceID surface, shown; /* decoded into (a reference), presented from */
        uint32_t seq;
        cb_buf tiles; /* the tile group OBU payload */
    } held;
    cb_buf seq_hdr; /* last emitted sequence header OBU payload */
    unsigned max_w, max_h;
    struct {
        const uint8_t *data;
        uint32_t size;
    } tile[MAX_TILES];
    cb_buf out, tmp, hdr;
} av1_state;

static const int32_t gm_default[6] = { 0, 0, 1 << 16, 0, 0, 1 << 16 };

/* ---- Bit-level helpers ----------------------------------------------------- */

static void put_su(cb_bw *w, unsigned n, int v) { cb_bw_put(w, n, (uint64_t)(uint32_t)v); }

/* ns(n): v in [0, n) */
static void put_ns(cb_bw *w, unsigned n, unsigned v)
{
    unsigned bits = 0;
    while ((n >> bits) > 1)
        bits++;
    unsigned m = (2u << bits) - n;
    if (v < m) {
        cb_bw_put(w, bits, v);
    } else {
        cb_bw_put(w, bits, (v + m) >> 1);
        cb_bw_put(w, 1, (v + m) & 1);
    }
}

static void put_delta_q(cb_bw *w, int v)
{
    cb_bw_flag(w, v != 0);
    if (v)
        put_su(w, 7, v);
}

static int recenter(int r, int v)
{
    if (v > 2 * r)
        return v;
    return v >= r ? (v - r) << 1 : ((r - v) << 1) - 1;
}

/* The inverse of decode_subexp() / decode_unsigned_subexp_with_ref(). */
static void put_subexp_with_ref(cb_bw *w, int n, int r, int x)
{
    int v = (r << 1) <= n ? recenter(r, x) : recenter(n - 1 - r, n - 1 - x);
    int mk = 0;
    for (unsigned i = 0;; i++) {
        unsigned b2 = i ? 3 + i - 1 : 3;
        int a = 1 << b2;
        if (n <= mk + 3 * a) {
            put_ns(w, (unsigned)(n - mk), (unsigned)(v - mk));
            return;
        }
        cb_bw_flag(w, v >= mk + a);
        if (v < mk + a) {
            cb_bw_put(w, b2, (unsigned)(v - mk));
            return;
        }
        mk += a;
    }
}

static unsigned tile_log2(unsigned blk, unsigned target)
{
    unsigned k = 0;
    while ((blk << k) < target)
        k++;
    return k;
}

static void put_obu(cb_buf *out, unsigned type, const uint8_t *payload, size_t len)
{
    cb_bw w;
    cb_bw_init(&w, out);
    cb_bw_put(&w, 8, type << 3 | 2); /* obu_has_size_field */
    cb_bw_leb128(&w, len);
    cb_buf_append(out, payload, len);
}

/* ---- Headers ---------------------------------------------------------------- */

#define SEQ(pp) ((pp)->seq_info_fields.fields)
#define PIC(pp) ((pp)->pic_info_fields.bits)

static void sequence_header(cb_buf *out, const VADecPictureParameterBufferAV1 *pp, unsigned max_w,
                            unsigned max_h)
{
    cb_bw w;
    cb_bw_init(&w, out);
    cb_bw_put(&w, 3, 0); /* seq_profile */
    cb_bw_flag(&w, SEQ(pp).still_picture);
    cb_bw_flag(&w, 0);     /* reduced_still_picture_header */
    cb_bw_flag(&w, 0);     /* timing_info_present_flag */
    cb_bw_flag(&w, 0);     /* initial_display_delay_present_flag */
    cb_bw_put(&w, 5, 0);   /* operating_points_cnt_minus_1 */
    cb_bw_put(&w, 12, 0);  /* operating_point_idc[0] */
    cb_bw_put(&w, 5, 31);  /* seq_level_idx[0]: no level constraints */
    cb_bw_flag(&w, 0);     /* seq_tier[0] */
    cb_bw_put(&w, 4, 15);  /* frame_width_bits_minus_1 */
    cb_bw_put(&w, 4, 15);
    cb_bw_put(&w, 16, max_w - 1);
    cb_bw_put(&w, 16, max_h - 1);
    cb_bw_flag(&w, 0); /* frame_id_numbers_present_flag */
    cb_bw_flag(&w, SEQ(pp).use_128x128_superblock);
    cb_bw_flag(&w, SEQ(pp).enable_filter_intra);
    cb_bw_flag(&w, SEQ(pp).enable_intra_edge_filter);
    cb_bw_flag(&w, SEQ(pp).enable_interintra_compound);
    cb_bw_flag(&w, SEQ(pp).enable_masked_compound);
    cb_bw_flag(&w, 1); /* enable_warped_motion */
    cb_bw_flag(&w, SEQ(pp).enable_dual_filter);
    cb_bw_flag(&w, SEQ(pp).enable_order_hint);
    if (SEQ(pp).enable_order_hint) {
        cb_bw_flag(&w, SEQ(pp).enable_jnt_comp);
        cb_bw_flag(&w, 1); /* enable_ref_frame_mvs */
    }
    cb_bw_flag(&w, 1); /* seq_choose_screen_content_tools */
    cb_bw_flag(&w, 1); /* seq_choose_integer_mv */
    if (SEQ(pp).enable_order_hint)
        cb_bw_put(&w, 3, pp->order_hint_bits_minus_1);
    cb_bw_flag(&w, 1); /* enable_superres */
    cb_bw_flag(&w, SEQ(pp).enable_cdef);
    cb_bw_flag(&w, 1); /* enable_restoration */
    /* color_config() */
    cb_bw_flag(&w, pp->bit_depth_idx > 0);
    cb_bw_flag(&w, 0);    /* mono_chrome */
    cb_bw_flag(&w, 1);    /* color_description_present_flag */
    cb_bw_put(&w, 8, 2);  /* color_primaries: unspecified */
    cb_bw_put(&w, 8, 2);  /* transfer_characteristics: unspecified */
    cb_bw_put(&w, 8, pp->matrix_coefficients);
    cb_bw_flag(&w, SEQ(pp).color_range);
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
    cb_bw_put(&w, 2, SEQ(pp).chroma_sample_position);
#pragma GCC diagnostic pop
    cb_bw_flag(&w, 1); /* separate_uv_delta_q */
    cb_bw_flag(&w, SEQ(pp).film_grain_params_present);
    cb_bw_trailing(&w);
}

static int relative_dist(unsigned bits, unsigned a, unsigned b)
{
    if (!bits)
        return 0;
    unsigned diff = a - b, m = 1u << (bits - 1);
    return (int)(diff & (m - 1)) - (int)(diff & m);
}

static int skip_mode_allowed(const av1_state *st, const VADecPictureParameterBufferAV1 *pp, unsigned bits)
{
    int fwd = -1, bwd = -1, fwd2 = -1;
    unsigned fwd_hint = 0, bwd_hint = 0, fwd2_hint = 0;
    for (int i = 0; i < 7; i++) {
        unsigned hint = st->slot[pp->ref_frame_idx[i] & 7].order_hint;
        int dist = relative_dist(bits, hint, pp->order_hint);
        if (dist < 0 && (fwd < 0 || relative_dist(bits, hint, fwd_hint) > 0)) {
            fwd = i;
            fwd_hint = hint;
        } else if (dist > 0 && (bwd < 0 || relative_dist(bits, hint, bwd_hint) < 0)) {
            bwd = i;
            bwd_hint = hint;
        }
    }
    if (fwd < 0)
        return 0;
    if (bwd >= 0)
        return 1;
    for (int i = 0; i < 7; i++) {
        unsigned hint = st->slot[pp->ref_frame_idx[i] & 7].order_hint;
        if (relative_dist(bits, hint, fwd_hint) < 0 &&
            (fwd2 < 0 || relative_dist(bits, hint, fwd2_hint) > 0)) {
            fwd2 = i;
            fwd2_hint = hint;
        }
    }
    return fwd2 >= 0;
}

/* One global motion parameter, coded relative to the primary reference's. */
static int global_param(cb_bw *w, int type, int idx, int hp, int32_t value, int32_t prev)
{
    int abs_bits = 12, prec_bits = 15;
    if (idx < 2) {
        abs_bits = type == TRANSLATION ? 9 - !hp : 12;
        prec_bits = type == TRANSLATION ? 3 - !hp : 6;
    }
    int prec_diff = 16 - prec_bits;
    int32_t round = idx % 3 == 2 ? 1 << 16 : 0, sub = idx % 3 == 2 ? 1 << prec_bits : 0;
    int32_t mx = 1 << abs_bits, d = value - round;
    if (d % (1 << prec_diff))
        return -1;
    int32_t x = d / (1 << prec_diff);
    if (x < -mx || x > mx)
        return -1;
    int32_t r = (prev >> prec_diff) - sub;
    put_subexp_with_ref(w, 2 * mx + 1, r + mx, x + mx);
    return 0;
}

static void film_grain(cb_bw *w, const VADecPictureParameterBufferAV1 *pp, unsigned frame_type)
{
    const VAFilmGrainStructAV1 *g = &pp->film_grain_info;
    cb_bw_flag(w, g->film_grain_info_fields.bits.apply_grain);
    if (!g->film_grain_info_fields.bits.apply_grain)
        return;
    cb_bw_put(w, 16, g->grain_seed);
    if (frame_type == INTER_FRAME)
        cb_bw_flag(w, 1); /* update_grain */
    cb_bw_put(w, 4, g->num_y_points);
    for (unsigned i = 0; i < g->num_y_points && i < 14; i++) {
        cb_bw_put(w, 8, g->point_y_value[i]);
        cb_bw_put(w, 8, g->point_y_scaling[i]);
    }
    unsigned from_luma = g->film_grain_info_fields.bits.chroma_scaling_from_luma;
    unsigned ncb = 0, ncr = 0;
    cb_bw_flag(w, from_luma);
    if (!from_luma && g->num_y_points) {
        ncb = g->num_cb_points < 10 ? g->num_cb_points : 10;
        ncr = g->num_cr_points < 10 ? g->num_cr_points : 10;
        cb_bw_put(w, 4, ncb);
        for (unsigned i = 0; i < ncb; i++) {
            cb_bw_put(w, 8, g->point_cb_value[i]);
            cb_bw_put(w, 8, g->point_cb_scaling[i]);
        }
        cb_bw_put(w, 4, ncr);
        for (unsigned i = 0; i < ncr; i++) {
            cb_bw_put(w, 8, g->point_cr_value[i]);
            cb_bw_put(w, 8, g->point_cr_scaling[i]);
        }
    }
    unsigned lag = g->film_grain_info_fields.bits.ar_coeff_lag;
    unsigned pos_luma = 2 * lag * (lag + 1), pos_chroma = pos_luma + (g->num_y_points ? 1 : 0);
    cb_bw_put(w, 2, g->film_grain_info_fields.bits.grain_scaling_minus_8);
    cb_bw_put(w, 2, lag);
    for (unsigned i = 0; g->num_y_points && i < pos_luma; i++)
        cb_bw_put(w, 8, (unsigned)(g->ar_coeffs_y[i] + 128));
    for (unsigned i = 0; (from_luma || ncb) && i < pos_chroma; i++)
        cb_bw_put(w, 8, (unsigned)(g->ar_coeffs_cb[i] + 128));
    for (unsigned i = 0; (from_luma || ncr) && i < pos_chroma; i++)
        cb_bw_put(w, 8, (unsigned)(g->ar_coeffs_cr[i] + 128));
    cb_bw_put(w, 2, g->film_grain_info_fields.bits.ar_coeff_shift_minus_6);
    cb_bw_put(w, 2, g->film_grain_info_fields.bits.grain_scale_shift);
    if (ncb) {
        cb_bw_put(w, 8, g->cb_mult);
        cb_bw_put(w, 8, g->cb_luma_mult);
        cb_bw_put(w, 9, g->cb_offset);
    }
    if (ncr) {
        cb_bw_put(w, 8, g->cr_mult);
        cb_bw_put(w, 8, g->cr_luma_mult);
        cb_bw_put(w, 9, g->cr_offset);
    }
    cb_bw_flag(w, g->film_grain_info_fields.bits.overlap_flag);
    cb_bw_flag(w, g->film_grain_info_fields.bits.clip_to_restricted_range);
}

/* tile_info(); returns NULL or why the tile layout cannot be coded. */
static const char *tile_info(cb_bw *w, const VADecPictureParameterBufferAV1 *pp, unsigned frame_w,
                             unsigned frame_h)
{
    unsigned mi_cols = 2 * ((frame_w + 7) >> 3), mi_rows = 2 * ((frame_h + 7) >> 3);
    unsigned sb_shift = SEQ(pp).use_128x128_superblock ? 5 : 4, sb_size = sb_shift + 2;
    unsigned sb_cols = (mi_cols + (1u << sb_shift) - 1) >> sb_shift;
    unsigned sb_rows = (mi_rows + (1u << sb_shift) - 1) >> sb_shift;
    unsigned max_width_sb = 4096 >> sb_size, max_area_sb = (4096 * 2304) >> (2 * sb_size);
    unsigned min_log2_cols = tile_log2(max_width_sb, sb_cols);
    unsigned max_log2_cols = tile_log2(1, sb_cols < 64 ? sb_cols : 64);
    unsigned max_log2_rows = tile_log2(1, sb_rows < 64 ? sb_rows : 64);
    unsigned min_log2_tiles = tile_log2(max_area_sb, sb_rows * sb_cols);
    if (min_log2_tiles < min_log2_cols)
        min_log2_tiles = min_log2_cols;
    unsigned cols = pp->tile_cols, rows = pp->tile_rows, cols_log2, rows_log2;
    cb_bw_flag(w, PIC(pp).uniform_tile_spacing_flag);
    if (PIC(pp).uniform_tile_spacing_flag) {
        for (cols_log2 = min_log2_cols; cols_log2 <= max_log2_cols; cols_log2++) {
            unsigned tw = (sb_cols + (1u << cols_log2) - 1) >> cols_log2;
            if ((sb_cols + tw - 1) / tw == cols)
                break;
        }
        if (cols_log2 > max_log2_cols)
            return "tile columns";
        for (unsigned i = min_log2_cols; i < cols_log2; i++)
            cb_bw_flag(w, 1);
        if (cols_log2 < max_log2_cols)
            cb_bw_flag(w, 0);
        unsigned min_log2_rows = min_log2_tiles > cols_log2 ? min_log2_tiles - cols_log2 : 0;
        for (rows_log2 = min_log2_rows; rows_log2 <= max_log2_rows; rows_log2++) {
            unsigned th = (sb_rows + (1u << rows_log2) - 1) >> rows_log2;
            if ((sb_rows + th - 1) / th == rows)
                break;
        }
        if (rows_log2 > max_log2_rows)
            return "tile rows";
        for (unsigned i = min_log2_rows; i < rows_log2; i++)
            cb_bw_flag(w, 1);
        if (rows_log2 < max_log2_rows)
            cb_bw_flag(w, 0);
    } else {
        /* VA has 63 sizes: the last tile takes what is left. */
        unsigned start = 0, widest = 0;
        for (unsigned i = 0; i < cols; i++) {
            if (start >= sb_cols)
                return "tile columns";
            unsigned max = sb_cols - start < max_width_sb ? sb_cols - start : max_width_sb;
            unsigned size = i + 1 < cols ? pp->width_in_sbs_minus_1[i] + 1u : sb_cols - start;
            if (size > max)
                return "tile columns";
            put_ns(w, max, size - 1);
            widest = size > widest ? size : widest;
            start += size;
        }
        if (start != sb_cols)
            return "tile columns";
        unsigned area = min_log2_tiles ? (sb_rows * sb_cols) >> (min_log2_tiles + 1) : sb_rows * sb_cols;
        unsigned max_height_sb = area / widest ? area / widest : 1;
        start = 0;
        for (unsigned i = 0; i < rows; i++) {
            if (start >= sb_rows)
                return "tile rows";
            unsigned max = sb_rows - start < max_height_sb ? sb_rows - start : max_height_sb;
            unsigned size = i + 1 < rows ? pp->height_in_sbs_minus_1[i] + 1u : sb_rows - start;
            if (size > max)
                return "tile rows";
            put_ns(w, max, size - 1);
            start += size;
        }
        if (start != sb_rows)
            return "tile rows";
        cols_log2 = tile_log2(1, cols);
        rows_log2 = tile_log2(1, rows);
    }
    if (cols_log2 + rows_log2) {
        cb_bw_put(w, cols_log2 + rows_log2, pp->context_update_tile_id);
        cb_bw_put(w, 2, 3); /* tile_size_bytes_minus_1: our tile group uses 4 */
    }
    return NULL;
}

/* uncompressed_header() for a picture, with the given refresh_frame_flags. A
 * provisional header is shown (a hidden key frame becomes intra-only) and
 * refreshes nothing. Returns NULL or why the header cannot be coded. */
static const char *frame_header(const av1_state *st, cb_buf *out, const VADecPictureParameterBufferAV1 *pp,
                                unsigned refresh, int provisional)
{
    cb_bw w;
    cb_bw_init(&w, out);
    unsigned type = PIC(pp).frame_type, show = PIC(pp).show_frame;
    if (provisional) {
        if (type == KEY_FRAME && !show)
            type = INTRA_ONLY_FRAME;
        show = 1;
        refresh = 0;
    }
    int intra = type == KEY_FRAME || type == INTRA_ONLY_FRAME;
    int er = PIC(pp).error_resilient_mode, refresh_coded = 1;
    if (type == SWITCH_FRAME || (type == KEY_FRAME && show)) {
        er = 1;
        refresh_coded = 0;
        refresh = ALL_FRAMES;
    }
    unsigned oh_bits = SEQ(pp).enable_order_hint ? pp->order_hint_bits_minus_1 + 1u : 0;
    unsigned upscaled_w = pp->frame_width_minus1 + 1u, frame_h = pp->frame_height_minus1 + 1u;
    unsigned denom = PIC(pp).use_superres ? pp->superres_scale_denominator : 8;
    if (denom < 8 || denom > 16)
        return "superres denominator";
    unsigned frame_w = (upscaled_w * 8 + denom / 2) / denom;
    int override = upscaled_w != st->max_w || frame_h != st->max_h;
    unsigned primary = intra || er ? PRIMARY_REF_NONE : pp->primary_ref_frame;
    if (primary > PRIMARY_REF_NONE)
        return "primary_ref_frame";
    int sct = PIC(pp).allow_screen_content_tools, integer_mv = PIC(pp).force_integer_mv;
    int intrabc = intra && sct && upscaled_w == frame_w && PIC(pp).allow_intrabc;

    cb_bw_flag(&w, 0); /* show_existing_frame */
    cb_bw_put(&w, 2, type);
    cb_bw_flag(&w, show);
    if (!show)
        cb_bw_flag(&w, PIC(pp).showable_frame);
    if (type != SWITCH_FRAME && !(type == KEY_FRAME && show))
        cb_bw_flag(&w, er);
    cb_bw_flag(&w, PIC(pp).disable_cdf_update);
    cb_bw_flag(&w, sct);
    if (sct)
        cb_bw_flag(&w, integer_mv);
    if (type != SWITCH_FRAME)
        cb_bw_flag(&w, override);
    else
        override = 1;
    cb_bw_put(&w, oh_bits, pp->order_hint);
    if (!intra && !er)
        cb_bw_put(&w, 3, primary);
    if (refresh_coded)
        cb_bw_put(&w, 8, refresh);
    if ((!intra || refresh != ALL_FRAMES) && er && oh_bits)
        for (unsigned i = 0; i < 8; i++)
            cb_bw_put(&w, oh_bits, st->slot[i].order_hint);
    if (!intra) {
        if (oh_bits)
            cb_bw_flag(&w, 0); /* frame_refs_short_signaling */
        for (unsigned i = 0; i < 7; i++)
            cb_bw_put(&w, 3, pp->ref_frame_idx[i]);
        if (override && !er)
            cb_bw_put(&w, 7, 0); /* found_ref: none, the size follows */
    }
    /* frame_size(), superres_params(), render_size() */
    if (override) {
        cb_bw_put(&w, 16, upscaled_w - 1);
        cb_bw_put(&w, 16, frame_h - 1);
    }
    cb_bw_flag(&w, PIC(pp).use_superres);
    if (PIC(pp).use_superres)
        cb_bw_put(&w, 3, denom - 9);
    cb_bw_flag(&w, 0); /* render_and_frame_size_different */
    if (intra) {
        if (sct && upscaled_w == frame_w)
            cb_bw_flag(&w, intrabc);
    } else {
        if (!integer_mv)
            cb_bw_flag(&w, PIC(pp).allow_high_precision_mv);
        cb_bw_flag(&w, pp->interp_filter == 4); /* is_filter_switchable */
        if (pp->interp_filter != 4)
            cb_bw_put(&w, 2, pp->interp_filter);
        cb_bw_flag(&w, PIC(pp).is_motion_mode_switchable);
        if (!er && oh_bits)
            cb_bw_flag(&w, PIC(pp).use_ref_frame_mvs);
    }
    if (!PIC(pp).disable_cdf_update)
        cb_bw_flag(&w, PIC(pp).disable_frame_end_update_cdf);

    const char *why = tile_info(&w, pp, frame_w, frame_h);
    if (why)
        return why;

    /* quantization_params() */
    cb_bw_put(&w, 8, pp->base_qindex);
    put_delta_q(&w, pp->y_dc_delta_q);
    int diff_uv = pp->u_dc_delta_q != pp->v_dc_delta_q || pp->u_ac_delta_q != pp->v_ac_delta_q;
    cb_bw_flag(&w, diff_uv);
    put_delta_q(&w, pp->u_dc_delta_q);
    put_delta_q(&w, pp->u_ac_delta_q);
    if (diff_uv) {
        put_delta_q(&w, pp->v_dc_delta_q);
        put_delta_q(&w, pp->v_ac_delta_q);
    }
    cb_bw_flag(&w, pp->qmatrix_fields.bits.using_qmatrix);
    if (pp->qmatrix_fields.bits.using_qmatrix) {
        cb_bw_put(&w, 4, pp->qmatrix_fields.bits.qm_y);
        cb_bw_put(&w, 4, pp->qmatrix_fields.bits.qm_u);
        cb_bw_put(&w, 4, pp->qmatrix_fields.bits.qm_v);
    }

    /* segmentation_params() */
    static const uint8_t seg_bits[8] = { 8, 6, 6, 6, 6, 3, 0, 0 }, seg_signed[8] = { 1, 1, 1, 1, 1, 0, 0, 0 };
    const VASegmentationStructAV1 *seg = &pp->seg_info;
    int seg_on = seg->segment_info_fields.bits.enabled;
    cb_bw_flag(&w, seg_on);
    if (seg_on) {
        int update_data = 1;
        if (primary != PRIMARY_REF_NONE) {
            cb_bw_flag(&w, seg->segment_info_fields.bits.update_map);
            if (seg->segment_info_fields.bits.update_map)
                cb_bw_flag(&w, seg->segment_info_fields.bits.temporal_update);
            update_data = seg->segment_info_fields.bits.update_data;
            cb_bw_flag(&w, update_data);
        }
        for (unsigned i = 0; i < 8 && update_data; i++)
            for (unsigned j = 0; j < 8; j++) {
                int on = (seg->feature_mask[i] >> j) & 1;
                cb_bw_flag(&w, on);
                if (on && seg_signed[j])
                    put_su(&w, 1 + seg_bits[j], seg->feature_data[i][j]);
                else if (on)
                    cb_bw_put(&w, seg_bits[j], (unsigned)seg->feature_data[i][j]);
            }
    }

    /* delta_q_params(), delta_lf_params() */
    int dq = pp->base_qindex > 0 && pp->mode_control_fields.bits.delta_q_present_flag;
    if (pp->base_qindex > 0)
        cb_bw_flag(&w, dq);
    if (dq) {
        cb_bw_put(&w, 2, pp->mode_control_fields.bits.log2_delta_q_res);
        if (!intrabc) {
            int dlf = pp->mode_control_fields.bits.delta_lf_present_flag;
            cb_bw_flag(&w, dlf);
            if (dlf) {
                cb_bw_put(&w, 2, pp->mode_control_fields.bits.log2_delta_lf_res);
                cb_bw_flag(&w, pp->mode_control_fields.bits.delta_lf_multi);
            }
        }
    }

    int coded_lossless = 1;
    for (unsigned i = 0; i < 8; i++) {
        int q = pp->base_qindex;
        if (seg_on && (seg->feature_mask[i] & 1))
            q += seg->feature_data[i][0];
        coded_lossless &= q <= 0 && !pp->y_dc_delta_q && !pp->u_dc_delta_q && !pp->u_ac_delta_q &&
                          !pp->v_dc_delta_q && !pp->v_ac_delta_q;
    }
    int all_lossless = coded_lossless && frame_w == upscaled_w;

    /* loop_filter_params(): deltas are always sent in full */
    if (!coded_lossless && !intrabc) {
        cb_bw_put(&w, 6, pp->filter_level[0]);
        cb_bw_put(&w, 6, pp->filter_level[1]);
        if (pp->filter_level[0] || pp->filter_level[1]) {
            cb_bw_put(&w, 6, pp->filter_level_u);
            cb_bw_put(&w, 6, pp->filter_level_v);
        }
        cb_bw_put(&w, 3, pp->loop_filter_info_fields.bits.sharpness_level);
        int deltas = pp->loop_filter_info_fields.bits.mode_ref_delta_enabled;
        cb_bw_flag(&w, deltas);
        if (deltas) {
            cb_bw_flag(&w, 1); /* loop_filter_delta_update */
            for (unsigned i = 0; i < 8; i++) {
                cb_bw_flag(&w, 1);
                put_su(&w, 7, pp->ref_deltas[i]);
            }
            for (unsigned i = 0; i < 2; i++) {
                cb_bw_flag(&w, 1);
                put_su(&w, 7, pp->mode_deltas[i]);
            }
        }
    }

    /* cdef_params() */
    if (!coded_lossless && !intrabc && SEQ(pp).enable_cdef) {
        cb_bw_put(&w, 2, pp->cdef_damping_minus_3);
        cb_bw_put(&w, 2, pp->cdef_bits);
        for (unsigned i = 0; i < (1u << (pp->cdef_bits & 3)); i++) {
            cb_bw_put(&w, 6, pp->cdef_y_strengths[i]); /* primary << 2 | secondary, as coded */
            cb_bw_put(&w, 6, pp->cdef_uv_strengths[i]);
        }
    }

    /* lr_params(): VA has FrameRestorationType, the bitstream lr_type */
    if (!all_lossless && !intrabc) {
        static const uint8_t lr_type[4] = { 0, 2, 3, 1 };
        unsigned types[3] = { pp->loop_restoration_fields.bits.yframe_restoration_type,
                              pp->loop_restoration_fields.bits.cbframe_restoration_type,
                              pp->loop_restoration_fields.bits.crframe_restoration_type };
        int uses = 0, uses_chroma = 0;
        for (unsigned i = 0; i < 3; i++) {
            cb_bw_put(&w, 2, lr_type[types[i]]);
            uses |= types[i] != 0;
            uses_chroma |= i && types[i];
        }
        if (uses) {
            unsigned shift = pp->loop_restoration_fields.bits.lr_unit_shift;
            if (SEQ(pp).use_128x128_superblock) {
                cb_bw_put(&w, 1, shift - 1);
            } else {
                cb_bw_flag(&w, shift > 0);
                if (shift)
                    cb_bw_put(&w, 1, shift - 1);
            }
            if (uses_chroma)
                cb_bw_flag(&w, pp->loop_restoration_fields.bits.lr_uv_shift);
        }
    }

    if (!coded_lossless)
        cb_bw_flag(&w, pp->mode_control_fields.bits.tx_mode == 2); /* tx_mode_select */
    if (!intra)
        cb_bw_flag(&w, pp->mode_control_fields.bits.reference_select);
    if (!intra && pp->mode_control_fields.bits.reference_select && oh_bits && skip_mode_allowed(st, pp, oh_bits))
        cb_bw_flag(&w, pp->mode_control_fields.bits.skip_mode_present);
    if (!intra && !er)
        cb_bw_flag(&w, PIC(pp).allow_warped_motion);
    cb_bw_flag(&w, pp->mode_control_fields.bits.reduced_tx_set_used);

    /* global_motion_params() */
    if (!intra) {
        const slot_t *ref = primary == PRIMARY_REF_NONE ? NULL : &st->slot[pp->ref_frame_idx[primary] & 7];
        for (unsigned i = 0; i < 7; i++) {
            const VAWarpedMotionParamsAV1 *wm = &pp->wm[i];
            const int32_t *prev = ref ? ref->gm[i] : gm_default, *m = wm->wmmat;
            int t = (int)wm->wmtype, hp = PIC(pp).allow_high_precision_mv;
            if (t < IDENTITY || t > AFFINE)
                return "global motion type";
            cb_bw_flag(&w, t != IDENTITY);
            if (t != IDENTITY) {
                cb_bw_flag(&w, t == ROTZOOM);
                if (t != ROTZOOM)
                    cb_bw_flag(&w, t == TRANSLATION);
            }
            int bad = 0;
            if (t >= ROTZOOM) {
                bad |= global_param(&w, t, 2, hp, m[2], prev[2]) | global_param(&w, t, 3, hp, m[3], prev[3]);
                if (t == AFFINE)
                    bad |= global_param(&w, t, 4, hp, m[4], prev[4]) | global_param(&w, t, 5, hp, m[5], prev[5]);
                else
                    bad |= m[4] != -m[3] || m[5] != m[2];
            }
            if (t >= TRANSLATION)
                bad |= global_param(&w, t, 0, hp, m[0], prev[0]) | global_param(&w, t, 1, hp, m[1], prev[1]);
            if (bad)
                return "global motion parameters";
        }
    }

    if (SEQ(pp).film_grain_params_present && (show || PIC(pp).showable_frame))
        film_grain(&w, pp, type);
    cb_bw_trailing(&w);
    return NULL;
}

/* ---- Temporal units ------------------------------------------------------- */

static void put_show_existing(cb_buf *out, unsigned slot)
{
    uint8_t b = (uint8_t)(0x80 | slot << 4 | 0x08); /* show_existing_frame, slot, trailing bit */
    put_obu(out, OBU_FRAME_HEADER, &b, 1);
}

static void put_temporal_delimiter(cb_buf *out) { put_obu(out, OBU_TEMPORAL_DELIMITER, NULL, 0); }

/* Appends the sequence header if this picture needs one. With `commit`, the
 * header becomes the stream's; otherwise (provisional) nothing changes. */
static const char *put_sequence_header(av1_state *st, cb_buf *out, const VADecPictureParameterBufferAV1 *pp,
                                       int commit)
{
    unsigned w = pp->frame_width_minus1 + 1u, h = pp->frame_height_minus1 + 1u;
    int key = PIC(pp).frame_type == KEY_FRAME;
    if (key) { /* the maximum only grows, so the header stays put */
        st->max_w = w > st->max_w ? w : st->max_w;
        st->max_h = h > st->max_h ? h : st->max_h;
    }
    if (w > st->max_w || h > st->max_h)
        return "frame larger than the sequence's maximum";
    cb_buf_reset(&st->hdr);
    sequence_header(&st->hdr, pp, st->max_w, st->max_h);
    int same = st->seq_hdr.len == st->hdr.len && st->hdr.len &&
               memcmp(st->seq_hdr.data, st->hdr.data, st->hdr.len) == 0;
    if (!same && !key)
        return "sequence header changed without a key frame";
    if (key || !same) {
        put_obu(out, OBU_SEQUENCE_HEADER, st->hdr.data, st->hdr.len);
        if (commit) {
            cb_buf_reset(&st->seq_hdr);
            cb_buf_append(&st->seq_hdr, st->hdr.data, st->hdr.len);
        }
    }
    return NULL;
}

/* The held picture shown, refreshing nothing: its pixels, no state change. */
static int provisional_unit(av1_state *st, cb_buf *out)
{
    cb_buf_reset(out);
    put_temporal_delimiter(out);
    cb_buf_reset(&st->tmp);
    if (put_sequence_header(st, out, &st->held.pp, 0) || frame_header(st, &st->tmp, &st->held.pp, 0, 1))
        return -1;
    put_obu(out, OBU_FRAME_HEADER, st->tmp.data, st->tmp.len);
    put_obu(out, OBU_TILE_GROUP, st->held.tiles.data, st->held.tiles.len);
    return out->oom ? -1 : 0;
}

/* Emits the held picture with its refresh_frame_flags, and records what the
 * decoder's reference slots hold afterwards. */
static int emit_held(cb_context *c, unsigned refresh)
{
    av1_state *st = c->state;
    const VADecPictureParameterBufferAV1 *pp = &st->held.pp;
    unsigned type = PIC(pp).frame_type, show = PIC(pp).show_frame;
    unsigned w = pp->frame_width_minus1 + 1u, h = pp->frame_height_minus1 + 1u;
    st->held.valid = 0;
    cb_buf_reset(&st->out);
    put_temporal_delimiter(&st->out);
    const char *why = put_sequence_header(st, &st->out, pp, 1);
    cb_buf_reset(&st->tmp);
    if (!why)
        why = frame_header(st, &st->tmp, pp, refresh, 0);
    if (why) {
        cb_unsupported(c, why);
        return CB_UNSUPPORTED;
    }
    put_obu(&st->out, OBU_FRAME_HEADER, st->tmp.data, st->tmp.len);
    put_obu(&st->out, OBU_TILE_GROUP, st->held.tiles.data, st->held.tiles.len);
    unsigned flags = show ? (type == KEY_FRAME ? CB_FRAME_KEY : 0) : CB_FRAME_HIDDEN;
    if (!show && PIC(pp).showable_frame && type != KEY_FRAME && refresh)
        put_show_existing(&st->out, (unsigned)__builtin_ctz(refresh));
    if (st->out.oom)
        return -1;
    cb_emit(c, st->held.seq, st->held.shown, flags, st->out.data, st->out.len, w, h);

    slot_t s = { st->held.surface, st->held.shown, st->held.seq, (uint8_t)type, pp->order_hint,
                 (uint16_t)w, (uint16_t)h, { { 0 } } };
    int intra = type == KEY_FRAME || type == INTRA_ONLY_FRAME;
    for (unsigned i = 0; i < 7; i++)
        memcpy(s.gm[i], intra ? gm_default : pp->wm[i].wmmat, sizeof(s.gm[i]));
    for (unsigned i = 0; i < 8; i++)
        if (refresh & (1u << i))
            st->slot[i] = s;
    /* Decoding locally, a hidden key frame gets its pixels now: the app shows
     * it with show_existing_frame, which this stream only repeats at the next
     * picture, after the app has read the surface. */
    if (type == KEY_FRAME && !show && !st->held.given && c->mode == CB_MODE_DECODE && c->local &&
        provisional_unit(st, &st->out) == 0)
        cb_local_decode(c->local, st->held.seq, st->out.data, st->out.len);
    return 0;
}

/* The app showed a key frame with show_existing_frame (every slot now holds
 * it): send the same, which resets the slots the same way. */
static int show_existing_key(cb_context *c, const VADecPictureParameterBufferAV1 *pp)
{
    av1_state *st = c->state;
    for (unsigned i = 1; i < 8; i++)
        if (pp->ref_frame_map[i] != pp->ref_frame_map[0])
            return -1;
    for (unsigned j = 0; j < 8; j++) {
        if (st->slot[j].surface != pp->ref_frame_map[0] || st->slot[j].frame_type != KEY_FRAME ||
            pp->ref_frame_map[0] == VA_INVALID_SURFACE)
            continue;
        cb_buf_reset(&st->out);
        put_temporal_delimiter(&st->out);
        put_show_existing(&st->out, j);
        if (st->out.oom)
            return -1;
        slot_t k = st->slot[j];
        cb_emit(c, k.seq, k.shown, 0, st->out.data, st->out.len, k.w, k.h);
        for (unsigned i = 0; i < 8; i++)
            st->slot[i] = k;
        return 0;
    }
    return -1;
}

/* refresh_frame_flags for the held picture when nothing shows them (the next
 * picture is a shown key frame, or there is none): they no longer matter, except
 * that a hidden frame needs a slot to be shown from. */
static unsigned unknown_refresh(const av1_state *st)
{
    const VADecPictureParameterBufferAV1 *pp = &st->held.pp;
    return !PIC(pp).show_frame && PIC(pp).showable_frame && PIC(pp).frame_type != KEY_FRAME ? 1 : 0;
}

/* The tile group OBU payload: every tile, in order, with 4-byte sizes. */
static int tile_group(av1_state *st, const cb_picture *p, const VADecPictureParameterBufferAV1 *pp)
{
    unsigned cols = pp->tile_cols, rows = pp->tile_rows, n = cols * rows;
    if (!cols || !rows || cols > 64 || rows > 64 || n > MAX_TILES)
        return -1;
    for (unsigned t = 0; t < n; t++)
        st->tile[t].data = NULL;
    for (unsigned i = 0; i < p->nslices; i++) {
        const cb_slice *sl = &p->slices[i];
        if (sl->elem_size < sizeof(VASliceParameterBufferAV1))
            return -1;
        for (unsigned k = 0; k < sl->count; k++) {
            const VASliceParameterBufferAV1 *sp =
                (const void *)((const uint8_t *)sl->params + (size_t)k * sl->elem_size);
            unsigned t = sp->tile_row * cols + sp->tile_column;
            if (sp->tile_row >= rows || sp->tile_column >= cols || st->tile[t].data || !sp->slice_data_size ||
                (size_t)sp->slice_data_offset + sp->slice_data_size > sl->data_size)
                return -1;
            st->tile[t].data = sl->data + sp->slice_data_offset;
            st->tile[t].size = sp->slice_data_size;
        }
    }
    cb_buf *out = &st->held.tiles;
    cb_buf_reset(out);
    if (n > 1)
        cb_buf_u8(out, 0); /* tile_start_and_end_present_flag = 0, byte_alignment() */
    for (unsigned t = 0; t < n; t++) {
        if (!st->tile[t].data)
            return -1;
        if (t + 1 < n)
            cb_buf_le32(out, st->tile[t].size - 1);
        cb_buf_append(out, st->tile[t].data, st->tile[t].size);
    }
    return out->oom ? -1 : 0;
}

/* With film grain, the app decodes into one surface (the reference) and
 * presents another, current_display_picture, which carries the picture. */
static VASurfaceID av1_display(cb_context *c, const cb_picture *p)
{
    (void)c;
    const VADecPictureParameterBufferAV1 *pp = p->pp;
    if (p->pp_size < sizeof(*pp) || !pp->film_grain_info.film_grain_info_fields.bits.apply_grain)
        return p->target;
    return pp->current_display_picture;
}

static const char *refused(const VADecPictureParameterBufferAV1 *pp)
{
    if (pp->profile != 0)
        return "profile 1 or 2 (4:4:4, 4:2:2 or 12-bit)";
    if (pp->bit_depth_idx > 1)
        return "12-bit";
    if (SEQ(pp).mono_chrome)
        return "monochrome"; /* FFmpeg never sends it to VA, so it is untested */
    if (!SEQ(pp).subsampling_x || !SEQ(pp).subsampling_y)
        return "not 4:2:0";
    if (PIC(pp).large_scale_tile || pp->anchor_frames_num)
        return "large-scale tile";
    return NULL;
}

static int av1_picture(cb_context *c, const cb_picture *p, uint32_t seq)
{
    av1_state *st = c->state;
    if (!st->init) {
        for (unsigned i = 0; i < 8; i++)
            st->slot[i].surface = VA_INVALID_SURFACE;
        st->max_w = c->width;
        st->max_h = c->height;
        st->init = 1;
    }
    if (p->pp_size < sizeof(VADecPictureParameterBufferAV1))
        return -1;
    const VADecPictureParameterBufferAV1 *pp = p->pp;
    const char *why = refused(pp);
    if (why) {
        cb_unsupported(c, why);
        return CB_UNSUPPORTED;
    }
    unsigned type = PIC(pp).frame_type;
    int shown_key = type == KEY_FRAME && PIC(pp).show_frame;

    /* The held picture's refresh_frame_flags: the slots that now hold it. A
     * shown key frame's ref_frame_map says nothing (it resets them all). */
    if (st->held.valid) {
        unsigned refresh = 0;
        for (unsigned i = 0; i < 8 && !shown_key; i++)
            if (pp->ref_frame_map[i] == st->held.surface)
                refresh |= 1u << i;
        int held_key = st->held.pp.pic_info_fields.bits.frame_type == KEY_FRAME;
        if (shown_key)
            refresh = unknown_refresh(st);
        int r = emit_held(c, refresh);
        if (r)
            return r;
        /* Every slot holding a hidden key frame: the app showed it. */
        if (held_key && refresh == ALL_FRAMES && show_existing_key(c, pp) < 0)
            return -1;
    }
    if (!shown_key) {
        int same = 1;
        for (unsigned i = 0; i < 8; i++)
            same &= pp->ref_frame_map[i] == st->slot[i].surface;
        if (!same && show_existing_key(c, pp) < 0) {
            cb_unsupported(c, "reference slots changed outside the stream");
            return CB_UNSUPPORTED;
        }
    }

    if (tile_group(st, p, pp) < 0)
        return -1;
    st->held.pp = *pp;
    st->held.pp.anchor_frames_list = NULL;
    st->held.surface = p->target;
    st->held.shown = av1_display(c, p);
    if (!cb_get_surface(c->drv, st->held.shown))
        st->held.shown = p->target;
    st->held.seq = seq;
    st->held.valid = 1;
    st->held.given = 0;
    if (shown_key || type == SWITCH_FRAME)
        return emit_held(c, ALL_FRAMES);
    return 0;
}

static void av1_flush(cb_context *c)
{
    av1_state *st = c->state;
    if (st->held.valid && !c->unsupported)
        emit_held(c, unknown_refresh(st));
    st->held.valid = 0;
}

static int av1_provisional(cb_context *c, cb_buf *out, uint32_t *seq)
{
    av1_state *st = c->state;
    if (!st->held.valid || st->held.given || provisional_unit(st, out))
        return -1;
    st->held.given = 1;
    *seq = st->held.seq;
    return 0;
}

static void av1_fini(cb_context *c)
{
    av1_state *st = c->state;
    cb_buf_free(&st->held.tiles);
    cb_buf_free(&st->seq_hdr);
    cb_buf_free(&st->out);
    cb_buf_free(&st->tmp);
    cb_buf_free(&st->hdr);
}

const cb_codec cb_codec_av1 = {
    .name = "av1",
    .id = CB_CODEC_AV1,
    .state_size = sizeof(av1_state),
    .picture = av1_picture,
    .flush = av1_flush,
    .provisional = av1_provisional,
    .display = av1_display,
    .fini = av1_fini,
};
