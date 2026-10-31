/*
 * caboose_scene_cairo.c — LD_PRELOAD Cairo / GTK4 / Qt6 Scene Graph Interceptor
 * for the Caboose OS Decomposition ("Zero Server Video") architecture.
 *
 * Compiles into libcaboose_scene_cairo.so without requiring libcairo at link
 * time (resolves real Cairo symbols lazily via dlsym(RTLD_NEXT, ...)).
 * Also exposes the explicit C API used by GTK/Qt hooks and unit tests.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "scene_wire.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* ========================================================================== *
 * Minimal Cairo ABI Types (Zero build-time dependency on cairo.h)            *
 * ========================================================================== */

typedef struct _cairo         cairo_t;
typedef struct _cairo_surface cairo_surface_t;

typedef struct {
    unsigned long index;
    double        x;
    double        y;
} cairo_glyph_t;

typedef struct {
    int num_bytes;
    int num_glyphs;
} cairo_text_cluster_t;

typedef enum {
    CAIRO_TEXT_CLUSTER_FLAG_BACKWARD = 0x00000001
} cairo_text_cluster_flags_t;

/* ========================================================================== *
 * Session & Frame State                                                      *
 * ========================================================================== */

#define CB_SCENE_MAX_NODES_PER_FRAME 256u
#define CB_SCENE_MAX_FONTS_CACHE     64u

typedef struct cb_registered_font {
    uint64_t font_hash;
    uint32_t face_index;
    char     family[64];
    uint8_t *bytes;
    size_t   len;
} cb_registered_font_t;

typedef struct cb_frame_node_storage {
    cb_scene_node_t node;
    uint8_t        *owned_payload;
    uint64_t       *owned_children;
} cb_frame_node_storage_t;

typedef struct cb_scene_session {
    pthread_mutex_t         lock;
    bool                    initialized;
    cb_scene_client_t       client;

    /* Registered font blobs (sent lazily once per session) */
    cb_registered_font_t    fonts[CB_SCENE_MAX_FONTS_CACHE];
    size_t                  fonts_count;

    /* Active frame state */
    bool                    in_frame;
    uint64_t                surface_id;
    uint64_t                seq;
    uint64_t                root_id;
    bool                    has_reset;
    bool                    reset_val;
    cb_frame_node_storage_t nodes[CB_SCENE_MAX_NODES_PER_FRAME];
    size_t                  nodes_count;
    uint64_t                remove_ids[CB_SCENE_MAX_NODES_PER_FRAME];
    size_t                  remove_count;
} cb_scene_session_t;

static cb_scene_session_t g_session = {
    .lock = PTHREAD_MUTEX_INITIALIZER,
    .initialized = false
};

static void cb_session_clear_frame_locked(cb_scene_session_t *s) {
    for (size_t i = 0; i < s->nodes_count; i++) {
        free(s->nodes[i].owned_payload);
        s->nodes[i].owned_payload = NULL;
        free(s->nodes[i].owned_children);
        s->nodes[i].owned_children = NULL;
    }
    s->nodes_count = 0;
    s->remove_count = 0;
    s->in_frame = false;
}

static void cb_session_ensure_init_locked(cb_scene_session_t *s) {
    if (!s->initialized) {
        cb_scene_client_init_env(&s->client);
        s->initialized = true;
    }
}

/* ========================================================================== *
 * Explicit C API (Used by GTK/Cairo/Qt hooks and unit tests)                 *
 * ========================================================================== */

/**
 * Re-read `CABOOSE_SCENE_SOCKET` from environment and reconnect (or enter
 * headless passthrough mode if unset/unreachable).
 */
void caboose_scene_reconnect(void) {
    pthread_mutex_lock(&g_session.lock);
    cb_session_clear_frame_locked(&g_session);
    if (g_session.initialized) {
        cb_scene_client_close(&g_session.client);
    }
    cb_scene_client_init_env(&g_session.client);
    g_session.initialized = true;
    g_session.seq = 0;
    pthread_mutex_unlock(&g_session.lock);
}

