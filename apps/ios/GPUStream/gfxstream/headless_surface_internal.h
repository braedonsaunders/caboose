// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <vulkan/vulkan.h>
#include <cstdint>

namespace caboose::gpuv2 {
PFN_vkGetInstanceProcAddr runtimeInstanceProcAddr();
// The Linux executor's window surface: a VK_EXT_headless_surface of the decoder-owned
// instance. Its swapchains present offscreen; nothing is displayed.
struct HeadlessSurface;
// The caller retains the decoder-owned instance, created by the installed provider with
// VK_KHR_surface and VK_EXT_headless_surface enabled (gfxstream fork commit
// "Caboose: linux-headless-executor"). Creation only, not presentation.
int createHeadlessSurface(VkInstance instance, HeadlessSurface** out, VkResult* vulkanResult);
// Caller first retires every swapchain and GPU use; the instance must still be alive.
int destroyHeadlessSurface(HeadlessSurface** surface);
VkSurfaceKHR headlessSurfaceHandle(const HeadlessSurface* surface);
}
