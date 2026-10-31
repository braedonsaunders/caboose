/*
 * test_scene_wire.c — Unit & integration test suite for the Caboose Linux Guest
 * Scene Graph Interceptor (0x25 / 0x26 / 0x9A), Headless Liveness Invariant,
 * and Implicit WSI/Zink Promotion Gate.
 *
 * SPDX-License-Identifier: MIT
 */

#include "../src/scene_wire.h"

#include <assert.h>
#include <math.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

/* ========================================================================== *
 * External symbols from caboose_scene_cairo.c & caboose_wsi_promote.c        *
 * ========================================================================== */

extern void     caboose_scene_reconnect(void);
extern void     caboose_scene_attach_fd(int fd);
extern bool     caboose_scene_is_passthrough(void);
extern uint64_t caboose_scene_register_font(
    const void *font_bytes,
    size_t      font_len,
    uint32_t    face_index,
    const char *family
);
extern void     caboose_scene_begin_frame(uint64_t surface_id, uint64_t root_id, bool reset);
extern bool     caboose_scene_push_rect(
    uint64_t node_id,
    double   x,
    double   y,
    double   w,
    double   h,
    double   radius,
    uint32_t color_rgba
);
extern bool     caboose_scene_push_scroll(
    uint64_t        node_id,
    double          x,
    double          y,
    double          viewport_w,
    double          viewport_h,
    double          content_w,
    double          content_h,
    double          scroll_x,
    double          scroll_y,
    const uint64_t *children,
    size_t          children_count
);
extern bool     caboose_scene_push_glyphs(
    uint64_t              node_id,
    uint64_t              font_hash,
    uint32_t              face_index,
    double                font_size,
    double                origin_x,
    double                origin_y,
    uint32_t              color_rgba,
    const cb_glyph_pos_t *glyphs,
    size_t                glyph_count
);
extern bool     caboose_scene_commit_frame(uint64_t pts_us);
extern bool     caboose_scene_poll_scroll(cb_scene_scroll_event_t *out_event);

extern bool     caboose_wsi_should_promote_process_ex(
    const char *proc_name,
    const char *auto_promote_env,
    const char *seat_env,
    const char *disable_env,
    const char *force_env
);
extern bool     caboose_wsi_should_promote_process(const char *proc_name_override);
extern bool     caboose_wsi_apply_zink_env_if_promoted(const char *proc_name_override);

/* ========================================================================== *
 * Test 1: xxHash64 Reference Vector Verification                             *
 * ========================================================================== */

static void test_xxh64_vectors(void) {
    uint64_t empty_hash = cb_xxh64("", 0, 0ULL);
    assert(empty_hash == 0xEF46DB3751D8E999ULL);

    /* Multi-chunk (>= 32 bytes) deterministic sanity check */
    const char *long_input = "Caboose OS Decomposition Zero Server Video Scene Graph Lane";
    uint64_t h1 = cb_xxh64(long_input, strlen(long_input), 0ULL);
    uint64_t h2 = cb_xxh64(long_input, strlen(long_input), 0ULL);
    assert(h1 == h2 && h1 != 0ULL && h1 != empty_hash);

    printf("[PASS] test_xxh64_vectors (cb_xxh64(\"\", 0) == 0xEF46DB3751D8E999ULL)\n");
}

/* ========================================================================== *
 * Recursive Canonical CBOR Validator (RFC 8949 Section 4.2.1)                *
 * ========================================================================== */

static bool cbor_skip_and_validate_canonical(
    const uint8_t *buf,
    size_t         len,
    size_t        *pos
) {
    uint8_t major = 0;
    uint64_t arg = 0;
    if (!cb_cbor_read_type_arg(buf, len, pos, &major, &arg)) {
        return false;
    }

    switch (major) {
        case 0u: /* unsigned int */
        case 1u: /* negative int */
        case 7u: /* bool / simple / float64 */
            return true;

        case 2u: /* byte string */
        case 3u: /* text string */
            if (*pos + (size_t)arg > len) {
                return false;
            }
            *pos += (size_t)arg;
            return true;

        case 4u: /* array */
            for (uint64_t i = 0; i < arg; i++) {
                if (!cbor_skip_and_validate_canonical(buf, len, pos)) {
                    return false;
                }
            }
            return true;

        case 5u: { /* map: verify canonical key ordering (length first, then lex) */
            const uint8_t *prev_key = NULL;
            size_t prev_key_len = 0;

            for (uint64_t i = 0; i < arg; i++) {
                uint8_t kmaj = 0;
                uint64_t klen = 0;
                if (!cb_cbor_read_type_arg(buf, len, pos, &kmaj, &klen) || kmaj != 3u) {
                    return false;
                }
                if (*pos + (size_t)klen > len) {
                    return false;
                }
                const uint8_t *cur_key = buf + *pos;
                size_t cur_key_len = (size_t)klen;
                *pos += cur_key_len;

                if (prev_key != NULL) {
                    /* RFC 8949 canonical order: shorter byte length first, then lex */
                    if (cur_key_len < prev_key_len) {
                        return false;
                    }
                    if (cur_key_len == prev_key_len &&
                        memcmp(prev_key, cur_key, cur_key_len) >= 0) {
                        return false;
                    }
                }
                prev_key = cur_key;
                prev_key_len = cur_key_len;

                /* Validate nested value recursively */
                if (!cbor_skip_and_validate_canonical(buf, len, pos)) {
                    return false;
                }
            }
            return true;
        }

        default:
            return false;
    }
}

