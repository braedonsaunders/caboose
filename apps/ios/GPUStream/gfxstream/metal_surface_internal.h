// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <vulkan/vulkan.h>

namespace caboose::gpuv2 {
PFN_vkGetInstanceProcAddr runtimeInstanceProcAddr();
struct MetalSurface;
// Internal only: the caller must retain the decoder-owned instance and ensure
// it belongs to the process-wide installed provider, with VK_KHR_surface and
// VK_EXT_metal_surface enabled at creation. Call on the main thread.
// A successful return is surface creation only, not presentation or completion.
int createMetalSurface(VkInstance instance, void* metalLayer, MetalSurface** out,
                       VkResult* vulkanResult);
// Main thread only. Caller must first retire all swapchains and GPU use; the
// decoder-owned instance must still be alive. Clears *surface on success.
int destroyMetalSurface(MetalSurface** surface);
VkSurfaceKHR metalSurfaceHandle(const MetalSurface* surface);
// Main only, no swapchain/GPU use. Checks exact retained layer, sets actual
// natural/drawable pixel extent without changing its position or transform.
int configureMetalSurfaceExtent(MetalSurface* surface, void* trustedLayer,
                                uint32_t width, uint32_t height);
bool metalSurfaceMatchesLayer(const MetalSurface* surface, void* trustedLayer);
}
