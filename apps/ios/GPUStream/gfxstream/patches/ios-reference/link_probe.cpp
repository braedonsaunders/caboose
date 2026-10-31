// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// Link-only probe. It is never launched and does not claim Vulkan execution.
#include "headless_framebuffer.h"
#include "process_registry.h"
#include "vulkan_dispatch.h"
#include <vulkan/vulkan.h>
namespace {
auto volatile initFrame = &caboose::gpuv2::initializeHeadlessFramebuffer;
auto volatile finalFrame = &caboose::gpuv2::finalizeHeadlessFramebuffer;
auto volatile installLoader = &gfxstream::host::vk::installVulkanLoader;
auto volatile registryCreate = &caboose_gfx_registry_create;
auto volatile registryDestroy = &caboose_gfx_registry_destroy;
auto volatile processOpen = &caboose_gfx_process_open;
auto volatile processRun = &caboose_gfx_process_run;
auto volatile processStop = &caboose_gfx_process_stop;
auto volatile processFinish = &caboose_gfx_process_finish;
auto volatile vulkanLoader = &vkGetInstanceProcAddr;
}
int main() {
    return !(initFrame && finalFrame && installLoader && registryCreate && registryDestroy &&
             processOpen && processRun && processStop && processFinish && vulkanLoader);
}
