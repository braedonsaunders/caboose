// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "presentation_virtual_swapchain_internal.h"
#include "metal_surface_internal.h"
#include "vk_decoder_global_state.h"
#include <algorithm>
#include <new>

namespace caboose::gpuv2 {
VkResult createVirtualSwapchain(gfxstream::host::vk::CabooseSwapchainDevice& device,
    VkSurfaceKHR surface, const caboose_gpu_swapchain_create_info& info,
    VkSwapchainKHR* out, std::vector<VkImage>* images, PresentationProviderResult* provider,
    bool requireExactExtent) {
    if (provider) *provider = {};
    if (!out || !images) return VK_ERROR_INITIALIZATION_FAILED;
    *out = VK_NULL_HANDLE; images->clear();
    auto* vk = device.vk;
    auto get = runtimeInstanceProcAddr();
    if (!get || !vk || !device.instance || !device.physicalDevice || !device.device || !surface ||
        !vk->vkCreateSwapchainKHR || !vk->vkDestroySwapchainKHR || !vk->vkGetSwapchainImagesKHR)
        return VK_ERROR_INITIALIZATION_FAILED;
    if (info.create_flags || info.has_unsupported_extensions || info.old_swapchain_id ||
        !info.min_image_count || info.min_image_count > 256 || !info.width || !info.height ||
        info.image_array_layers != 1 || !info.image_usage || info.clipped > 1 ||
        !info.composite_alpha || (info.composite_alpha & (info.composite_alpha - 1)) ||
        info.sharing_mode != VK_SHARING_MODE_EXCLUSIVE || info.queue_family_count ||
        info.present_mode != VK_PRESENT_MODE_FIFO_KHR ||
        info.pre_transform != VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR)
        return VK_ERROR_FEATURE_NOT_PRESENT;
    auto capsFn = reinterpret_cast<PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR>(
        get(device.instance, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR"));
    auto formatsFn = reinterpret_cast<PFN_vkGetPhysicalDeviceSurfaceFormatsKHR>(
        get(device.instance, "vkGetPhysicalDeviceSurfaceFormatsKHR"));
    auto modesFn = reinterpret_cast<PFN_vkGetPhysicalDeviceSurfacePresentModesKHR>(
        get(device.instance, "vkGetPhysicalDeviceSurfacePresentModesKHR"));
    auto formatFn = reinterpret_cast<PFN_vkGetPhysicalDeviceFormatProperties>(
        get(device.instance, "vkGetPhysicalDeviceFormatProperties"));
    auto queueFamiliesFn = reinterpret_cast<PFN_vkGetPhysicalDeviceQueueFamilyProperties>(
        get(device.instance, "vkGetPhysicalDeviceQueueFamilyProperties"));
    auto supportFn = reinterpret_cast<PFN_vkGetPhysicalDeviceSurfaceSupportKHR>(
        get(device.instance, "vkGetPhysicalDeviceSurfaceSupportKHR"));
    if (!capsFn || !formatsFn || !modesFn || !formatFn || !queueFamiliesFn || !supportFn)
        return VK_ERROR_EXTENSION_NOT_PRESENT;
    auto failed = [provider](VkResult r) { return provider ? provider->record(r) : r; };
    try {
        uint32_t queueCount = 0;
        queueFamiliesFn(device.physicalDevice, &queueCount, nullptr);
        if (!queueCount || queueCount > 4096) return VK_ERROR_FEATURE_NOT_PRESENT;
        bool supported = false;
        for (uint32_t i = 0; i < queueCount; ++i) {
            VkBool32 present = VK_FALSE;
            VkResult r = supportFn(device.physicalDevice, i, surface, &present);
            if (r != VK_SUCCESS) return failed(r);
            supported = supported || present == VK_TRUE;
        }
        if (!supported) return VK_ERROR_FEATURE_NOT_PRESENT;
        VkSurfaceCapabilitiesKHR caps{};
        VkResult r = capsFn(device.physicalDevice, surface, &caps);
        if (r != VK_SUCCESS) return failed(r);
        const VkImageUsageFlags nativeUsage = info.image_usage | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
        if (info.min_image_count < caps.minImageCount ||
            (caps.maxImageCount && info.min_image_count > caps.maxImageCount) ||
            info.width < caps.minImageExtent.width || info.width > caps.maxImageExtent.width ||
            info.height < caps.minImageExtent.height || info.height > caps.maxImageExtent.height ||
            ((requireExactExtent || caps.currentExtent.width != UINT32_MAX) &&
             (caps.currentExtent.width != info.width || caps.currentExtent.height != info.height)) ||
            caps.currentTransform != VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR ||
            !(caps.supportedTransforms & info.pre_transform) ||
            !(caps.supportedCompositeAlpha & info.composite_alpha) ||
            (caps.supportedUsageFlags & nativeUsage) != nativeUsage)
            return VK_ERROR_FEATURE_NOT_PRESENT;
        VkFormat format = static_cast<VkFormat>(info.vk_format);
        if (format != VK_FORMAT_R8G8B8A8_UNORM && format != VK_FORMAT_R8G8B8A8_SRGB &&
            format != VK_FORMAT_B8G8R8A8_UNORM && format != VK_FORMAT_B8G8R8A8_SRGB)
            return VK_ERROR_FORMAT_NOT_SUPPORTED;
        VkFormatProperties props{}; formatFn(device.physicalDevice, format, &props);
        const VkFormatFeatureFlags transfer = VK_FORMAT_FEATURE_TRANSFER_SRC_BIT | VK_FORMAT_FEATURE_TRANSFER_DST_BIT;
        if ((props.optimalTilingFeatures & transfer) != transfer) return VK_ERROR_FORMAT_NOT_SUPPORTED;
        uint32_t count = 0; r = formatsFn(device.physicalDevice, surface, &count, nullptr);
        if (r != VK_SUCCESS) return failed(r);
        if (!count || count > 4096) return VK_ERROR_FORMAT_NOT_SUPPORTED;
        std::vector<VkSurfaceFormatKHR> formats(count);
        r = formatsFn(device.physicalDevice, surface, &count, formats.data());
        if (r != VK_SUCCESS) return failed(r);
        formats.resize(count);
        bool found = false;
        for (const auto& f : formats) {
            if ((f.format == format || (formats.size() == 1 && f.format == VK_FORMAT_UNDEFINED)) &&
                static_cast<uint32_t>(f.colorSpace) == info.color_space) found = true;
        }
        if (!found) return VK_ERROR_FORMAT_NOT_SUPPORTED;
        count = 0; r = modesFn(device.physicalDevice, surface, &count, nullptr);
        if (r != VK_SUCCESS) return failed(r);
        if (!count || count > 4096) return VK_ERROR_FEATURE_NOT_PRESENT;
        std::vector<VkPresentModeKHR> modes(count);
        r = modesFn(device.physicalDevice, surface, &count, modes.data());
        if (r != VK_SUCCESS) return failed(r);
        modes.resize(count);
        if (std::find(modes.begin(), modes.end(), VK_PRESENT_MODE_FIFO_KHR) == modes.end())
            return VK_ERROR_FEATURE_NOT_PRESENT;
        VkSwapchainCreateInfoKHR create{}; create.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
        create.surface = surface; create.minImageCount = info.min_image_count;
        create.imageFormat = format; create.imageColorSpace = static_cast<VkColorSpaceKHR>(info.color_space);
        create.imageExtent = {info.width, info.height}; create.imageArrayLayers = info.image_array_layers;
        create.imageUsage = nativeUsage; create.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
        create.preTransform = static_cast<VkSurfaceTransformFlagBitsKHR>(info.pre_transform);
        create.compositeAlpha = static_cast<VkCompositeAlphaFlagBitsKHR>(info.composite_alpha);
        create.presentMode = VK_PRESENT_MODE_FIFO_KHR; create.clipped = info.clipped;
        VkSwapchainKHR swapchain = VK_NULL_HANDLE;
        r = vk->vkCreateSwapchainKHR(device.device, &create, nullptr, &swapchain);
        if (r != VK_SUCCESS) return failed(r);
        count = 0; r = vk->vkGetSwapchainImagesKHR(device.device, swapchain, &count, nullptr);
        if (r != VK_SUCCESS) { vk->vkDestroySwapchainKHR(device.device, swapchain, nullptr); return failed(r); }
        if (count < info.min_image_count || count > 256 || (caps.maxImageCount && count > caps.maxImageCount)) {
            vk->vkDestroySwapchainKHR(device.device, swapchain, nullptr); return VK_ERROR_FEATURE_NOT_PRESENT;
        }
        try { images->resize(count); }
        catch (const std::bad_alloc&) { vk->vkDestroySwapchainKHR(device.device, swapchain, nullptr); return VK_ERROR_OUT_OF_HOST_MEMORY; }
        r = vk->vkGetSwapchainImagesKHR(device.device, swapchain, &count, images->data());
        if (r != VK_SUCCESS) { images->clear(); vk->vkDestroySwapchainKHR(device.device, swapchain, nullptr); return failed(r); }
        if (count < info.min_image_count || count > 256 || (caps.maxImageCount && count > caps.maxImageCount)) {
            images->clear(); vk->vkDestroySwapchainKHR(device.device, swapchain, nullptr); return VK_ERROR_FEATURE_NOT_PRESENT;
        }
        images->resize(count); *out = swapchain;
        if (provider) provider->record(VK_SUCCESS);
        return VK_SUCCESS;
    } catch (const std::bad_alloc&) { return VK_ERROR_OUT_OF_HOST_MEMORY; }
}
VkResult validateVirtualPresentQueue(gfxstream::host::vk::CaboosePresentationDevice& device,
    VkSurfaceKHR surface, PresentationProviderResult* provider) {
    if (provider) *provider = {};
    auto get = runtimeInstanceProcAddr();
    if (!get || !device.instance || !device.physicalDevice || !device.device || !device.queue || !surface)
        return VK_ERROR_INITIALIZATION_FAILED;
    auto families = reinterpret_cast<PFN_vkGetPhysicalDeviceQueueFamilyProperties>(
        get(device.instance, "vkGetPhysicalDeviceQueueFamilyProperties"));
    auto support = reinterpret_cast<PFN_vkGetPhysicalDeviceSurfaceSupportKHR>(
        get(device.instance, "vkGetPhysicalDeviceSurfaceSupportKHR"));
    if (!families || !support) return VK_ERROR_EXTENSION_NOT_PRESENT;
    try {
        uint32_t count = 0;
        families(device.physicalDevice, &count, nullptr);
        if (!count || count > 4096 || device.queueFamily >= count) return VK_ERROR_FEATURE_NOT_PRESENT;
        std::vector<VkQueueFamilyProperties> properties(count);
        families(device.physicalDevice, &count, properties.data());
        if (device.queueFamily >= count || !(properties[device.queueFamily].queueFlags &
                (VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT | VK_QUEUE_TRANSFER_BIT)))
            return VK_ERROR_FEATURE_NOT_PRESENT;
        VkBool32 supported = VK_FALSE;
        VkResult result = support(device.physicalDevice, device.queueFamily, surface, &supported);
        if (result != VK_SUCCESS) return provider ? provider->record(result) : result;
        if (!supported) return VK_ERROR_FEATURE_NOT_PRESENT;
        return provider ? provider->record(VK_SUCCESS) : VK_SUCCESS;
    } catch (const std::bad_alloc&) { return VK_ERROR_OUT_OF_HOST_MEMORY; }
}
VkResult releaseUnusedVirtualImages(gfxstream::host::vk::CabooseSwapchainDevice& device,
    VkSwapchainKHR swapchain, uint32_t imageCount, uint32_t count, const uint32_t* indices,
    PresentationProviderResult* provider) {
    if (provider) *provider = {};
    if (!device.instance || !device.device || !swapchain || !imageCount || imageCount > 256 ||
        !count || count > imageCount || !indices)
        return VK_ERROR_INITIALIZATION_FAILED;
    for (uint32_t i = 0; i < count; ++i) {
        if (indices[i] >= imageCount) return VK_ERROR_INITIALIZATION_FAILED;
        for (uint32_t j = 0; j < i; ++j)
            if (indices[j] == indices[i]) return VK_ERROR_INITIALIZATION_FAILED;
    }
    auto get = runtimeInstanceProcAddr();
    if (!get) return VK_ERROR_INITIALIZATION_FAILED;
    auto getDevice = reinterpret_cast<PFN_vkGetDeviceProcAddr>(get(device.instance, "vkGetDeviceProcAddr"));
    if (!getDevice) return VK_ERROR_EXTENSION_NOT_PRESENT;
    auto release = reinterpret_cast<PFN_vkReleaseSwapchainImagesKHR>(
        getDevice(device.device, "vkReleaseSwapchainImagesKHR"));
    if (!release) release = reinterpret_cast<PFN_vkReleaseSwapchainImagesKHR>(
        getDevice(device.device, "vkReleaseSwapchainImagesEXT"));
    if (!release) return VK_ERROR_EXTENSION_NOT_PRESENT;
    VkReleaseSwapchainImagesInfoKHR info{};
    info.sType = VK_STRUCTURE_TYPE_RELEASE_SWAPCHAIN_IMAGES_INFO_KHR;
    info.swapchain = swapchain; info.imageIndexCount = count; info.pImageIndices = indices;
    VkResult result = release(device.device, &info);
    return provider ? provider->record(result) : result;
}
}