/**
 * Attach an existing connected AF_UNIX socket descriptor (useful for tests
 * and pre-connected sandboxes).
 */
void caboose_scene_attach_fd(int fd) {
    pthread_mutex_lock(&g_session.lock);
    cb_session_clear_frame_locked(&g_session);
    if (g_session.initialized) {
        cb_scene_client_close(&g_session.client);
    }
    cb_scene_client_init_from_fd(&g_session.client, fd);
    g_session.initialized = true;
    g_session.seq = 0;
    pthread_mutex_unlock(&g_session.lock);
}

/**
 * Returns true if the scene client is currently in non-blocking local
 * passthrough mode (Invariant A: Headless Liveness).
 */
bool caboose_scene_is_passthrough(void) {
    pthread_mutex_lock(&g_session.lock);
    cb_session_ensure_init_locked(&g_session);
    bool pt = g_session.client.passthrough;
    pthread_mutex_unlock(&g_session.lock);
    return pt;
}

/**
 * Register a font face blob (`0x25 scene.font`). Computes its 64-bit xxHash64
 * (`seed = 0`) and caches it for session-scoped deduplication.
 */
uint64_t caboose_scene_register_font(
    const void *font_bytes,
    size_t font_len,
    uint32_t face_index,
    const char *family
) {
    if (!font_bytes || font_len == 0) {
        return 0;
    }
    uint64_t hash = cb_xxh64(font_bytes, font_len, 0ULL);

    pthread_mutex_lock(&g_session.lock);
    cb_session_ensure_init_locked(&g_session);

    /* Check if already registered in local cache */
    bool found = false;
    for (size_t i = 0; i < g_session.fonts_count; i++) {
        if (g_session.fonts[i].font_hash == hash &&
            g_session.fonts[i].face_index == face_index) {
            found = true;
            break;
        }
    }

    if (!found && g_session.fonts_count < CB_SCENE_MAX_FONTS_CACHE) {
        uint8_t *copy = (uint8_t *)malloc(font_len);
        if (copy) {
            memcpy(copy, font_bytes, font_len);
            cb_registered_font_t *entry = &g_session.fonts[g_session.fonts_count++];
            entry->font_hash = hash;
            entry->face_index = face_index;
            memset(entry->family, 0, sizeof(entry->family));
            if (family) {
                strncpy(entry->family, family, sizeof(entry->family) - 1);
            }
            entry->bytes = copy;
            entry->len = font_len;
        }
    }

    /* Immediately attempt non-blocking send if connected and not yet sent */
    (void)cb_scene_client_send_font_once(
        &g_session.client,
        hash,
        face_index,
        family,
        font_bytes,
        font_len
    );

    pthread_mutex_unlock(&g_session.lock);
    return hash;
}

/**
 * Begin recording a scene graph frame for `surface_id`.
 */
void caboose_scene_begin_frame(uint64_t surface_id, uint64_t root_id, bool reset) {
    pthread_mutex_lock(&g_session.lock);
    cb_session_ensure_init_locked(&g_session);
    cb_session_clear_frame_locked(&g_session);

    g_session.in_frame = true;
    g_session.surface_id = surface_id;
    g_session.root_id = root_id;
    g_session.has_reset = reset;
    g_session.reset_val = reset;
    pthread_mutex_unlock(&g_session.lock);
}

/**
 * Push a rounded rectangle (`op = "rect"`) node into the active frame.
 */
