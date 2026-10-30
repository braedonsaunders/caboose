// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include "presentation_provider_result.h"
#include <cstdint>
#include <memory>
#include <mutex>
#include <vulkan/vulkan.h>

namespace gfxstream::host::vk { struct CabooseAcquireSync; }
namespace caboose::gpuv2 {
// Real acquire operation, not a public API. The caller owns the per-swapchain
// host-synchronization mutex and a lease that prevents swapchain destruction.
// Keep this object until signalComplete() reports real success/device loss.
// Dropping it early quarantines its leases rather than claiming cleanup.
class PresentationAcquire {
public:
    struct PollResult {
        VkResult value = VK_ERROR_INITIALIZATION_FAILED;
        bool fromProvider = false;
        bool hasIndex = false;
        uint32_t index = 0;
    };
    static VkResult create(std::unique_ptr<gfxstream::host::vk::CabooseAcquireSync> sync,
        VkSwapchainKHR swapchain, std::shared_ptr<void> swapchainLease,
        std::shared_ptr<std::mutex> swapchainMutex,
        std::unique_ptr<PresentationAcquire>* out, PresentationProviderResult* provider);
    ~PresentationAcquire();
    PresentationAcquire(const PresentationAcquire&) = delete;
    PresentationAcquire& operator=(const PresentationAcquire&) = delete;
    // One actual vkAcquireNextImageKHR call with timeout zero. The caller paces
    // retries with a monotonic deadline and serializes cancel against this call.
    PollResult poll();
    // Local cancellation only wins before an actual successful acquire. On a
    // lost race returns false; poll() then returns the retained actual index.
    bool cancel();
    // A successful acquire schedules a real signal; this method observes its
    // real fence without blocking. It never manufactures completion.
    PollResult signalComplete();
private:
    struct Retained;
    explicit PresentationAcquire(std::unique_ptr<Retained> retained);
    std::mutex mutex_;
    std::unique_ptr<Retained> retained_;
    VkSwapchainKHR swapchain_ = VK_NULL_HANDLE;
    std::shared_ptr<std::mutex> swapchainMutex_;
    PollResult acquired_{};
    bool cancelled_ = false;
    bool acquiredValid_ = false;
    bool signalDone_ = false;
    VkResult signalResult_ = VK_SUCCESS;
};
}
