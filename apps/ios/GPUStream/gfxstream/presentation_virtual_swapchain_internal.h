// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include "presentation_provider_result.h"
#include "presentation_swapchain_api_draft.h"
#include <vector>
#include <vulkan/vulkan.h>
namespace gfxstream::host::vk { struct CabooseSwapchainDevice; }
namespace caboose::gpuv2 {
// Real provider creation; caller retains the decoder device lease and surface.
// The function rejects unsupported guest parameters, never substitutes them.
VkResult createVirtualSwapchain(gfxstream::host::vk::CabooseSwapchainDevice& device,
    VkSurfaceKHR surface, const caboose_gpu_swapchain_create_info& info,
    VkSwapchainKHR* out, std::vector<VkImage>* images, PresentationProviderResult* provider);
}
