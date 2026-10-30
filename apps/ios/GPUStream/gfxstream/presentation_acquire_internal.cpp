// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "presentation_acquire_internal.h"
#include "vk_decoder_global_state.h"
#include <new>
#include <utility>

namespace caboose::gpuv2 {
struct PresentationAcquire::Retained {
    std::unique_ptr<gfxstream::host::vk::CabooseAcquireSync> sync;
    std::shared_ptr<void> swapchainLease;
    VkFence observeFence = VK_NULL_HANDLE;
    bool ownsFence = false;
};
PresentationAcquire::PresentationAcquire(std::unique_ptr<Retained> retained)
    : retained_(std::move(retained)) {}
PresentationAcquire::~PresentationAcquire() {
    if (!retained_) return;
    // The driver may still signal an acquired semaphore/fence. Keep all leases
    // and the internally owned fence alive on an unproven shutdown path.
    if (acquiredValid_ && !signalDone_) { (void)retained_.release(); return; }
    if (retained_->ownsFence && retained_->observeFence)
        retained_->sync->vk->vkDestroyFence(retained_->sync->device, retained_->observeFence, nullptr);
}
VkResult PresentationAcquire::create(
    std::unique_ptr<gfxstream::host::vk::CabooseAcquireSync> sync, VkSwapchainKHR swapchain,
    std::shared_ptr<void> swapchainLease, std::shared_ptr<std::mutex> swapchainMutex,
    std::unique_ptr<PresentationAcquire>* out, PresentationProviderResult* provider) {
    if (provider) *provider = {};
    if (!out) return VK_ERROR_INITIALIZATION_FAILED;
    out->reset();
    if (!sync || !sync->vk || !sync->device || (!sync->semaphore && !sync->fence) ||
        !swapchain || !swapchainLease || !swapchainMutex || !sync->vk->vkAcquireNextImageKHR ||
        !sync->vk->vkGetFenceStatus || !sync->vk->vkCreateFence || !sync->vk->vkDestroyFence)
        return VK_ERROR_INITIALIZATION_FAILED;
    try {
        auto retained = std::make_unique<Retained>();
        retained->sync = std::move(sync);
        retained->swapchainLease = std::move(swapchainLease);
        retained->observeFence = retained->sync->fence;
        if (!retained->observeFence) {
            VkFenceCreateInfo info{}; info.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
            VkResult result = retained->sync->vk->vkCreateFence(retained->sync->device, &info, nullptr,
                                                                &retained->observeFence);
            if (result != VK_SUCCESS) return provider ? provider->record(result) : result;
            retained->ownsFence = true;
        }
        // Allocate the operation before transferring the fence into it. If this
        // allocation fails, destroy the unused internal fence explicitly.
        PresentationAcquire* operation = new (std::nothrow) PresentationAcquire(std::move(retained));
        if (!operation) {
            if (retained && retained->ownsFence)
                retained->sync->vk->vkDestroyFence(retained->sync->device, retained->observeFence, nullptr);
            return VK_ERROR_OUT_OF_HOST_MEMORY;
        }
        operation->swapchain_ = swapchain;
        operation->swapchainMutex_ = std::move(swapchainMutex);
        out->reset(operation);
        return VK_SUCCESS;
    } catch (const std::bad_alloc&) { return VK_ERROR_OUT_OF_HOST_MEMORY; }
}
PresentationAcquire::PollResult PresentationAcquire::poll() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (acquiredValid_) return acquired_;
    if (cancelled_) return {};
    uint32_t index = 0;
    VkResult result;
    {
        std::lock_guard<std::mutex> swapchainLock(*swapchainMutex_);
        result = retained_->sync->vk->vkAcquireNextImageKHR(retained_->sync->device, swapchain_, 0,
            retained_->sync->semaphore, retained_->observeFence, &index);
    }
    PollResult value{result, true, result == VK_SUCCESS || result == VK_SUBOPTIMAL_KHR, index};
    if (value.hasIndex) { acquired_ = value; acquiredValid_ = true; }
    return value;
}
bool PresentationAcquire::cancel() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (acquiredValid_) return false;
    cancelled_ = true;
    return true;
}
PresentationAcquire::PollResult PresentationAcquire::signalComplete() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!acquiredValid_) return {};
    if (signalDone_) return {signalResult_, true, false, 0};
    VkResult result = retained_->sync->vk->vkGetFenceStatus(retained_->sync->device, retained_->observeFence);
    if (result == VK_SUCCESS || result == VK_ERROR_DEVICE_LOST) {
        signalDone_ = true;
        signalResult_ = result;
    }
    return {result, true, false, 0};
}
}
