// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "presentation_copy_internal.h"
#include "vk_decoder_global_state.h"
#include <algorithm>
#include <memory>
#include <mutex>
#include <new>
#include <vector>

namespace caboose::gpuv2 {
VkResult submitPresentationCopy(gfxstream::host::vk::CaboosePresentationObjects& objects,
    VkImage destination, VkSemaphore acquired, VkSemaphore ready,
    VkFence copyFence, VkCommandBuffer commandBuffer, PresentationProviderResult* provider) {
    if (provider) *provider = {};
    auto* vk = objects.vk;
    if (!vk || !objects.device || !objects.queue || !objects.image || !objects.queueMutex ||
        !destination || destination == objects.image || !acquired || !ready || acquired == ready ||
        !copyFence || !commandBuffer || !vk->vkBeginCommandBuffer || !vk->vkEndCommandBuffer ||
        !vk->vkCmdPipelineBarrier || !vk->vkCmdCopyImage || !vk->vkQueueSubmit)
        return VK_ERROR_INITIALIZATION_FAILED;
    if (std::find(objects.waitSemaphores.begin(), objects.waitSemaphores.end(), acquired) != objects.waitSemaphores.end() ||
        std::find(objects.waitSemaphores.begin(), objects.waitSemaphores.end(), ready) != objects.waitSemaphores.end())
        return VK_ERROR_INITIALIZATION_FAILED;
    try {
        std::vector<VkSemaphore> waits = objects.waitSemaphores;
        waits.push_back(acquired);
        std::vector<VkPipelineStageFlags> stages(waits.size(), VK_PIPELINE_STAGE_TRANSFER_BIT);
        VkCommandBufferBeginInfo begin{};
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        VkResult result = vk->vkBeginCommandBuffer(commandBuffer, &begin);
        if (result != VK_SUCCESS) return provider ? provider->record(result) : result;
        VkImageSubresourceRange range{};
        range.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        range.levelCount = 1; range.layerCount = 1;
        VkImageMemoryBarrier barriers[2]{};
        for (auto& barrier : barriers) {
            barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
            barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
            barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
            barrier.subresourceRange = range;
        }
        barriers[0].image = objects.image;
        barriers[0].oldLayout = VK_IMAGE_LAYOUT_GENERAL;
        barriers[0].newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        barriers[0].dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        barriers[1].image = destination;
        barriers[1].oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        barriers[1].newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barriers[1].dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        vk->vkCmdPipelineBarrier(commandBuffer, VK_PIPELINE_STAGE_TRANSFER_BIT,
            VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, 2, barriers);
        VkImageCopy region{};
        region.srcSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        region.srcSubresource.layerCount = 1;
        region.dstSubresource = region.srcSubresource;
        region.extent = objects.extent;
        vk->vkCmdCopyImage(commandBuffer, objects.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            destination, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
        barriers[0].oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        barriers[0].newLayout = VK_IMAGE_LAYOUT_GENERAL;
        barriers[0].srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        barriers[0].dstAccessMask = 0;
        barriers[1].oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barriers[1].newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        barriers[1].srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        barriers[1].dstAccessMask = 0;
        vk->vkCmdPipelineBarrier(commandBuffer, VK_PIPELINE_STAGE_TRANSFER_BIT,
            VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, nullptr, 0, nullptr, 2, barriers);
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
    PresentationProviderResult* provider) {
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
    std::lock_guard<std::mutex> lock(*objects.queueMutex);
    VkResult result = objects.vk->vkQueuePresentKHR(objects.queue, &info);
    return provider ? provider->record(result) : result;
}
}