/* ========================================================================== *
 * Test 2: AF_UNIX Socket Pair Wire Framing, Canonical CBOR, Font Dedup,      *
 *         Packed 10-Byte Glyph Records, and 0x9A Scroll Readback             *
 * ========================================================================== */

static void test_wire_socket_font_dedup_glyphs_and_scroll(void) {
    int sv[2] = { -1, -1 };
    int rc = socketpair(AF_UNIX, SOCK_STREAM, 0, sv);
    assert(rc == 0);

    /* Attach client end (sv[0]) to the scene interceptor; sv[1] is caboose-display */
    caboose_scene_attach_fd(sv[0]);
    assert(!caboose_scene_is_passthrough());

    /* Register a synthetic OpenType font blob -> should immediately emit 0x25 once */
    const uint8_t fake_ttf[] = "OTTO-Caboose-Inter-Regular-Subset-Font-Data";
    uint64_t expected_font_hash = cb_xxh64(fake_ttf, sizeof(fake_ttf), 0ULL);
    uint64_t font_hash = caboose_scene_register_font(fake_ttf, sizeof(fake_ttf), 0u, "Inter");
    assert(font_hash == expected_font_hash);

    /* Frame 1: push rect, scroll container, and 3 positioned glyphs */
    caboose_scene_begin_frame(42ULL, 100ULL, true);
    assert(caboose_scene_push_rect(101ULL, 0.0, 0.0, 800.0, 600.0, 12.0, 0x1E1E2EFFu));

    uint64_t scroll_children[1] = { 103ULL };
    assert(caboose_scene_push_scroll(
        102ULL,
        16.0, 48.0,
        768.0, 520.0,
        768.0, 2400.0,
        0.0, 128.5,
        scroll_children, 1u
    ));

    const cb_glyph_pos_t glyphs[3] = {
        { .glyph_id = 36u,  .x = 12.5f,  .y = 24.0f },
        { .glyph_id = 72u,  .x = 21.25f, .y = 24.0f },
        { .glyph_id = 108u, .x = 30.75f, .y = 24.0f }
    };
    assert(caboose_scene_push_glyphs(
        103ULL,
        font_hash,
        0u,
        15.0,
        16.0,
        64.0,
        0xCDD6F4FFu,
        glyphs,
        3u
    ));
    assert(caboose_scene_commit_frame(123456789ULL));

    /* Frame 2: re-register and push glyphs with the SAME font -> MUST NOT re-send 0x25! */
    uint64_t font_hash_again = caboose_scene_register_font(fake_ttf, sizeof(fake_ttf), 0u, "Inter");
    assert(font_hash_again == expected_font_hash);

    caboose_scene_begin_frame(42ULL, 100ULL, false);
    assert(caboose_scene_push_glyphs(
        103ULL,
        font_hash,
        0u,
        15.0,
        16.0,
        64.0,
        0xCDD6F4FFu,
        glyphs,
        3u
    ));
    assert(caboose_scene_commit_frame(123465122ULL));

    /* Read all frames emitted on sv[1] */
    uint8_t rx[4096];
    ssize_t nread = recv(sv[1], rx, sizeof(rx), 0);
    assert(nread > (ssize_t)CB_FRAME_HEADER_LEN);

    size_t offset = 0;
    size_t font_msg_count = 0;
    size_t commit_msg_count = 0;

    while (offset < (size_t)nread) {
        assert(offset + CB_FRAME_HEADER_LEN <= (size_t)nread);
        uint8_t msg_type = rx[offset];
        uint32_t payload_len = cb_read_le32(rx + offset + 1);
        const uint8_t *payload = rx + offset + CB_FRAME_HEADER_LEN;
        assert(offset + CB_FRAME_HEADER_LEN + payload_len <= (size_t)nread);

        /* Verify recursive RFC 8949 canonical CBOR key ordering on every frame */
        size_t cbor_pos = 0;
        bool canonical = cbor_skip_and_validate_canonical(payload, payload_len, &cbor_pos);
        assert(canonical);
        assert(cbor_pos == payload_len);

        if (msg_type == CB_MSG_SCENE_FONT) {
            font_msg_count++;
        } else if (msg_type == CB_MSG_SCENE_COMMIT) {
            commit_msg_count++;
        } else {
            assert(!"Unexpected message type on scene wire");
        }

        offset += CB_FRAME_HEADER_LEN + payload_len;
    }

    /* Font deduplication check: 1 font message across 2 frames using the same font */
    assert(font_msg_count == 1u);
    assert(commit_msg_count == 2u);

    /* Verify packed 10-byte glyph record layout directly */
    uint8_t packed[3 * CB_GLYPH_RECORD_LEN];
    cb_pack_glyph_records(packed, glyphs, 3u);
    assert(sizeof(packed) == 30u);
    for (size_t i = 0; i < 3u; i++) {
        const uint8_t *rec = packed + (i * 10u);
        uint16_t gid = (uint16_t)rec[0] | ((uint16_t)rec[1] << 8);
        uint32_t xbits = cb_read_le32(rec + 2);
        uint32_t ybits = cb_read_le32(rec + 6);
        float gx = 0.0f, gy = 0.0f;
        memcpy(&gx, &xbits, sizeof(gx));
        memcpy(&gy, &ybits, sizeof(gy));
        assert(gid == glyphs[i].glyph_id);
        assert(fabsf(gx - glyphs[i].x) < 1e-6f);
        assert(fabsf(gy - glyphs[i].y) < 1e-6f);
    }
    /* Ensure the packed 30-byte sequence appears verbatim in the wire stream */
    bool found_packed_glyphs_in_wire = false;
    for (size_t i = 0; i + sizeof(packed) <= (size_t)nread; i++) {
        if (memcmp(rx + i, packed, sizeof(packed)) == 0) {
            found_packed_glyphs_in_wire = true;
            break;
        }
    }
    assert(found_packed_glyphs_in_wire);

    /* Verify 0x9A (scene.scroll) non-blocking readback from caboose-display */
    cb_scene_scroll_event_t tx_scroll = {
        .surface_id = 42ULL,
        .node_id    = 102ULL,
        .sx         = 0.0,
        .sy         = 412.75
    };
    cb_cbor_buf scroll_buf;
    cb_cbor_buf_init(&scroll_buf, 128u);
    assert(cb_encode_scene_scroll(&scroll_buf, &tx_scroll));
    assert(scroll_buf.data[0] == CB_MSG_SCENE_SCROLL);

    /* Also check that our 0x9A frame is canonical CBOR */
    size_t s_pos = 0;
    assert(cbor_skip_and_validate_canonical(
        scroll_buf.data + CB_FRAME_HEADER_LEN,
        scroll_buf.len - CB_FRAME_HEADER_LEN,
        &s_pos
    ));

    ssize_t nsent = send(sv[1], scroll_buf.data, scroll_buf.len, 0);
    assert(nsent == (ssize_t)scroll_buf.len);
    cb_cbor_buf_free(&scroll_buf);

    cb_scene_scroll_event_t rx_scroll;
    memset(&rx_scroll, 0, sizeof(rx_scroll));
    bool got_scroll = caboose_scene_poll_scroll(&rx_scroll);
    assert(got_scroll);
    assert(rx_scroll.surface_id == 42ULL);
    assert(rx_scroll.node_id == 102ULL);
    assert(fabs(rx_scroll.sx - 0.0) < 1e-9);
    assert(fabs(rx_scroll.sy - 412.75) < 1e-9);

    /* Subsequent poll with empty socket must return false immediately without blocking */
    assert(!caboose_scene_poll_scroll(&rx_scroll));

    close(sv[1]);
    printf("[PASS] test_wire_socket_font_dedup_glyphs_and_scroll (0x25, 0x26, 0x9A)\n");
}

