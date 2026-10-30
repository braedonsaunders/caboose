// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <vulkan/vulkan.h>
#include <vector>
namespace gfxstream::host::vk { struct CaboosePresentationPhysicalDevice; }
namespace caboose::gpuv2 {
struct PresentationSurfaceFormat {
    VkSurfaceFormatKHR surface;
    VkFormatProperties properties;
    bool propertiesQueried = false;
};
struct PresentationQueueFamily {
    VkQueueFamilyProperties properties;
    VkBool32 presentSupported;
};
struct PresentationCandidateFormat {
    VkFormat format;
    VkFormatProperties properties;
};
struct PresentationSurfaceCapabilities {
    VkSurfaceCapabilitiesKHR capabilities{};
    std::vector<PresentationSurfaceFormat> formats;
    // Real format properties for the four initially supported candidate formats,
    // including when a surface reports VK_FORMAT_UNDEFINED.
    std::vector<PresentationCandidateFormat> candidateFormats;
    std::vector<VkPresentModeKHR> modes;
    std::vector<PresentationQueueFamily> queueFamilies;
};
struct PresentationQueryStatus {
    bool hasDriverResult = false;
    VkResult driverResult = VK_SUCCESS;
};
// Caller retains a context-validated physical-device/instance lease and the
// matching live surface throughout this call. Output is committed only after
// all actual provider queries succeed, without truncating returned lists.
VkResult queryPresentationSurface(gfxstream::host::vk::CaboosePresentationPhysicalDevice& physical,
    VkSurfaceKHR surface, PresentationSurfaceCapabilities* out, PresentationQueryStatus* status);
}
