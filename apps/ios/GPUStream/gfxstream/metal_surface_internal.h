// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <vulkan/vulkan.h>

namespace caboose::gpuv2 {
PFN_vkGetInstanceProcAddr runtimeInstanceProcAddr();
struct MetalSurface;
// Internal only: the caller must retain the decoder-owned instance and ensure
// it belongs to the process-wide installed provider. Call on the main thread.
// A successful return is surface creation only, not presentation or completion.
int createMetalSurface(VkInstance instance, void* metalLayer, MetalSurface** out,
                       VkResult* vulkanResult);
// Main thread only. Caller must first retire all swapchains and GPU use; the
// decoder-owned instance must still be alive. Clears *surface on success.
int destroyMetalSurface(MetalSurface** surface);
VkSurfaceKHR metalSurfaceHandle(const MetalSurface* surface);
}
