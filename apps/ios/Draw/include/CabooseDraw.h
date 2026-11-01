/*
 * CabooseDraw: draws Caboose draw lists (docs/draw.md) with Skia on Metal.
 *
 * A renderer keeps every stream's surfaces as Metal textures at `scale` device pixels per
 * surface pixel, and draws each op as it arrives. The textures it hands out are its own,
 * never reused while the caller holds them; they are drawn on the queue the renderer was made
 * with, so work the caller encodes on that queue after `caboose_draw_texture` sees them drawn.
 * Not thread-safe: one renderer is used from one thread at a time.
 */
#ifndef CABOOSE_DRAW_H
#define CABOOSE_DRAW_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CabooseDrawRenderer CabooseDrawRenderer;

/* `device` and `queue` are an id<MTLDevice> and an id<MTLCommandQueue>, retained by the
 * renderer. NULL when Skia cannot use them. */
CabooseDrawRenderer *caboose_draw_create(void *device, void *queue);
void caboose_draw_destroy(CabooseDrawRenderer *renderer);

/* Device pixels per surface pixel for surfaces declared from now on (default 1). */
void caboose_draw_set_scale(CabooseDrawRenderer *renderer, float scale);

/* Appends a `draw.ops` payload to `stream` and draws every op it completes. Returns 0, or -1
 * when the stream is malformed: the stream is then dropped, as after `caboose_draw_end`. */
int caboose_draw_feed(CabooseDrawRenderer *renderer, uint32_t stream, const uint8_t *bytes, size_t length);

/* The stream ended: its surfaces, images and glyphs go. */
void caboose_draw_end(CabooseDrawRenderer *renderer, uint32_t stream);

/* Submits what was drawn and returns surface `surface` of `stream` as an id<MTLTexture>
 * (BGRA8, premultiplied; +0, valid until the surface is freed or the stream ends), with its
 * size in pixels and the scale it was made at. NULL for a surface the stream does not have. */
void *caboose_draw_texture(CabooseDrawRenderer *renderer, uint32_t stream, uint32_t surface, uint32_t *width,
                           uint32_t *height, float *scale);

/* Reads surface `surface` of `stream` back as premultiplied RGBA8 into `rgba` (`capacity`
 * bytes), waiting for the GPU. Returns the bytes written, or 0. For checks, not for display. */
size_t caboose_draw_read(CabooseDrawRenderer *renderer, uint32_t stream, uint32_t surface, uint8_t *rgba,
                         size_t capacity, uint32_t *width, uint32_t *height);

/* Counters since the renderer was made: ops drawn, ops skipped (unknown, or naming what the
 * stream does not have), streams dropped as malformed. */
void caboose_draw_stats(CabooseDrawRenderer *renderer, uint64_t *drawn, uint64_t *skipped, uint64_t *dropped);

#ifdef __cplusplus
}
#endif

#endif