bool caboose_scene_push_rect(
    uint64_t node_id,
    double x,
    double y,
    double w,
    double h,
    double radius,
    uint32_t color_rgba
) {
    pthread_mutex_lock(&g_session.lock);
    if (!g_session.in_frame || g_session.nodes_count >= CB_SCENE_MAX_NODES_PER_FRAME) {
        pthread_mutex_unlock(&g_session.lock);
        return false;
    }

    cb_frame_node_storage_t *slot = &g_session.nodes[g_session.nodes_count++];
    memset(slot, 0, sizeof(*slot));
    slot->node.id = node_id;
    slot->node.kind = CB_NODE_RECT;
    slot->node.x = x;
    slot->node.y = y;
    slot->node.w = w;
    slot->node.h = h;
    slot->node.r = radius;
    slot->node.color_rgba = color_rgba;

    pthread_mutex_unlock(&g_session.lock);
    return true;
}

/**
 * Push a rounded clip container (`op = "rclip"`) node into the active frame.
 */
bool caboose_scene_push_rclip(
    uint64_t node_id,
    double x,
    double y,
    double w,
    double h,
    double radius,
    const uint64_t *children,
    size_t children_count
) {
    pthread_mutex_lock(&g_session.lock);
    if (!g_session.in_frame || g_session.nodes_count >= CB_SCENE_MAX_NODES_PER_FRAME) {
        pthread_mutex_unlock(&g_session.lock);
        return false;
    }

    cb_frame_node_storage_t *slot = &g_session.nodes[g_session.nodes_count++];
    memset(slot, 0, sizeof(*slot));
    slot->node.id = node_id;
    slot->node.kind = CB_NODE_RCLIP;
    slot->node.x = x;
    slot->node.y = y;
    slot->node.w = w;
    slot->node.h = h;
    slot->node.r = radius;

    if (children && children_count > 0) {
        slot->owned_children = (uint64_t *)malloc(children_count * sizeof(uint64_t));
        if (slot->owned_children) {
            memcpy(slot->owned_children, children, children_count * sizeof(uint64_t));
            slot->node.children = slot->owned_children;
            slot->node.children_count = children_count;
        }
    }

    pthread_mutex_unlock(&g_session.lock);
    return true;
}

/**
 * Push a scroll container (`op = "scroll"`) node into the active frame.
 */
bool caboose_scene_push_scroll(
    uint64_t node_id,
    double x,
    double y,
    double viewport_w,
    double viewport_h,
    double content_w,
    double content_h,
    double scroll_x,
    double scroll_y,
    const uint64_t *children,
    size_t children_count
) {
    pthread_mutex_lock(&g_session.lock);
    if (!g_session.in_frame || g_session.nodes_count >= CB_SCENE_MAX_NODES_PER_FRAME) {
        pthread_mutex_unlock(&g_session.lock);
        return false;
    }

    cb_frame_node_storage_t *slot = &g_session.nodes[g_session.nodes_count++];
    memset(slot, 0, sizeof(*slot));
    slot->node.id = node_id;
    slot->node.kind = CB_NODE_SCROLL;
    slot->node.x = x;
    slot->node.y = y;
    slot->node.w = viewport_w;
    slot->node.h = viewport_h;
    slot->node.content_w = content_w;
    slot->node.content_h = content_h;
    slot->node.scroll_x = scroll_x;
    slot->node.scroll_y = scroll_y;

    if (children && children_count > 0) {
        slot->owned_children = (uint64_t *)malloc(children_count * sizeof(uint64_t));
        if (slot->owned_children) {
            memcpy(slot->owned_children, children, children_count * sizeof(uint64_t));
            slot->node.children = slot->owned_children;
            slot->node.children_count = children_count;
        }
    }

    pthread_mutex_unlock(&g_session.lock);
    return true;
}

/**
 * Push a positioned glyph run (`op = "glyphs"`) node into the active frame.
 * Packs each glyph into a tight 10-byte `(uint16_t glyph_id, float x, float y)`
 * little-endian record. Also ensures the referenced font (`0x25`) has been sent
 * once on the current session.
 */
