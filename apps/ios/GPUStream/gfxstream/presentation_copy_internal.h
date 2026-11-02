// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <vulkan/vulkan.h>
#include "presentation_provider_result.h"
namespace gfxstream::host::vk { struct CaboosePresentationObjects; }
namespace caboose::gpuv2 {
// Internal GPU operations. Caller owns all swapchain and synchronization objects,
// verifies destination format/extent, queue family and surface ownership, and
// holds the decoder object lease until the copy fence is actually signaled.
// Guest source must have been transitioned to GENERAL before its original wait
// semaphores were signaled. The acquired destination is fully overwritten.
// If acquired is null, the caller must already have observed the real acquire
// signal completion; a guest acquire binary semaphore must never be waited twice.
// A success means submission only; it is not an image-release receipt.
// A non-null `capture` (same format and extent as the source, owned by the caller's capture
// ring) receives a second copy of the source in the same submission.
// A non-null `destinationExtent` is the destination's extent when it may differ from the
// source's; `placePresentation` (presentation_placement.h) decides where the source lands:
// a lengthened image's top-left part is copied, any other size is scaled to fit, and destination
// pixels the source does not cover are cleared.
VkResult submitPresentationCopy(gfxstream::host::vk::CaboosePresentationObjects& objects,
    VkImage destination, VkSemaphore acquired, VkSemaphore ready,
    VkFence copyFence, VkCommandBuffer commandBuffer, PresentationProviderResult* provider,
    VkImage capture = VK_NULL_HANDLE, const VkExtent2D* destinationExtent = nullptr);
// A successful return means queued presentation, not displayed-vsync completion.
// Caller must have queried and enabled swapchain maintenance1 on this actual
// device. The ready semaphore and swapchain remain alive until presentFence is
// actually signaled; timeout is not completion.
// A nonzero presentId is chained as the VK_GOOGLE_display_timing present ID while frame
// lab measures (framelab_timing.h).
VkResult queuePresentation(gfxstream::host::vk::CaboosePresentationObjects& objects,
    VkSwapchainKHR swapchain, uint32_t imageIndex, VkSemaphore ready, VkFence presentFence,
    PresentationProviderResult* provider, uint64_t presentId = 0);
}
