// SPDX-License-Identifier: MIT
//
// Images in phone-resident dma-bufs (docs/gpu-buffers.md): the modifier, and the nominal
// plane layout the GBM backend gives such a buffer (guest/gpu/gbm/include/
// caboose_drm_formats.h). The host image itself is an ordinary optimally tiled image.
#pragma once

#include <cstdint>
#include <vulkan/vulkan.h>

namespace caboose::dmabuf {

// CABOOSE_FORMAT_MOD_REMOTE.
inline constexpr uint64_t modifierRemote = uint64_t(0xcb) << 56 | 1;
inline constexpr uint64_t pitchAlign = 256;

struct PlaneFormat {
    uint32_t planes;
    uint32_t bytes[3];
    uint32_t xshift[3], yshift[3];
};

// The formats a remote buffer can have, as Vulkan formats.
inline bool planeFormat(VkFormat format, PlaneFormat* out) {
    switch (format) {
        case VK_FORMAT_B8G8R8A8_UNORM: case VK_FORMAT_B8G8R8A8_SRGB:
        case VK_FORMAT_R8G8B8A8_UNORM: case VK_FORMAT_R8G8B8A8_SRGB:
        case VK_FORMAT_A2R10G10B10_UNORM_PACK32: case VK_FORMAT_A2B10G10R10_UNORM_PACK32:
        case VK_FORMAT_R16G16_UNORM:
            *out = {1, {4}, {0}, {0}}; return true;
        case VK_FORMAT_R5G6B5_UNORM_PACK16: case VK_FORMAT_R8G8_UNORM: case VK_FORMAT_R16_UNORM:
            *out = {1, {2}, {0}, {0}}; return true;
        case VK_FORMAT_R8_UNORM:
            *out = {1, {1}, {0}, {0}}; return true;
        case VK_FORMAT_R16G16B16A16_SFLOAT:
            *out = {1, {8}, {0}, {0}}; return true;
        case VK_FORMAT_G8_B8R8_2PLANE_420_UNORM:
            *out = {2, {1, 2}, {0, 1}, {0, 1}}; return true;
        case VK_FORMAT_G10X6_B10X6R10X6_2PLANE_420_UNORM_3PACK16:
            *out = {2, {2, 4}, {0, 1}, {0, 1}}; return true;
        default:
            return false;
    }
}

// The nominal layout of `plane` for an image of this format and extent: rows aligned to
// 256 bytes, planes stacked. False for an unknown format or plane.
inline bool planeLayout(VkFormat format, uint32_t width, uint32_t height, uint32_t plane,
                        VkSubresourceLayout* out) {
    PlaneFormat f;
    if (!planeFormat(format, &f) || plane >= f.planes || !width || !height) return false;
    uint64_t offset = 0;
    for (uint32_t p = 0; p < f.planes; ++p) {
        const uint64_t w = (uint64_t(width) + (1u << f.xshift[p]) - 1) >> f.xshift[p];
        const uint64_t h = (uint64_t(height) + (1u << f.yshift[p]) - 1) >> f.yshift[p];
        const uint64_t pitch = (w * f.bytes[p] + pitchAlign - 1) / pitchAlign * pitchAlign;
        if (p == plane) {
            *out = VkSubresourceLayout{offset, pitch * h, pitch, 0, 0};
            return true;
        }
        offset += pitch * h;
    }
    return false;
}

}  // namespace caboose::dmabuf