bool caboose_scene_push_glyphs(
    uint64_t node_id,
    uint64_t font_hash,
    uint32_t face_index,
    double font_size,
    double origin_x,
    double origin_y,
    uint32_t color_rgba,
    const cb_glyph_pos_t *glyphs,
    size_t glyph_count
) {
    if (!glyphs && glyph_count > 0) {
        return false;
    }

    pthread_mutex_lock(&g_session.lock);
    if (!g_session.in_frame || g_session.nodes_count >= CB_SCENE_MAX_NODES_PER_FRAME) {
        pthread_mutex_unlock(&g_session.lock);
        return false;
    }

    /* Ensure font has been transmitted once on this session */
    if (!g_session.client.passthrough &&
        !cb_scene_client_has_font(&g_session.client, font_hash, face_index)) {
        for (size_t i = 0; i < g_session.fonts_count; i++) {
            if (g_session.fonts[i].font_hash == font_hash &&
                g_session.fonts[i].face_index == face_index) {
                (void)cb_scene_client_send_font_once(
                    &g_session.client,
                    font_hash,
                    face_index,
                    g_session.fonts[i].family,
                    g_session.fonts[i].bytes,
                    g_session.fonts[i].len
                );
                break;
            }
        }
    }

    size_t packed_len = glyph_count * CB_GLYPH_RECORD_LEN;
    uint8_t *packed = NULL;
    if (packed_len > 0) {
        packed = (uint8_t *)malloc(packed_len);
        if (!packed) {
            pthread_mutex_unlock(&g_session.lock);
            return false;
        }
        cb_pack_glyph_records(packed, glyphs, glyph_count);
    }

    cb_frame_node_storage_t *slot = &g_session.nodes[g_session.nodes_count++];
    memset(slot, 0, sizeof(*slot));
    slot->owned_payload = packed;
    slot->node.id = node_id;
    slot->node.kind = CB_NODE_GLYPHS;
    slot->node.x = origin_x;
    slot->node.y = origin_y;
    slot->node.font_hash = font_hash;
    slot->node.face_index = face_index;
    slot->node.font_size = font_size;
    slot->node.color_rgba = color_rgba;
    slot->node.packed_data = packed;
    slot->node.packed_len = packed_len;

    pthread_mutex_unlock(&g_session.lock);
    return true;
}

/**
 * Push a vector path (`op = "path"`) node into the active frame.
 */
bool caboose_scene_push_path(
    uint64_t node_id,
    uint32_t color_rgba,
    const uint8_t *path_bytes,
    size_t path_len
) {
    if (!path_bytes && path_len > 0) {
        return false;
    }

    pthread_mutex_lock(&g_session.lock);
    if (!g_session.in_frame || g_session.nodes_count >= CB_SCENE_MAX_NODES_PER_FRAME) {
        pthread_mutex_unlock(&g_session.lock);
        return false;
    }

    uint8_t *copy = NULL;
    if (path_len > 0) {
        copy = (uint8_t *)malloc(path_len);
        if (!copy) {
            pthread_mutex_unlock(&g_session.lock);
            return false;
        }
        memcpy(copy, path_bytes, path_len);
    }

    cb_frame_node_storage_t *slot = &g_session.nodes[g_session.nodes_count++];
    memset(slot, 0, sizeof(*slot));
    slot->owned_payload = copy;
    slot->node.id = node_id;
    slot->node.kind = CB_NODE_PATH;
    slot->node.color_rgba = color_rgba;
    slot->node.packed_data = copy;
    slot->node.packed_len = path_len;

    pthread_mutex_unlock(&g_session.lock);
    return true;
}

/**
 * Commit the active frame (`0x26 scene.commit`) over the non-blocking socket.
 *
 * Invariant A (Headless Liveness):
 *   If the client is in passthrough mode or the socket write fails with EAGAIN
 *   or EPIPE, this function immediately clears the frame and returns false
 *   without ever blocking or raising SIGPIPE.
 */
