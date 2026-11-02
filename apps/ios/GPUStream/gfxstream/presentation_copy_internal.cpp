// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "presentation_copy_internal.h"
#include "framelab_timing.h"
#include "presentation_placement.h"
#include "vk_decoder_global_state.h"
#include <algorithm>
#include <memory>
#include <mutex>
#include <new>
#include <vector>

namespace caboose::gpuv2 {
VkResult submitPresentationCopy(gfxstream::host::vk::CaboosePresentationObjects& objects,
    VkImage destination, VkSemaphore acquired, VkSemaphore ready,
    VkFence copyFence, VkCommandBuffer commandBuffer, PresentationProviderResult* provider,
    VkImage capture, const VkExtent2D* destinationExtent) {
    if (provider) *provider = {};
    auto* vk = objects.vk;
    if (!vk || !objects.device || !objects.queue || !objects.image || !objects.queueMutex ||
        !destination || destination == objects.image || capture == objects.image || capture == destination ||
        !ready || acquired == ready ||
        !copyFence || !commandBuffer || !vk->vkBeginCommandBuffer || !vk->vkEndCommandBuffer ||
        !vk->vkCmdPipelineBarrier || !vk->vkCmdCopyImage || !vk->vkQueueSubmit)
        return VK_ERROR_INITIALIZATION_FAILED;
    if (std::find(objects.waitSemaphores.begin(), objects.waitSemaphores.end(), acquired) != objects.waitSemaphores.end() ||
        std::find(objects.waitSemaphores.begin(), objects.waitSemaphores.end(), ready) != objects.waitSemaphores.end())
        return VK_ERROR_INITIALIZATION_FAILED;
    try {
        std::vector<VkSemaphore> waits = objects.waitSemaphores;
        if (acquired) waits.push_back(acquired);
        std::vector<VkPipelineStageFlags> stages(waits.size(), VK_PIPELINE_STAGE_TRANSFER_BIT);
        VkCommandBufferBeginInfo begin{};
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        VkResult result = vk->vkBeginCommandBuffer(commandBuffer, &begin);
        if (result != VK_SUCCESS) return provider ? provider->record(result) : result;
        VkImageSubresourceRange range{};
        range.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        range.levelCount = 1; range.layerCount = 1;
        VkImageMemoryBarrier barriers[3]{};
        for (auto& barrier : barriers) {
            barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
            barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
            barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
            barrier.subresourceRange = range;
        }
        barriers[0].image = objects.image;
        barriers[0].oldLayout = VK_IMAGE_LAYOUT_GENERAL;
        barriers[0].newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        barriers[0].srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT;
        barriers[0].dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        barriers[1].image = destination;
        barriers[1].oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        barriers[1].newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barriers[1].dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        // The capture's previous contents were read by Metal before the slot was released.
        barriers[2] = barriers[1];
        barriers[2].image = capture;
        const uint32_t count = capture ? 3 : 2;
        vk->vkCmdPipelineBarrier(commandBuffer, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
            VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, count, barriers);
        VkImageCopy region{};
        region.srcSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        region.srcSubresource.layerCount = 1;
        region.dstSubresource = region.srcSubresource;
        region.extent = objects.extent;
        VkImageCopy shown = region;
        PresentationPlacement placement;
        if (destinationExtent) {
            placement = placePresentation(objects.extent.width, objects.extent.height,
                                          destinationExtent->width, destinationExtent->height);
            shown.extent.width = placement.copyWidth;
            shown.extent.height = placement.copyHeight;
            if (placement.kind == PresentationPlacement::Kind::scale && !vk->vkCmdBlitImage)
                return VK_ERROR_INITIALIZATION_FAILED;
            if (placement.clear) {
                if (!vk->vkCmdClearColorImage) return VK_ERROR_INITIALIZATION_FAILED;
                const VkClearColorValue black{};
                vk->vkCmdClearColorImage(commandBuffer, destination, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                                         &black, 1, &range);
                VkMemoryBarrier cleared{VK_STRUCTURE_TYPE_MEMORY_BARRIER, nullptr,
                                        VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_TRANSFER_WRITE_BIT};
                vk->vkCmdPipelineBarrier(commandBuffer, VK_PIPELINE_STAGE_TRANSFER_BIT,
                    VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 1, &cleared, 0, nullptr, 0, nullptr);
            }
        }
        if (placement.kind == PresentationPlacement::Kind::scale) {
            VkImageBlit blit{};
            blit.srcSubresource = region.srcSubresource;
            blit.dstSubresource = region.dstSubresource;
            blit.srcOffsets[1] = {int32_t(objects.extent.width), int32_t(objects.extent.height), 1};
            blit.dstOffsets[0] = {placement.x, placement.y, 0};
            blit.dstOffsets[1] = {placement.x + int32_t(placement.width), placement.y + int32_t(placement.height), 1};
            vk->vkCmdBlitImage(commandBuffer, objects.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                destination, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &blit, VK_FILTER_LINEAR);
        } else {
            vk->vkCmdCopyImage(commandBuffer, objects.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                destination, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &shown);
        }
        if (capture) {
            vk->vkCmdCopyImage(commandBuffer, objects.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                capture, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
        }
        barriers[0].oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        barriers[0].newLayout = VK_IMAGE_LAYOUT_GENERAL;
        barriers[0].srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        barriers[0].dstAccessMask = 0;
        barriers[1].oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barriers[1].newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        barriers[1].srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        barriers[1].dstAccessMask = 0;
        // Metal reads the capture after the copy fence; its layout is GENERAL from here.
        barriers[2].oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barriers[2].newLayout = VK_IMAGE_LAYOUT_GENERAL;
        barriers[2].srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        barriers[2].dstAccessMask = VK_ACCESS_MEMORY_READ_BIT;
        vk->vkCmdPipelineBarrier(commandBuffer, VK_PIPELINE_STAGE_TRANSFER_BIT,
            VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, nullptr, 0, nullptr, count, barriers);
#if !defined(__APPLE__)
        if (capture) {
            // The Linux executor reads its captures on the CPU once the copy fence signals.
            VkMemoryBarrier host{VK_STRUCTURE_TYPE_MEMORY_BARRIER, nullptr, VK_ACCESS_TRANSFER_WRITE_BIT,
                                 VK_ACCESS_HOST_READ_BIT};
            vk->vkCmdPipelineBarrier(commandBuffer, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
                0, 1, &host, 0, nullptr, 0, nullptr);
        }
#endif
        result = vk->vkEndCommandBuffer(commandBuffer);
        if (result != VK_SUCCESS) return provider ? provider->record(result) : result;
        VkSubmitInfo submit{};
        submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit.waitSemaphoreCount = static_cast<uint32_t>(waits.size());
        submit.pWaitSemaphores = waits.data();
        submit.pWaitDstStageMask = stages.data();
        submit.commandBufferCount = 1; submit.pCommandBuffers = &commandBuffer;
        submit.signalSemaphoreCount = 1; submit.pSignalSemaphores = &ready;
        std::lock_guard<std::mutex> lock(*objects.queueMutex);
        VkResult submitted = vk->vkQueueSubmit(objects.queue, 1, &submit, copyFence);
        return provider ? provider->record(submitted) : submitted;
    } catch (const std::bad_alloc&) { return VK_ERROR_OUT_OF_HOST_MEMORY; }
}
VkResult queuePresentation(gfxstream::host::vk::CaboosePresentationObjects& objects,
    VkSwapchainKHR swapchain, uint32_t imageIndex, VkSemaphore ready, VkFence presentFence,
    PresentationProviderResult* provider, uint64_t presentId) {
    if (provider) *provider = {};
    if (!objects.vk || !objects.vk->vkQueuePresentKHR || !objects.queue ||
        !objects.queueMutex || !swapchain || !ready || !presentFence) return VK_ERROR_INITIALIZATION_FAILED;
    VkSwapchainPresentFenceInfoKHR fenceInfo{};
    fenceInfo.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_PRESENT_FENCE_INFO_KHR;
    fenceInfo.swapchainCount = 1; fenceInfo.pFences = &presentFence;
    VkPresentInfoKHR info{};
    info.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
    info.pNext = &fenceInfo;
    info.waitSemaphoreCount = 1; info.pWaitSemaphores = &ready;
    info.swapchainCount = 1; info.pSwapchains = &swapchain; info.pImageIndices = &imageIndex;
    VkPresentTimeGOOGLE time{static_cast<uint32_t>(presentId), 0};
    VkPresentTimesInfoGOOGLE times{VK_STRUCTURE_TYPE_PRESENT_TIMES_INFO_GOOGLE, nullptr, 1, &time};
    if (presentId && caboose::framelab::pastTiming(objects.vk, objects.device)) {
        times.pNext = info.pNext;
        info.pNext = &times;
    }
    std::lock_guard<std::mutex> lock(*objects.queueMutex);
    VkResult result = objects.vk->vkQueuePresentKHR(objects.queue, &info);
    return provider ? provider->record(result) : result;
}
}
