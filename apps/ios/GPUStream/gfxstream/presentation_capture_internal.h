// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <vulkan/vulkan.h>
#include <memory>
#include <vector>
namespace gfxstream::host::vk { struct VulkanDispatch; }
namespace caboose::gpuv2 {
// Images on the presenting device that receive a copy of each presented picture, each also
// a Metal texture the phone's scroll compositor reads (VK_EXT_metal_objects). The images are
// never presented, sampled by Vulkan, or shared with the guest.
struct PresentationCaptureRing {
    gfxstream::host::vk::VulkanDispatch* vk = nullptr;
    VkDevice device = VK_NULL_HANDLE;
    VkFormat format = VK_FORMAT_UNDEFINED;
    VkExtent3D extent{};
    std::vector<VkImage> images;
    std::vector<VkDeviceMemory> memory;
    // MTLTexture_id per image, owned by its VkImage.
    std::vector<void*> textures;
};
// Creates `count` device-local images of `format` and `extent` and exports their Metal
// textures. VK_ERROR_EXTENSION_NOT_PRESENT when the device cannot export Metal objects;
// the caller then presents without captures. On failure nothing is retained.
VkResult createCaptureRing(gfxstream::host::vk::VulkanDispatch* vk, VkPhysicalDevice physical,
    VkDevice device, VkFormat format, VkExtent3D extent, uint32_t count,
    std::unique_ptr<PresentationCaptureRing>* out);
// Caller guarantees no submitted copy into the ring is outstanding.
void destroyCaptureRing(PresentationCaptureRing& ring);
}
