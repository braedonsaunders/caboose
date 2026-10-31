// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "presentation_capture_internal.h"
#include <vulkan/vulkan_metal.h>
#include "metal_surface_internal.h"
#include "vk_decoder_global_state.h"
#include <cstdio>
#include <new>

namespace caboose::gpuv2 {
VkResult createCaptureRing(gfxstream::host::vk::VulkanDispatch* vk, VkInstance instance, VkPhysicalDevice physical,
    VkDevice device, VkFormat format, VkExtent3D extent, uint32_t count,
    std::unique_ptr<PresentationCaptureRing>* out) {
    if (!out) return VK_ERROR_INITIALIZATION_FAILED;
    out->reset();
    auto get = runtimeInstanceProcAddr();
    // The device dispatch carries device-level entry points only; the memory properties
    // query and the device proc lookup are instance-level.
    auto memoryProperties = get && instance ? reinterpret_cast<PFN_vkGetPhysicalDeviceMemoryProperties>(
        get(instance, "vkGetPhysicalDeviceMemoryProperties")) : nullptr;
    auto deviceProc = get && instance ? reinterpret_cast<PFN_vkGetDeviceProcAddr>(get(instance, "vkGetDeviceProcAddr")) : nullptr;
    const char* missing = !vk ? "device dispatch" : !get ? "vkGetInstanceProcAddr" : !instance ? "instance"
        : !physical ? "physical device" : !device ? "device" : (!count || count > 255) ? "slot count"
        : (!extent.width || !extent.height) ? "extent" : !vk->vkCreateImage ? "vkCreateImage"
        : !vk->vkDestroyImage ? "vkDestroyImage" : !vk->vkGetImageMemoryRequirements ? "vkGetImageMemoryRequirements"
        : !vk->vkAllocateMemory ? "vkAllocateMemory" : !vk->vkFreeMemory ? "vkFreeMemory"
        : !vk->vkBindImageMemory ? "vkBindImageMemory" : !memoryProperties ? "vkGetPhysicalDeviceMemoryProperties"
        : !deviceProc ? "vkGetDeviceProcAddr" : nullptr;
    if (missing) {
        fprintf(stderr, "caboose-scroll: capture ring: no %s\n", missing);
        return VK_ERROR_INITIALIZATION_FAILED;
    }
    auto exportObjects = reinterpret_cast<PFN_vkExportMetalObjectsEXT>(deviceProc(device, "vkExportMetalObjectsEXT"));
    // MoltenVK's own accessor serves a device created without VK_EXT_metal_objects.
    using GetTexture = void (*)(VkImage, void**);
    auto getTexture = reinterpret_cast<GetTexture>(deviceProc(device, "vkGetMTLTextureMVK"));
    if (!getTexture) getTexture = reinterpret_cast<GetTexture>(get(instance, "vkGetMTLTextureMVK"));
    if (!exportObjects && !getTexture) {
        fprintf(stderr, "caboose-scroll: capture ring: neither vkExportMetalObjectsEXT nor vkGetMTLTextureMVK on the presenting device\n");
        return VK_ERROR_EXTENSION_NOT_PRESENT;
    }
    std::unique_ptr<PresentationCaptureRing> ring(new (std::nothrow) PresentationCaptureRing());
    if (!ring) return VK_ERROR_OUT_OF_HOST_MEMORY;
    ring->vk = vk; ring->device = device; ring->format = format; ring->extent = extent;
    VkPhysicalDeviceMemoryProperties properties{};
    memoryProperties(physical, &properties);
    try {
        for (uint32_t i = 0; i < count; ++i) {
            VkExportMetalObjectCreateInfoEXT exportInfo{};
            exportInfo.sType = VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECT_CREATE_INFO_EXT;
            exportInfo.exportObjectType = VK_EXPORT_METAL_OBJECT_TYPE_METAL_TEXTURE_BIT_EXT;
            VkImageCreateInfo info{};
            info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
            info.pNext = exportObjects ? &exportInfo : nullptr;
            info.imageType = VK_IMAGE_TYPE_2D;
            info.format = format;
            info.extent = {extent.width, extent.height, 1};
            info.mipLevels = 1; info.arrayLayers = 1;
            info.samples = VK_SAMPLE_COUNT_1_BIT;
            info.tiling = VK_IMAGE_TILING_OPTIMAL;
            info.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
            info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
            info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
            VkImage image = VK_NULL_HANDLE;
            VkResult r = vk->vkCreateImage(device, &info, nullptr, &image);
            if (r != VK_SUCCESS) {
                fprintf(stderr, "caboose-scroll: capture ring: vkCreateImage format %d %ux%u failed (%d)\n",
                        static_cast<int>(format), extent.width, extent.height, static_cast<int>(r));
                destroyCaptureRing(*ring); return r;
            }
            ring->images.push_back(image);
            VkMemoryRequirements requirements{};
            vk->vkGetImageMemoryRequirements(device, image, &requirements);
            uint32_t type = UINT32_MAX;
            for (uint32_t t = 0; t < properties.memoryTypeCount; ++t) {
                if ((requirements.memoryTypeBits & (1u << t)) &&
                    (properties.memoryTypes[t].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) { type = t; break; }
            }
            if (type == UINT32_MAX) {
                fprintf(stderr, "caboose-scroll: capture ring: no device-local memory type in 0x%x\n", requirements.memoryTypeBits);
                destroyCaptureRing(*ring); return VK_ERROR_FEATURE_NOT_PRESENT;
            }
            VkMemoryAllocateInfo allocation{};
            allocation.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
            allocation.allocationSize = requirements.size;
            allocation.memoryTypeIndex = type;
            VkDeviceMemory memory = VK_NULL_HANDLE;
            r = vk->vkAllocateMemory(device, &allocation, nullptr, &memory);
            if (r != VK_SUCCESS) {
                fprintf(stderr, "caboose-scroll: capture ring: vkAllocateMemory failed (%d)\n", static_cast<int>(r));
                destroyCaptureRing(*ring); return r;
            }
            ring->memory.push_back(memory);
            r = vk->vkBindImageMemory(device, image, memory, 0);
            if (r != VK_SUCCESS) {
                fprintf(stderr, "caboose-scroll: capture ring: vkBindImageMemory failed (%d)\n", static_cast<int>(r));
                destroyCaptureRing(*ring); return r;
            }
            void* metal = nullptr;
            if (exportObjects) {
                VkExportMetalTextureInfoEXT texture{};
                texture.sType = VK_STRUCTURE_TYPE_EXPORT_METAL_TEXTURE_INFO_EXT;
                texture.image = image;
                texture.plane = VK_IMAGE_ASPECT_PLANE_0_BIT;
                VkExportMetalObjectsInfoEXT objects{};
                objects.sType = VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT;
                objects.pNext = &texture;
                exportObjects(device, &objects);
                metal = reinterpret_cast<void*>(texture.mtlTexture);
            }
            if (!metal && getTexture) getTexture(image, &metal);
            if (!metal) {
                fprintf(stderr, "caboose-scroll: capture ring: the presenting device exported no Metal texture\n");
                destroyCaptureRing(*ring); return VK_ERROR_EXTENSION_NOT_PRESENT;
            }
            ring->textures.push_back(metal);
        }
    } catch (const std::bad_alloc&) { destroyCaptureRing(*ring); return VK_ERROR_OUT_OF_HOST_MEMORY; }
    *out = std::move(ring);
    return VK_SUCCESS;
}

void destroyCaptureRing(PresentationCaptureRing& ring) {
    if (!ring.vk || !ring.device) return;
    for (auto image : ring.images) if (image) ring.vk->vkDestroyImage(ring.device, image, nullptr);
    for (auto memory : ring.memory) if (memory) ring.vk->vkFreeMemory(ring.device, memory, nullptr);
    ring.images.clear(); ring.memory.clear(); ring.textures.clear();
}
}