/* ========================================================================== *
 * Test 3: Invariant A — Headless Liveness (< 5 ms for 1,000 commits)         *
 * ========================================================================== */

static volatile sig_atomic_t g_sigpipe_caught = 0;

static void sigpipe_handler(int sig) {
    (void)sig;
    g_sigpipe_caught = 1;
}

static void test_headless_liveness(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = sigpipe_handler;
    sigaction(SIGPIPE, &sa, NULL);

    /* Case A: Reader closes socket mid-session -> 1,000 commits must not SIGPIPE or stall */
    int sv[2] = { -1, -1 };
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0);
    caboose_scene_attach_fd(sv[0]);
    close(sv[1]); /* Reader immediately hangs up! */

    uint64_t t0_us = cb_monotonic_us();
    for (int i = 0; i < 1000; i++) {
        caboose_scene_begin_frame(1ULL, 1ULL, false);
        (void)caboose_scene_push_rect(1ULL, 0.0, 0.0, 100.0, 40.0, 4.0, 0xFF0000FFu);
        (void)caboose_scene_commit_frame(0);
    }
    uint64_t elapsed_closed_us = cb_monotonic_us() - t0_us;
    assert(g_sigpipe_caught == 0);
    assert(caboose_scene_is_passthrough());
    assert(elapsed_closed_us < 5000ULL); /* < 5 ms */

    /* Case B: CABOOSE_SCENE_SOCKET points to a non-existent / dead socket path */
    setenv("CABOOSE_SCENE_SOCKET", "/tmp/caboose-nonexistent-dead-scene-socket.sock", 1);
    caboose_scene_reconnect();
    assert(caboose_scene_is_passthrough());

    uint64_t t1_us = cb_monotonic_us();
    for (int i = 0; i < 1000; i++) {
        (void)caboose_scene_commit_frame(0);
    }
    uint64_t elapsed_dead_us = cb_monotonic_us() - t1_us;
    assert(g_sigpipe_caught == 0);
    assert(elapsed_dead_us < 5000ULL); /* < 5 ms */

    printf(
        "[PASS] test_headless_liveness (1,000 commits: peer-closed=%llu us, dead-socket=%llu us < 5000 us)\n",
        (unsigned long long)elapsed_closed_us,
        (unsigned long long)elapsed_dead_us
    );
}

