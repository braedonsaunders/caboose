/* Source-level AV1 state/OBU regression tests. Synthetic tile bytes deliberately
 * test header/state behavior, not decoder conformance (roundtrip.sh does that). */
#include <assert.h>
#include <stdio.h>
#include "../src/av1.c"

static cb_buf emitted;
static unsigned emits;
void cb_emit(cb_context *c, uint32_t seq, VASurfaceID surface, unsigned flags,
             const uint8_t *data, size_t len, unsigned w, unsigned h)
{
    (void)c; (void)seq; (void)surface; (void)flags; (void)w; (void)h;
    cb_buf_reset(&emitted);
    cb_buf_append(&emitted, data, len);
    emits++;
}
void cb_unsupported(cb_context *c, const char *why) { (void)why; c->unsupported = 1; }
cb_surface *cb_get_surface(cb_driver *d, VASurfaceID id) { (void)d; (void)id; return NULL; }
void cb_local_decode(cb_local *l, uint32_t seq, const uint8_t *data, size_t len)
{ (void)l; (void)seq; (void)data; (void)len; assert(!"unexpected local decoder call"); }

static void setup(av1_state *st)
{
    memset(st, 0, sizeof(*st));
    st->max_w = st->max_h = 64;
    st->held.valid = 1;
    st->held.seq = 42;
    st->held.surface = st->held.shown = 9;
    VADecPictureParameterBufferAV1 *pp = &st->held.pp;
    pp->frame_width_minus1 = pp->frame_height_minus1 = 63;
    pp->seq_info_fields.fields.subsampling_x = pp->seq_info_fields.fields.subsampling_y = 1;
    pp->pic_info_fields.bits.frame_type = INTER_FRAME;
    pp->pic_info_fields.bits.show_frame = 1;
    pp->pic_info_fields.bits.uniform_tile_spacing_flag = 1;
    pp->tile_cols = pp->tile_rows = 1;
    pp->primary_ref_frame = PRIMARY_REF_NONE;
    for (unsigned i = 0; i < 8; i++) st->slot[i].surface = 100 + i;
    sequence_header(&st->seq_hdr, pp, 64, 64);
    cb_buf_u8(&st->held.tiles, 0);
}

/* Find a size-delimited OBU and count frame headers, independently of writer. */
static const uint8_t *header(const cb_buf *b, size_t *len, unsigned *count)
{
    const uint8_t *first = NULL;
    *count = 0;
    for (size_t i = 0; i < b->len;) {
        unsigned type = (b->data[i++] >> 3) & 15;
        size_t n = 0; unsigned shift = 0; uint8_t byte;
        do {
            assert(i < b->len && shift < 32);
            byte = b->data[i++]; n |= (size_t)(byte & 127) << shift; shift += 7;
        } while (byte & 128);
        assert(n <= b->len - i);
        if (type == OBU_FRAME_HEADER) {
            (*count)++;
            if (!first) { first = b->data + i; *len = n; }
        }
        i += n;
    }
    assert(first);
    return first;
}

static void check_shown_inter_refresh_zero(const cb_buf *b)
{
    size_t n = 0; unsigned count;
    const uint8_t *h = header(b, &n, &count);
    assert(count == 1);
    cb_br r; cb_br_init(&r, h, n);
    assert(cb_br_get(&r, 1) == 0); /* no show_existing_frame */
    assert(cb_br_get(&r, 2) == INTER_FRAME);
    assert(cb_br_get(&r, 1) == 1); /* show_frame */
    assert(cb_br_get(&r, 1) == 0); /* error_resilient_mode */
    assert(cb_br_get(&r, 1) == 0); /* disable_cdf_update */
    assert(cb_br_get(&r, 1) == 0); /* allow_screen_content_tools */
    assert(cb_br_get(&r, 1) == 0); /* frame_size_override_flag */
    assert(cb_br_get(&r, 3) == PRIMARY_REF_NONE);
    assert(cb_br_get(&r, 8) == 0); /* refresh_frame_flags */
    assert(!r.overrun);
}

int main(void)
{
    av1_state st; setup(&st);
    cb_context c = { .state = &st };
    cb_buf out = {0};
    slot_t before[8]; memcpy(before, st.slot, sizeof(before));
    /* Syncing another outstanding surface cannot consume the paused frame. */
    assert(av1_provisional(&c, &out, 41) == -1);
    assert(!st.held.given && st.held.valid && !out.len);
    assert(av1_provisional(&c, &out, 42) == 0);
    check_shown_inter_refresh_zero(&out);
    assert(st.held.given && st.held.valid && emits == 0);
    assert(memcmp(before, st.slot, sizeof(before)) == 0);
    assert(av1_provisional(&c, &out, 42) == -1); /* bounded: once */
    /* Resume commits the real refresh mask; provisional never consumes it. */
    assert(emit_held(&c, 0x24) == 0);
    for (unsigned i = 0; i < 8; i++)
        assert(st.slot[i].surface == ((0x24 & (1u << i)) ? 9u : 100u + i));
    assert(!st.held.valid && emits == 1);
    cb_buf_free(&out); av1_fini(&c);

    /* A hidden frame without a refreshed slot cannot use show_existing. */
    for (unsigned mask = 0; mask <= 1; mask++) {
        setup(&st);
        st.held.pp.pic_info_fields.bits.show_frame = 0;
        st.held.pp.pic_info_fields.bits.showable_frame = 1;
        assert(emit_held(&c, mask) == 0);
        size_t n = 0; unsigned count; header(&emitted, &n, &count);
        assert(count == (mask ? 2u : 1u));
        if (mask) assert(emitted.data[emitted.len - 1] == 0x88); /* slot 0 */
        av1_fini(&c);
    }
    /* Destruction flush is terminal and bounded, never a pause timer. */
    setup(&st); unsigned prior = emits;
    av1_flush(&c); av1_flush(&c);
    assert(emits == prior + 1 && !st.held.valid);
    check_shown_inter_refresh_zero(&emitted);
    av1_fini(&c); cb_buf_free(&emitted);
    puts("av1-state: ok");
    return 0;
}
