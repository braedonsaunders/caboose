// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include "presentation_types.h"
#include "process_registry.h"
#include <memory>
#include <vulkan/vulkan.h>
namespace gfxstream::host::vk { struct CaboosePresentationObjects; struct CaboosePresentationInstance; struct CaboosePresentationDevice; }
namespace caboose::gpuv2 {
VkResult acquirePresentationInstance(caboose_gfx_registry* registry, uint64_t token,
    uint64_t boxedInstance, std::unique_ptr<gfxstream::host::vk::CaboosePresentationInstance>* out);
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
