// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "presentation_swapchain_internal.h"
#include "metal_surface_internal.h"
#include "vk_decoder_global_state.h"
#include <algorithm>
#include <cerrno>
#include <limits>
#include <new>

namespace caboose::gpuv2 {
VkResult createPresentationSwapchain(gfxstream::host::vk::CaboosePresentationDevice& device,
    VkSurfaceKHR surface, VkFormat format, uint32_t width, uint32_t height,
    VkSwapchainKHR* swapchain, std::vector<VkImage>* images, PresentationProviderResult* provider) {
    if (provider) *provider = {};
    auto driverFailure = [provider](VkResult result) { return provider ? provider->record(result) : result; };
    if (!swapchain || !images) return VK_ERROR_INITIALIZATION_FAILED;
    *swapchain = VK_NULL_HANDLE; images->clear();
    auto get = runtimeInstanceProcAddr();
    auto* vk = device.vk;
    if (!get || !vk || !device.instance || !device.physicalDevice || !device.device ||
        !device.queue || !surface || !width || !height || format == VK_FORMAT_UNDEFINED ||
        !vk->vkCreateSwapchainKHR || !vk->vkDestroySwapchainKHR || !vk->vkGetSwapchainImagesKHR ||
        !vk->vkAcquireNextImageKHR)
        return VK_ERROR_INITIALIZATION_FAILED;
    auto support = reinterpret_cast<PFN_vkGetPhysicalDeviceSurfaceSupportKHR>(
        get(device.instance, "vkGetPhysicalDeviceSurfaceSupportKHR"));
    auto capabilities = reinterpret_cast<PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR>(
        get(device.instance, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR"));
    auto formats = reinterpret_cast<PFN_vkGetPhysicalDeviceSurfaceFormatsKHR>(
        get(device.instance, "vkGetPhysicalDeviceSurfaceFormatsKHR"));
    auto modes = reinterpret_cast<PFN_vkGetPhysicalDeviceSurfacePresentModesKHR>(
        get(device.instance, "vkGetPhysicalDeviceSurfacePresentModesKHR"));
    auto families = reinterpret_cast<PFN_vkGetPhysicalDeviceQueueFamilyProperties>(
        get(device.instance, "vkGetPhysicalDeviceQueueFamilyProperties"));
    auto formatProperties = reinterpret_cast<PFN_vkGetPhysicalDeviceFormatProperties>(
        get(device.instance, "vkGetPhysicalDeviceFormatProperties"));
    if (!support || !capabilities || !formats || !modes || !families || !formatProperties)
        return VK_ERROR_EXTENSION_NOT_PRESENT;
    try {
        VkFormatProperties props{};
        formatProperties(device.physicalDevice, format, &props);
        const VkFormatFeatureFlags transfer = VK_FORMAT_FEATURE_TRANSFER_SRC_BIT | VK_FORMAT_FEATURE_TRANSFER_DST_BIT;
        if ((props.optimalTilingFeatures & transfer) != transfer) return VK_ERROR_FORMAT_NOT_SUPPORTED;
        uint32_t familyCount = 0;
        families(device.physicalDevice, &familyCount, nullptr);
        if (!familyCount || familyCount > 4096 || device.queueFamily >= familyCount)
            return VK_ERROR_FEATURE_NOT_PRESENT;
        std::vector<VkQueueFamilyProperties> familyProperties(familyCount);
        families(device.physicalDevice, &familyCount, familyProperties.data());
        if (device.queueFamily >= familyCount ||
            !(familyProperties[device.queueFamily].queueFlags &
              (VK_QUEUE_TRANSFER_BIT | VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT)))
            return VK_ERROR_FEATURE_NOT_PRESENT;
        VkBool32 supported = VK_FALSE;
        VkResult result = support(device.physicalDevice, device.queueFamily, surface, &supported);
        if (result != VK_SUCCESS) return driverFailure(result);
        if (!supported) return VK_ERROR_FEATURE_NOT_PRESENT;
        VkSurfaceCapabilitiesKHR caps{};
        result = capabilities(device.physicalDevice, surface, &caps);
        if (result != VK_SUCCESS) return driverFailure(result);
        if (!(caps.supportedUsageFlags & VK_IMAGE_USAGE_TRANSFER_DST_BIT) ||
            !(caps.supportedCompositeAlpha & VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR) ||
            caps.currentTransform != VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR ||
            width < caps.minImageExtent.width || width > caps.maxImageExtent.width ||
            height < caps.minImageExtent.height || height > caps.maxImageExtent.height ||
            (caps.currentExtent.width != UINT32_MAX &&
             (caps.currentExtent.width != width || caps.currentExtent.height != height)))
            return VK_ERROR_FEATURE_NOT_PRESENT;
        uint32_t count = 0;
        result = formats(device.physicalDevice, surface, &count, nullptr);
        if (result != VK_SUCCESS || count == 0 || count > 4096) return result == VK_SUCCESS ? VK_ERROR_FORMAT_NOT_SUPPORTED : driverFailure(result);
        std::vector<VkSurfaceFormatKHR> available(count);
        result = formats(device.physicalDevice, surface, &count, available.data());
        if (result != VK_SUCCESS) return driverFailure(result);
        available.resize(count);
        bool found = false;
        for (const auto& f : available)
            if ((f.format == format || (available.size() == 1 && f.format == VK_FORMAT_UNDEFINED)) &&
                f.colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) found = true;
        if (!found) return VK_ERROR_FORMAT_NOT_SUPPORTED;
        count = 0;
        result = modes(device.physicalDevice, surface, &count, nullptr);
        if (result != VK_SUCCESS || count == 0 || count > 4096) return result == VK_SUCCESS ? VK_ERROR_FEATURE_NOT_PRESENT : driverFailure(result);
        std::vector<VkPresentModeKHR> availableModes(count);
        result = modes(device.physicalDevice, surface, &count, availableModes.data());
        if (result != VK_SUCCESS) return driverFailure(result);
        availableModes.resize(count);
        if (std::find(availableModes.begin(), availableModes.end(), VK_PRESENT_MODE_FIFO_KHR) == availableModes.end())
            return VK_ERROR_FEATURE_NOT_PRESENT;
        uint32_t desired = caps.minImageCount;
        if (desired < std::numeric_limits<uint32_t>::max()) ++desired;
        if (caps.maxImageCount && desired > caps.maxImageCount) desired = caps.maxImageCount;
        VkSwapchainCreateInfoKHR create{};
        create.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
        create.surface = surface; create.minImageCount = desired;
        create.imageFormat = format; create.imageColorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;
        create.imageExtent = {width, height}; create.imageArrayLayers = 1;
        create.imageUsage = VK_IMAGE_USAGE_TRANSFER_DST_BIT;
        create.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
        create.preTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
        create.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
        create.presentMode = VK_PRESENT_MODE_FIFO_KHR; create.clipped = VK_TRUE;
        VkSwapchainKHR created = VK_NULL_HANDLE;
        result = vk->vkCreateSwapchainKHR(device.device, &create, nullptr, &created);
        if (result != VK_SUCCESS) return driverFailure(result);
        count = 0;
        result = vk->vkGetSwapchainImagesKHR(device.device, created, &count, nullptr);
        if (result != VK_SUCCESS && provider) provider->record(result);
        if (result == VK_SUCCESS && count && count <= 4096) {
            try {
                images->resize(count);
                result = vk->vkGetSwapchainImagesKHR(device.device, created, &count, images->data());
                if (result != VK_SUCCESS && provider) provider->record(result);
            } catch (const std::bad_alloc&) { result = VK_ERROR_OUT_OF_HOST_MEMORY; }
        } else if (result == VK_SUCCESS) result = VK_ERROR_INITIALIZATION_FAILED;
        if (result != VK_SUCCESS) {
            images->clear(); vk->vkDestroySwapchainKHR(device.device, created, nullptr); return result;
        }
        images->resize(count);
        *swapchain = created;
        if (provider) provider->record(VK_SUCCESS);
        return VK_SUCCESS;
    } catch (const std::bad_alloc&) { return VK_ERROR_OUT_OF_HOST_MEMORY; }
}
VkResult acquirePresentationImage(gfxstream::host::vk::CaboosePresentationDevice& device,
    VkSwapchainKHR swapchain, uint64_t timeoutNs, VkSemaphore acquired, uint32_t* imageIndex,
    PresentationProviderResult* provider) {
    if (provider) *provider = {};
    if (!device.vk || !device.vk->vkAcquireNextImageKHR || !device.device || !swapchain ||
        !acquired || !imageIndex) return VK_ERROR_INITIALIZATION_FAILED;
    VkResult result = device.vk->vkAcquireNextImageKHR(device.device, swapchain, timeoutNs, acquired,
                                                        VK_NULL_HANDLE, imageIndex);
    return provider ? provider->record(result) : result;
}
VkResult waitPresentationFence(gfxstream::host::vk::CaboosePresentationDevice& device,
    VkFence fence, uint64_t timeoutNs) {
    if (!device.vk || !device.vk->vkWaitForFences || !device.device || !fence)
        return VK_ERROR_INITIALIZATION_FAILED;
    return device.vk->vkWaitForFences(device.device, 1, &fence, VK_TRUE, timeoutNs);
}
int destroyPresentationSwapchain(gfxstream::host::vk::CaboosePresentationDevice& device,
    VkSwapchainKHR swapchain) {
    if (!device.vk || !device.vk->vkDestroySwapchainKHR || !device.device || !swapchain) return EINVAL;
    device.vk->vkDestroySwapchainKHR(device.device, swapchain, nullptr);
    return 0;
}
}
