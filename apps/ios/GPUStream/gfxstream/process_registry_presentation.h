// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include "presentation_types.h"
#include "process_registry.h"
#include <memory>
#include <vulkan/vulkan.h>
namespace gfxstream::host::vk { struct CaboosePresentationObjects; struct CaboosePresentationInstance; struct CaboosePresentationPhysicalDevice; struct CaboosePresentationDevice; struct CabooseAcquireSync; struct CabooseSwapchainDevice; struct CabooseMappedSources; }
namespace caboose::gpuv2 {
VkResult acquireMappedSources(caboose_gfx_registry* registry, uint64_t token,
    uint64_t boxedInstance, uint64_t boxedDevice, uint32_t format, uint32_t width, uint32_t height,
    uint32_t usage, uint32_t count, const uint64_t* boxedImages,
    std::unique_ptr<gfxstream::host::vk::CabooseMappedSources>* out);
VkResult acquireSwapchainDevice(caboose_gfx_registry* registry, uint64_t token,
    uint64_t boxedInstance, uint64_t boxedDevice,
    std::unique_ptr<gfxstream::host::vk::CabooseSwapchainDevice>* out);
// Keeps instance, device and supplied semaphore/fence alive; release only after
// real acquire signal completion or established terminal device loss.
VkResult acquirePresentationSync(caboose_gfx_registry* registry, uint64_t token,
    uint64_t boxedInstance, uint64_t boxedDevice, uint64_t boxedSemaphore, uint64_t boxedFence,
    std::unique_ptr<gfxstream::host::vk::CabooseAcquireSync>* out);
VkResult acquirePresentationInstance(caboose_gfx_registry* registry, uint64_t token,
    uint64_t boxedInstance, std::unique_ptr<gfxstream::host::vk::CaboosePresentationInstance>* out);
VkResult acquirePresentationPhysicalDevice(caboose_gfx_registry* registry, uint64_t token,
    uint64_t boxedInstance, uint64_t boxedPhysicalDevice,
    std::unique_ptr<gfxstream::host::vk::CaboosePresentationPhysicalDevice>* out);
VkResult acquirePresentationDevice(caboose_gfx_registry* registry, uint64_t token,
    uint64_t boxedInstance, uint64_t boxedDevice, uint64_t boxedQueue, uint32_t queueFamily,
    std::unique_ptr<gfxstream::host::vk::CaboosePresentationDevice>* out);
// Internal entry: caller has already authenticated the surface identity and
// selected a live owner layer. Admission is serialized with process stop.
// This only obtains the underlying objects/lifetime lease, not presentation.
VkResult acquirePresentationObjects(caboose_gfx_registry* registry,
    uint64_t boxedInstance, const caboose_gpu_present_info& info,
    std::unique_ptr<gfxstream::host::vk::CaboosePresentationObjects>* out);
}
