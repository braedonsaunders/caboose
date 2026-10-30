// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include "presentation_types.h"
#include "process_registry.h"
#include <memory>
#include <vulkan/vulkan.h>
namespace gfxstream::host::vk { struct CaboosePresentationObjects; }
namespace caboose::gpuv2 {
// Internal entry: caller has already authenticated the surface identity and
// selected a live owner layer. Admission is serialized with process stop.
// This only obtains the underlying objects/lifetime lease, not presentation.
VkResult acquirePresentationObjects(caboose_gfx_registry* registry,
    uint64_t boxedInstance, const caboose_gpu_present_info& info,
    std::unique_ptr<gfxstream::host::vk::CaboosePresentationObjects>* out);
}
