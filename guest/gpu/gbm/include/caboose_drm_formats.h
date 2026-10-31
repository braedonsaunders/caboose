// SPDX-License-Identifier: MIT
//
// The buffer formats and layouts shared by the Caboose GBM backend, the phone-GPU
// Vulkan driver and caboose-display (docs/gpu-buffers.md).
#ifndef CABOOSE_DRM_FORMATS_H
#define CABOOSE_DRM_FORMATS_H

#include <stdint.h>
#include <drm_fourcc.h>

// A buffer whose pixels live in phone GPU memory. Its dma-buf has the nominal linear
// size but no meaningful bytes: only a phone-GPU consumer (the Caboose Vulkan driver,
// or caboose-display presenting through the GPU stream) can use it. Vendor 0x7e is not
// allocated in drm_fourcc.h.
#define CABOOSE_FORMAT_MOD_REMOTE ((uint64_t)0x7e << 56 | 1)

// Row pitch alignment for both layouts: satisfies Metal's linear texture alignment.
#define CABOOSE_PITCH_ALIGN 256u

struct caboose_format {
    uint32_t fourcc;
    uint8_t planes;
    uint8_t bytes[3];    // bytes per pixel, per plane
    uint8_t xshift[3];   // horizontal subsampling, as a shift, per plane
    uint8_t yshift[3];   // vertical subsampling, as a shift, per plane
};

static const struct caboose_format caboose_formats[] = {
    {DRM_FORMAT_XRGB8888, 1, {4}, {0}, {0}},
    {DRM_FORMAT_ARGB8888, 1, {4}, {0}, {0}},
    {DRM_FORMAT_XBGR8888, 1, {4}, {0}, {0}},
    {DRM_FORMAT_ABGR8888, 1, {4}, {0}, {0}},
    {DRM_FORMAT_RGB565, 1, {2}, {0}, {0}},
    {DRM_FORMAT_XRGB2101010, 1, {4}, {0}, {0}},
    {DRM_FORMAT_ARGB2101010, 1, {4}, {0}, {0}},
    {DRM_FORMAT_XBGR2101010, 1, {4}, {0}, {0}},
    {DRM_FORMAT_ABGR2101010, 1, {4}, {0}, {0}},
    {DRM_FORMAT_XBGR16161616F, 1, {8}, {0}, {0}},
    {DRM_FORMAT_ABGR16161616F, 1, {8}, {0}, {0}},
    {DRM_FORMAT_R8, 1, {1}, {0}, {0}},
    {DRM_FORMAT_GR88, 1, {2}, {0}, {0}},
    {DRM_FORMAT_R16, 1, {2}, {0}, {0}},
    {DRM_FORMAT_GR1616, 1, {4}, {0}, {0}},
    {DRM_FORMAT_NV12, 2, {1, 2}, {0, 1}, {0, 1}},
    {DRM_FORMAT_P010, 2, {2, 4}, {0, 1}, {0, 1}},
};

static inline const struct caboose_format *caboose_format_find(uint32_t fourcc) {
    for (unsigned i = 0; i < sizeof(caboose_formats) / sizeof(caboose_formats[0]); ++i)
        if (caboose_formats[i].fourcc == fourcc) return &caboose_formats[i];
    return 0;
}

// The layout both modifiers share: tightly stacked planes, each row aligned to
// CABOOSE_PITCH_ALIGN. Returns the total size, or 0 when it overflows 32-bit pitches
// or a 64-bit size.
static inline uint64_t caboose_format_layout(const struct caboose_format *format, uint32_t width,
                                             uint32_t height, uint32_t strides[3], uint32_t offsets[3]) {
    uint64_t total = 0;
    if (!width || !height) return 0;
    for (unsigned p = 0; p < format->planes; ++p) {
        const uint64_t w = ((uint64_t)width + (1u << format->xshift[p]) - 1) >> format->xshift[p];
        const uint64_t h = ((uint64_t)height + (1u << format->yshift[p]) - 1) >> format->yshift[p];
        const uint64_t pitch = (w * format->bytes[p] + CABOOSE_PITCH_ALIGN - 1) / CABOOSE_PITCH_ALIGN * CABOOSE_PITCH_ALIGN;
        if (pitch > UINT32_MAX || total > UINT32_MAX) return 0;
        strides[p] = (uint32_t)pitch;
        offsets[p] = (uint32_t)total;
        total += pitch * h;
    }
    return total;
}

#endif