bool caboose_scene_commit_frame(uint64_t pts_us) {
    pthread_mutex_lock(&g_session.lock);
    cb_session_ensure_init_locked(&g_session);

    if (!g_session.in_frame) {
        /* Allow zero-setup commit calls in headless liveness benchmarks */
        g_session.surface_id = 1;
        g_session.root_id = 1;
    }

    if (g_session.client.passthrough || g_session.client.fd < 0) {
        g_session.client.drops++;
        cb_session_clear_frame_locked(&g_session);
        pthread_mutex_unlock(&g_session.lock);
        return false;
    }

    if (pts_us == 0) {
        pts_us = cb_monotonic_us();
    }

    uint64_t seq = ++g_session.seq;
    cb_scene_node_t flat_nodes[CB_SCENE_MAX_NODES_PER_FRAME];
    for (size_t i = 0; i < g_session.nodes_count; i++) {
        flat_nodes[i] = g_session.nodes[i].node;
    }

    cb_cbor_buf buf;
    cb_cbor_buf_init(&buf, 512u);
    bool encoded = cb_encode_scene_commit(
        &buf,
        g_session.surface_id,
        seq,
        pts_us,
        g_session.root_id,
        g_session.has_reset,
        g_session.reset_val,
        flat_nodes,
        g_session.nodes_count,
        g_session.remove_ids,
        g_session.remove_count
    );

    bool sent = false;
    if (encoded) {
        sent = cb_scene_client_send_raw(&g_session.client, buf.data, buf.len);
        if (sent) {
            g_session.client.frames_committed++;
        }
    }

    cb_cbor_buf_free(&buf);
    cb_session_clear_frame_locked(&g_session);
    pthread_mutex_unlock(&g_session.lock);
    return sent;
}

/**
 * Poll for an asynchronous `0x9A` (`scene.scroll`) event from the display server.
 */
bool caboose_scene_poll_scroll(cb_scene_scroll_event_t *out_event) {
    pthread_mutex_lock(&g_session.lock);
    cb_session_ensure_init_locked(&g_session);
    bool got = cb_scene_client_poll_scroll(&g_session.client, out_event);
    pthread_mutex_unlock(&g_session.lock);
    return got;
}

/* ========================================================================== *
 * LD_PRELOAD Cairo Interception Hooks (via RTLD_NEXT with safe fallback)     *
 * ========================================================================== */

typedef void (*pfn_cairo_fill_t)(cairo_t *cr);
typedef void (*pfn_cairo_stroke_t)(cairo_t *cr);
typedef void (*pfn_cairo_paint_t)(cairo_t *cr);
typedef void (*pfn_cairo_show_glyphs_t)(cairo_t *cr, const cairo_glyph_t *glyphs, int num_glyphs);
typedef void (*pfn_cairo_show_text_glyphs_t)(
    cairo_t *cr,
    const char *utf8,
    int utf8_len,
    const cairo_glyph_t *glyphs,
    int num_glyphs,
    const cairo_text_cluster_t *clusters,
    int num_clusters,
    cairo_text_cluster_flags_t cluster_flags
);
typedef void (*pfn_cairo_surface_flush_t)(cairo_surface_t *surface);

void cairo_fill(cairo_t *cr) {
    static pfn_cairo_fill_t real_fn = NULL;
    if (!real_fn) {
        real_fn = (pfn_cairo_fill_t)dlsym(RTLD_NEXT, "cairo_fill");
    }
    if (real_fn) {
        real_fn(cr);
    }
}

void cairo_stroke(cairo_t *cr) {
    static pfn_cairo_stroke_t real_fn = NULL;
    if (!real_fn) {
        real_fn = (pfn_cairo_stroke_t)dlsym(RTLD_NEXT, "cairo_stroke");
    }
    if (real_fn) {
        real_fn(cr);
    }
}

