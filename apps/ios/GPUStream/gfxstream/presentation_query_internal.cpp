// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "presentation_query_internal.h"
#include "metal_surface_internal.h"
#include "vk_decoder_global_state.h"
#include <new>
#include <utility>

namespace caboose::gpuv2 {
VkResult queryPresentationSurface(gfxstream::host::vk::CaboosePresentationPhysicalDevice& physical,
    VkSurfaceKHR surface, PresentationSurfaceCapabilities* out, PresentationQueryStatus* driverStatus) {
    if (driverStatus) *driverStatus = {};
    auto providerFailure = [driverStatus](VkResult r) {
        if (driverStatus) { driverStatus->hasDriverResult = true; driverStatus->driverResult = r; }
        return r;
    };
    auto get = runtimeInstanceProcAddr();
    if (!out || !get || !physical.instance || !physical.physicalDevice || !surface)
        return VK_ERROR_INITIALIZATION_FAILED;
    auto capabilities = reinterpret_cast<PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR>(
        get(physical.instance, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR"));
    auto formats = reinterpret_cast<PFN_vkGetPhysicalDeviceSurfaceFormatsKHR>(
        get(physical.instance, "vkGetPhysicalDeviceSurfaceFormatsKHR"));
    auto modes = reinterpret_cast<PFN_vkGetPhysicalDeviceSurfacePresentModesKHR>(
        get(physical.instance, "vkGetPhysicalDeviceSurfacePresentModesKHR"));
    auto queueProperties = reinterpret_cast<PFN_vkGetPhysicalDeviceQueueFamilyProperties>(
        get(physical.instance, "vkGetPhysicalDeviceQueueFamilyProperties"));
    auto queueSupport = reinterpret_cast<PFN_vkGetPhysicalDeviceSurfaceSupportKHR>(
        get(physical.instance, "vkGetPhysicalDeviceSurfaceSupportKHR"));
    auto formatProperties = reinterpret_cast<PFN_vkGetPhysicalDeviceFormatProperties>(
        get(physical.instance, "vkGetPhysicalDeviceFormatProperties"));
    if (!capabilities || !formats || !modes || !queueProperties || !queueSupport || !formatProperties)
        return VK_ERROR_EXTENSION_NOT_PRESENT;
    try {
        PresentationSurfaceCapabilities result{};
        VkResult status = capabilities(physical.physicalDevice, surface, &result.capabilities);
        if (status != VK_SUCCESS) return providerFailure(status);
        uint32_t count = 0;
        status = formats(physical.physicalDevice, surface, &count, nullptr);
        if (status != VK_SUCCESS) return providerFailure(status);
        if (!count || count > 4096) return VK_ERROR_FEATURE_NOT_PRESENT;
        std::vector<VkSurfaceFormatKHR> rawFormats(count);
        status = formats(physical.physicalDevice, surface, &count, rawFormats.data());
        if (status != VK_SUCCESS) return providerFailure(status);
        rawFormats.resize(count);
        result.formats.reserve(count);
        for (auto format : rawFormats) {
            PresentationSurfaceFormat entry{};
            entry.surface = format;
            // Undefined surface format means the provider permits any format;
            // preserve that fact without inventing format properties.
            if (format.format != VK_FORMAT_UNDEFINED) {
                formatProperties(physical.physicalDevice, format.format, &entry.properties);
                entry.propertiesQueried = true;
            }
            result.formats.push_back(entry);
        }
        const VkFormat candidates[] = {VK_FORMAT_R8G8B8A8_UNORM, VK_FORMAT_R8G8B8A8_SRGB,
            VK_FORMAT_B8G8R8A8_UNORM, VK_FORMAT_B8G8R8A8_SRGB};
        result.candidateFormats.reserve(4);
        for (VkFormat format : candidates) {
            PresentationCandidateFormat entry{};
            entry.format = format;
            formatProperties(physical.physicalDevice, format, &entry.properties);
            result.candidateFormats.push_back(entry);
        }
        count = 0;
        status = modes(physical.physicalDevice, surface, &count, nullptr);
        if (status != VK_SUCCESS) return providerFailure(status);
        if (!count || count > 4096) return VK_ERROR_FEATURE_NOT_PRESENT;
        result.modes.resize(count);
        status = modes(physical.physicalDevice, surface, &count, result.modes.data());
        if (status != VK_SUCCESS) return providerFailure(status);
        result.modes.resize(count);
        count = 0;
        queueProperties(physical.physicalDevice, &count, nullptr);
        if (!count || count > 4096) return VK_ERROR_FEATURE_NOT_PRESENT;
        std::vector<VkQueueFamilyProperties> rawQueues(count);
        queueProperties(physical.physicalDevice, &count, rawQueues.data());
        rawQueues.resize(count);
        result.queueFamilies.reserve(count);
        for (uint32_t i = 0; i < count; ++i) {
            PresentationQueueFamily entry{};
            entry.properties = rawQueues[i];
            status = queueSupport(physical.physicalDevice, i, surface, &entry.presentSupported);
            if (status != VK_SUCCESS) return providerFailure(status);
            result.queueFamilies.push_back(entry);
        }
        *out = std::move(result);
        if (driverStatus) { driverStatus->hasDriverResult = true; driverStatus->driverResult = VK_SUCCESS; }
        return VK_SUCCESS;
    } catch (const std::bad_alloc&) { return VK_ERROR_OUT_OF_HOST_MEMORY; }
}
}
