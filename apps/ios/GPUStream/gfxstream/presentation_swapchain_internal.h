// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <vulkan/vulkan.h>
#include <vector>
namespace gfxstream::host::vk { struct CaboosePresentationDevice; }
namespace caboose::gpuv2 {
// Caller owns the real surface and a live device lease until swapchain teardown.
// Checks real surface/queue/format/extent/usage and creates a FIFO swapchain.
// Only exact extent and identity transform are accepted; no scaling is implied.
VkResult createPresentationSwapchain(gfxstream::host::vk::CaboosePresentationDevice& device,
    VkSurfaceKHR surface, VkFormat format, uint32_t width, uint32_t height,
    VkSwapchainKHR* swapchain, std::vector<VkImage>* images);
// Caller serializes swapchain operations. A timeout or other error does not
// authorize use of an image or imply that any guest wait was consumed.
VkResult acquirePresentationImage(gfxstream::host::vk::CaboosePresentationDevice& device,
    VkSwapchainKHR swapchain, uint64_t timeoutNs, VkSemaphore acquired, uint32_t* imageIndex);
// A timeout/error is not retirement. The caller retains all protected objects.
VkResult waitPresentationFence(gfxstream::host::vk::CaboosePresentationDevice& device,
    VkFence fence, uint64_t timeoutNs);
// Caller MUST first retire all submitted copy/present work, including every
// maintenance1 present fence, or establish real terminal device loss.
int destroyPresentationSwapchain(gfxstream::host::vk::CaboosePresentationDevice& device,
    VkSwapchainKHR swapchain);
}
