// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "native_runtime.h"
#include "headless_framebuffer.h"
#include "process_registry.h"
#include "frame_buffer.h"
#include "gfxstream/host/features.h"
#include "vulkan_dispatch.h"
#include <cerrno>
#include <cstdint>
#include <limits>
#include <mutex>

namespace {
std::mutex mutex;
bool attempted = false;
int startResult = EAGAIN;
PFN_vkGetInstanceProcAddr installedGet = nullptr;
caboose_gpu_resolve_export installedResolve = nullptr;
caboose_gfx_registry* registry = nullptr;
uint64_t nextToken = 1;
}
extern "C" int caboose_gpu_runtime_start(PFN_vkGetInstanceProcAddr get,
                                           caboose_gpu_resolve_export resolve) {
    if (!get || !resolve) return EINVAL;
    // The global entrypoint and exported trampolines must come from the same
    // caller-owned provider; do not silently mix two Vulkan loaders.
    if (reinterpret_cast<PFN_vkGetInstanceProcAddr>(resolve("vkGetInstanceProcAddr")) != get ||
        !resolve("vkCreateInstance") || !resolve("vkDestroyInstance")) return EINVAL;
    std::lock_guard<std::mutex> lock(mutex);
    if (attempted) {
        if (get != installedGet || resolve != installedResolve) return EBUSY;
        return startResult;
    }
    attempted = true;
    installedGet = get;
    installedResolve = resolve;
    if (!gfxstream::host::vk::installVulkanLoader(get, resolve)) return startResult = EBUSY;
    gfxstream::host::FeatureSet features;
    features.Vulkan.setEnabled(true);
    features.GuestVulkanOnly.setEnabled(true);
    features.GlDirectMem.setEnabled(false);
    features.VirtioGpuNext.setEnabled(false);
    features.ExternalBlob.setEnabled(false);
    features.VulkanSnapshots.setEnabled(false);
    features.VulkanNativeSwapchain.setEnabled(false);
    features.VulkanQueueSubmitWithCommands.setEnabled(false);
    features.VulkanNullOptionalStrings.setEnabled(true);
    if (!caboose::gpuv2::initializeHeadlessFramebuffer(features)) return startResult = EIO;
    const auto& actual = gfxstream::host::FrameBuffer::getFB()->getFeatures();
    if (actual.GlDirectMem.enabled() || actual.VirtioGpuNext.enabled() ||
        actual.ExternalBlob.enabled() || actual.VulkanQueueSubmitWithCommands.enabled() ||
        !actual.VulkanNullOptionalStrings.enabled()) {
        caboose::gpuv2::finalizeHeadlessFramebuffer();
        return startResult = EPROTO;
    }
    const int result = caboose_gfx_registry_create(&registry);
    if (result) {
        caboose::gpuv2::finalizeHeadlessFramebuffer();
        return startResult = result;
    }
    return startResult = 0;
}
extern "C" int caboose_gpu_runtime_open(uint64_t* token) {
    if (!token) return EINVAL;
    *token = 0;
    std::lock_guard<std::mutex> lock(mutex);
    if (startResult) return startResult;
    if (nextToken == std::numeric_limits<uint64_t>::max()) return ENOSPC;
    const uint64_t candidate = nextToken++;
    const int result = caboose_gfx_process_open(registry, candidate);
    if (!result) *token = candidate;
    return result;
}
namespace {
caboose_gfx_registry* getRegistry() {
    std::lock_guard<std::mutex> lock(mutex);
    return startResult == 0 ? registry : nullptr;
}
}
namespace caboose::gpuv2 {
PFN_vkGetInstanceProcAddr runtimeInstanceProcAddr() {
    std::lock_guard<std::mutex> lock(mutex);
    return startResult == 0 ? installedGet : nullptr;
}
}
extern "C" int caboose_gpu_runtime_run(uint64_t token, int fd, size_t max_packet,
                                        size_t max_reply_buffer) {
    auto* r = getRegistry();
    return r ? caboose_gfx_process_run(r, token, fd, max_packet, max_reply_buffer) : ENODEV;
}
extern "C" int caboose_gpu_runtime_stop(uint64_t token) {
    auto* r = getRegistry();
    return r ? caboose_gfx_process_stop(r, token) : ENODEV;
}
extern "C" int caboose_gpu_runtime_finish(uint64_t token) {
    auto* r = getRegistry();
    if (!r) return ENODEV;
    const int result = caboose_gfx_process_finish(r, token);
    if (result) return result;
    // stop enqueues cleanup before process_finish can remove this entry. The
    // upstream barrier waits through that queued cleanup, without holding the
    // registry or runtime mutex; cleanup itself waits for render TLS to leave.
    gfxstream::host::FrameBuffer::getFB()->waitForAllPendingCleanups();
    return 0;
}