void cairo_paint(cairo_t *cr) {
    static pfn_cairo_paint_t real_fn = NULL;
    if (!real_fn) {
        real_fn = (pfn_cairo_paint_t)dlsym(RTLD_NEXT, "cairo_paint");
    }
    if (real_fn) {
        real_fn(cr);
    }
}

void cairo_show_glyphs(cairo_t *cr, const cairo_glyph_t *glyphs, int num_glyphs) {
    static pfn_cairo_show_glyphs_t real_fn = NULL;
    if (!real_fn) {
        real_fn = (pfn_cairo_show_glyphs_t)dlsym(RTLD_NEXT, "cairo_show_glyphs");
    }
    if (glyphs && num_glyphs > 0 && !caboose_scene_is_passthrough()) {
        size_t count = (size_t)num_glyphs;
        cb_glyph_pos_t stack_glyphs[128];
        cb_glyph_pos_t *conv = (count <= 128)
            ? stack_glyphs
            : (cb_glyph_pos_t *)malloc(count * sizeof(cb_glyph_pos_t));
        if (conv) {
            for (size_t i = 0; i < count; i++) {
                conv[i].glyph_id = (uint16_t)(glyphs[i].index & 0xFFFFu);
                conv[i].x = (float)glyphs[i].x;
                conv[i].y = (float)glyphs[i].y;
            }
            (void)caboose_scene_push_glyphs(
                (uint64_t)(uintptr_t)cr,
                0ULL,
                0u,
                14.0,
                0.0,
                0.0,
                0xFFFFFFFFu,
                conv,
                count
            );
            if (conv != stack_glyphs) {
                free(conv);
            }
        }
    }
    if (real_fn) {
        real_fn(cr, glyphs, num_glyphs);
    }
}

void cairo_show_text_glyphs(
    cairo_t *cr,
    const char *utf8,
    int utf8_len,
    const cairo_glyph_t *glyphs,
    int num_glyphs,
    const cairo_text_cluster_t *clusters,
    int num_clusters,
    cairo_text_cluster_flags_t cluster_flags
) {
    static pfn_cairo_show_text_glyphs_t real_fn = NULL;
    if (!real_fn) {
        real_fn = (pfn_cairo_show_text_glyphs_t)dlsym(RTLD_NEXT, "cairo_show_text_glyphs");
    }
    if (glyphs && num_glyphs > 0 && !caboose_scene_is_passthrough()) {
        size_t count = (size_t)num_glyphs;
        cb_glyph_pos_t stack_glyphs[128];
        cb_glyph_pos_t *conv = (count <= 128)
            ? stack_glyphs
            : (cb_glyph_pos_t *)malloc(count * sizeof(cb_glyph_pos_t));
        if (conv) {
            for (size_t i = 0; i < count; i++) {
                conv[i].glyph_id = (uint16_t)(glyphs[i].index & 0xFFFFu);
                conv[i].x = (float)glyphs[i].x;
                conv[i].y = (float)glyphs[i].y;
            }
            (void)caboose_scene_push_glyphs(
                (uint64_t)(uintptr_t)cr,
                0ULL,
                0u,
                14.0,
                0.0,
                0.0,
                0xFFFFFFFFu,
                conv,
                count
            );
            if (conv != stack_glyphs) {
                free(conv);
            }
        }
    }
    if (real_fn) {
        real_fn(cr, utf8, utf8_len, glyphs, num_glyphs, clusters, num_clusters, cluster_flags);
    }
}

void cairo_surface_flush(cairo_surface_t *surface) {
    static pfn_cairo_surface_flush_t real_fn = NULL;
    if (!real_fn) {
        real_fn = (pfn_cairo_surface_flush_t)dlsym(RTLD_NEXT, "cairo_surface_flush");
    }
    if (g_session.in_frame) {
        (void)caboose_scene_commit_frame(0);
    }
    if (real_fn) {
        real_fn(surface);
    }
}
