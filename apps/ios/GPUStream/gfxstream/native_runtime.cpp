// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "native_runtime.h"
#include "caboose_pipeline_cache.h"
#ifdef CABOOSE_GPU_MEMORY_AUDIT
#include "memory_audit.h"
#endif
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
bool installedVirtualWsi = false;
unsigned installedMode = 0;
int startResult = EAGAIN;
PFN_vkGetInstanceProcAddr installedGet = nullptr;
caboose_gpu_resolve_export installedResolve = nullptr;
caboose_gfx_registry* registry = nullptr;
uint64_t nextToken = 1;
#ifdef CABOOSE_GPU_MEMORY_AUDIT
bool memoryAuditRequested = false;
#endif
}
static int startRuntime(PFN_vkGetInstanceProcAddr get, caboose_gpu_resolve_export resolve,
                        unsigned mode) {
    const bool virtualWsi = mode != 0;
    if (!get || !resolve) return EINVAL;
    // The global entrypoint and exported trampolines must come from the same
    // caller-owned provider; do not silently mix two Vulkan loaders.
    if (reinterpret_cast<PFN_vkGetInstanceProcAddr>(resolve("vkGetInstanceProcAddr")) != get ||
        !resolve("vkCreateInstance") || !resolve("vkDestroyInstance")) return EINVAL;
    std::lock_guard<std::mutex> lock(mutex);
#ifdef CABOOSE_GPU_MEMORY_AUDIT
    if (memoryAuditRequested && mode != 2) return EINVAL;
#endif
    if (attempted) {
        if (get != installedGet || resolve != installedResolve || mode != installedMode)
            return EBUSY;
        return startResult;
    }
    attempted = true;
    installedGet = get;
    installedResolve = resolve;
    installedVirtualWsi = virtualWsi;
    installedMode = mode;
    (void)caboose::gpuv2::enableConcurrentShaderCompilation();
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
    if (mode == 2) features.VulkanVirtualQueue.setEnabled(false);
#ifdef CABOOSE_GPU_INDEXED_WSI
    features.CabooseSynchronousProof.setEnabled(mode == 2);
#endif
#ifdef CABOOSE_GPU_MEMORY_AUDIT
    features.CabooseMemoryAudit.setEnabled(memoryAuditRequested);
#endif
    features.VulkanNullOptionalStrings.setEnabled(true);
#ifdef CABOOSE_GPU_PRESENTATION_LEASE
    features.CabooseVirtualWsi.setEnabled(virtualWsi);
#endif
    if (!caboose::gpuv2::initializeHeadlessFramebuffer(features)) return startResult = EIO;
    const auto& actual = gfxstream::host::FrameBuffer::getFB()->getFeatures();
    if (actual.GlDirectMem.enabled() || actual.VirtioGpuNext.enabled() ||
        actual.ExternalBlob.enabled() || actual.VulkanQueueSubmitWithCommands.enabled() ||
        (mode == 2 && actual.VulkanVirtualQueue.enabled()) ||
#ifdef CABOOSE_GPU_INDEXED_WSI
        (actual.CabooseSynchronousProof.enabled() != (mode == 2)) ||
#endif
#ifdef CABOOSE_GPU_MEMORY_AUDIT
        (actual.CabooseMemoryAudit.enabled() != memoryAuditRequested) ||
#endif
        !actual.VulkanNullOptionalStrings.enabled()
#ifdef CABOOSE_GPU_PRESENTATION_LEASE
        || actual.CabooseVirtualWsi.enabled() != virtualWsi
#endif
        ) {
        caboose::gpuv2::finalizeHeadlessFramebuffer();
        return startResult = EPROTO;
    }
    const int result = mode == 2 ? caboose_gfx_registry_create_synchronous(&registry)
                                 : caboose_gfx_registry_create(&registry);
    if (result) {
        caboose::gpuv2::finalizeHeadlessFramebuffer();
        return startResult = result;
    }
    return startResult = 0;
}
extern "C" int caboose_gpu_runtime_start(PFN_vkGetInstanceProcAddr get,
                                           caboose_gpu_resolve_export resolve) {
    return startRuntime(get, resolve, 0);
}
#ifdef CABOOSE_GPU_PRESENTATION_LEASE
extern "C" int caboose_gpu_runtime_start_virtual_wsi(PFN_vkGetInstanceProcAddr get,
                                                       caboose_gpu_resolve_export resolve) {
    return startRuntime(get, resolve, 1);
}
#endif
#ifdef CABOOSE_GPU_INDEXED_WSI
extern "C" int caboose_gpu_runtime_start_v4(PFN_vkGetInstanceProcAddr get,
                                                       caboose_gpu_resolve_export resolve) {
    return startRuntime(get, resolve, 2);
}
#endif
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
caboose_gfx_registry* virtualWsiRegistry() {
    std::lock_guard<std::mutex> lock(mutex);
    return startResult == 0 && installedVirtualWsi ? registry : nullptr;
}
#ifdef CABOOSE_GPU_INDEXED_WSI
caboose_gfx_registry* indexedWsiRegistry() {
    std::lock_guard<std::mutex> lock(mutex);
    return startResult == 0 && installedMode == 2 ? registry : nullptr;
}
#endif
}
#ifdef CABOOSE_GPU_MEMORY_AUDIT
extern "C" int caboose_gpu_runtime_enable_memory_audit(void) {
    std::lock_guard<std::mutex> lock(mutex);
    if (attempted) return EBUSY;
    memoryAuditRequested = true;
    return 0;
}
extern "C" int caboose_gpu_runtime_memory_features(caboose_gpu_memory_features* out) {
    if (!out) return EINVAL;
    *out = {};
    std::lock_guard<std::mutex> lock(mutex);
    if (startResult || installedMode != 2 || !memoryAuditRequested) return ENODEV;
    auto* fb = gfxstream::host::FrameBuffer::getFB();
    if (!fb || !fb->getFeatures().CabooseMemoryAudit.enabled()) return ENODEV;
    const auto& f = fb->getFeatures();
    out->gl_direct_mem = f.GlDirectMem.enabled();
    out->virtio_gpu_next = f.VirtioGpuNext.enabled();
    out->disable_coherent_emulation = f.VulkanDisableCoherentMemoryAndEmulate.enabled();
    out->ensure_cached_coherent = f.VulkanEnsureCachedCoherentMemoryAvailable.enabled();
    out->allocate_device_only = f.VulkanAllocateDeviceMemoryOnly.enabled();
    out->allocate_host_memory = f.VulkanAllocateHostMemory.enabled();
    out->system_blob = f.SystemBlob.enabled();
    out->dedicated_ahb_type = f.VulkanUseDedicatedAhbMemoryType.enabled();
    out->external_blob = f.ExternalBlob.enabled();
    out->virtual_queue = f.VulkanVirtualQueue.enabled();
    out->submit_with_commands = f.VulkanQueueSubmitWithCommands.enabled();
    out->synchronous_proof = f.CabooseSynchronousProof.enabled();
    out->max_safe_heap_size = f.VulkanMaxSafeHeapSize.getValue().value_or(0);
    return 0;
}
extern "C" int caboose_gpu_runtime_memory_receipts(uint64_t token, caboose_gpu_memory_receipt* out,
                                                     size_t capacity, size_t* count) {
    auto* r = getRegistry();
    return r ? caboose_gfx_process_memory_receipts(r, token, out, capacity, count) : ENODEV;
}
#endif
extern "C" int caboose_gpu_runtime_run(uint64_t token, int fd, size_t max_packet,
                                        size_t max_reply_buffer) {
    auto* r = getRegistry();
    return r ? caboose_gfx_process_run(r, token, fd, max_packet, max_reply_buffer) : ENODEV;
}
#ifdef CABOOSE_GPU_DECODER_TESTING
extern "C" int caboose_gpu_runtime_run_counted(uint64_t token, int fd, size_t max_packet,
    size_t max_reply_buffer, uint64_t* entries) {
    auto* r = getRegistry();
    return r ? caboose_gfx_process_run_counted(r, token, fd, max_packet, max_reply_buffer, entries) : ENODEV;
}
#endif
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