/* ========================================================================== *
 * Test 4: Implicit WSI / Mesa Zink Promotion Gate                            *
 * ========================================================================== */

static void test_wsi_zink_promotion_gate(void) {
    /* 1. Owner seat with CABOOSE_WSI_AUTO_PROMOTE=1 promotes 3D / Zink / Proton apps */
    assert(caboose_wsi_should_promote_process_ex("blender", "1", "owner", NULL, NULL) == true);
    assert(caboose_wsi_should_promote_process_ex("vkcube", "1", "owner", NULL, NULL) == true);
    assert(caboose_wsi_should_promote_process_ex("wine64-preloader", "1", "owner", NULL, NULL) == true);

    /* 2. Agent seat NEVER auto-promotes even if CABOOSE_WSI_AUTO_PROMOTE=1 */
    assert(caboose_wsi_should_promote_process_ex("blender", "1", "agent", NULL, NULL) == false);
    assert(caboose_wsi_should_promote_process_ex("vkcube", "0", "agent", NULL, NULL) == false);
    assert(caboose_wsi_should_promote_process_ex("vkcube", NULL, "owner", NULL, NULL) == false);

    /* 3. Denylisted 2D UI / desktop shell / Electron apps stay on Scene Graph / Atlas lanes */
    assert(caboose_wsi_should_promote_process_ex("waybar", "1", "owner", NULL, NULL) == false);
    assert(caboose_wsi_should_promote_process_ex("rofi", "1", "owner", NULL, NULL) == false);
    assert(caboose_wsi_should_promote_process_ex("nautilus", "1", "owner", NULL, NULL) == false);
    assert(caboose_wsi_should_promote_process_ex("claude-desktop", "1", "owner", NULL, NULL) == false);
    assert(caboose_wsi_should_promote_process_ex("code", "1", "owner", NULL, NULL) == false);

    /* 4. Environment integration check for Mesa Zink promotion helper */
    unsetenv("MESA_LOADER_DRIVER_OVERRIDE");
    unsetenv("GALLIUM_DRIVER");
    setenv("CABOOSE_WSI_AUTO_PROMOTE", "1", 1);
    setenv("CABOOSE_SEAT", "owner", 1);
    assert(caboose_wsi_apply_zink_env_if_promoted("godot4") == true);
    assert(strcmp(getenv("MESA_LOADER_DRIVER_OVERRIDE"), "zink") == 0);
    assert(strcmp(getenv("GALLIUM_DRIVER"), "zink") == 0);

    printf("[PASS] test_wsi_zink_promotion_gate (owner seat vs agent seat vs 2D denylist)\n");
}

int main(void) {
    test_xxh64_vectors();
    test_wire_socket_font_dedup_glyphs_and_scroll();
    test_headless_liveness();
    test_wsi_zink_promotion_gate();
    printf("All guest/scene wire & interceptor tests passed!\n");
    return 0;
}
