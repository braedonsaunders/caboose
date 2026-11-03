// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "native_runtime.h"
#include "caboose_pipeline_cache.h"
#include "shader_store.h"
#include "upload_store.h"
#ifdef CABOOSE_GPU_MEMORY_AUDIT
#include "memory_audit.h"
#endif
#include "executor_gate.h"
#include "memory_budget.h"
#include "headless_framebuffer.h"
#include "process_registry.h"
#include "frame_buffer.h"
#include "gfxstream/host/features.h"
#include "vulkan_dispatch.h"
#include "vk_decoder_global_state.h"
#include <chrono>
#include <cerrno>
#include <cstdio>
#include <cstdint>
#include <limits>
#include <mutex>
#include <string>

namespace {
// How long finish waits for its process's cleanup before letting it go on alone.
constexpr uint32_t kFinishCleanupWaitMs = 4000;
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
    // Batched descriptor sets (docs/gpu-live.md): each pool's set ids exist from its creation,
    // for guests that allocate and write sets themselves and commit them with a submit.
    // Guests that allocate sets per call are served as before.
    features.VulkanBatchedDescriptorSetUpdate.setEnabled(true);
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
        !actual.VulkanNullOptionalStrings.enabled() || !actual.VulkanBatchedDescriptorSetUpdate.enabled()
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
    caboose::gpuv2::installMemoryBudget();
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
// The patched MoltenVK's persistent Metal pipeline binaries
// (provider-patches/moltenvk-pipeline-binary-archive.patch). Weak, so a provider without
// them, such as a desktop reference build, keeps only the shader and pipeline caches.
extern "C" void mvkCabooseSetPipelineArchivePath(const char* path) __attribute__((weak));
extern "C" bool mvkCabooseSavePipelineArchive(void) __attribute__((weak));
extern "C" void mvkCabooseGetPipelineArchiveStats(uint64_t* hits, uint64_t* misses) __attribute__((weak));
extern "C" int caboose_gpu_runtime_set_cache_root(const char* root) {
    const int result = caboose::gpuv2::setShaderStoreRoot(root);
    if (mvkCabooseSetPipelineArchivePath) {
        const std::string selected = caboose::gpuv2::cacheRoot();
        mvkCabooseSetPipelineArchivePath(selected.empty() ? nullptr
                                         : (selected + "/pipeline/metal-binary-archive.bin").c_str());
    }
    return result;
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
extern "C" int caboose_gpu_runtime_wait_order(uint64_t token, uint64_t serial) {
    auto* r = getRegistry();
    return r ? caboose_gfx_process_wait_order(r, token, serial) : ENODEV;
}
extern "C" int caboose_gpu_runtime_suspend(uint32_t timeout_ms) {
    if (!getRegistry()) return ENODEV;
    if (const int closed = caboose::gpuv2::ExecutorGate::instance().close(std::chrono::milliseconds(timeout_ms)))
        return closed;
    auto* state = gfxstream::host::vk::VkDecoderGlobalState::get();
    return state && state->waitCabooseQueuesIdle() != VK_SUCCESS ? EIO : 0;
}
extern "C" int caboose_gpu_runtime_resume(void) {
    caboose::gpuv2::ExecutorGate::instance().open();
    return 0;
}
extern "C" int caboose_gpu_runtime_set_memory_limit(uint64_t bytes) {
    caboose::gpuv2::setMemoryLimit(bytes);
    return 0;
}
extern "C" void caboose_gpu_runtime_report_teardown(void) {
    if (auto* r = getRegistry()) caboose_gfx_registry_report(r);
}
extern "C" int caboose_gpu_runtime_stop(uint64_t token) {
    auto* r = getRegistry();
    return r ? caboose_gfx_process_stop(r, token) : ENODEV;
}
extern "C" int caboose_gpu_runtime_finish(uint64_t token) {
    auto* r = getRegistry();
    if (!r) return ENODEV;
    uint32_t context = 0;
    const int result = caboose_gfx_process_finish_context(r, token, &context);
    if (result) return result;
    // stop enqueued this process's cleanup before process_finish removed its entry. It is
    // waited for a bounded time, without holding the registry or runtime mutex: past it the
    // cleanup goes on by itself, and what it cannot free yet (GPU work or a presentation
    // still in flight) is deferred until it can, never holding other processes' cleanups.
    if (!gfxstream::host::FrameBuffer::getFB()->waitForGuestProcessCleanup(context, kFinishCleanupWaitMs)) {
        std::fprintf(stderr, "CABOOSE_GPU_CLEANUP_CONTINUES token=%llu context=%u\n",
                     (unsigned long long)token, context);
        caboose_gfx_registry_report(r);
    }
    // The process's pipelines are compiled; keep their binaries for the next launch.
    const bool archiveSaved = mvkCabooseSavePipelineArchive ? mvkCabooseSavePipelineArchive() : false;
    // What the persistent caches saved since launch, for the device console.
    uint64_t hits = 0, misses = 0;
    if (mvkCabooseGetPipelineArchiveStats) mvkCabooseGetPipelineArchiveStats(&hits, &misses);
    if (const auto store = caboose::gpuv2::currentShaderStore()) {
        const auto s = store->stats();
        std::fprintf(stderr,
            "CABOOSE_GPU_CACHES shaders=%llu shader_bytes=%llu resolved=%llu resolved_bytes=%llu "
            "unresolved=%llu inserted=%llu write_failures=%llu pipeline_hits=%llu pipeline_misses=%llu "
            "archive_saved=%d\n",
            (unsigned long long)s.entries, (unsigned long long)s.bytes, (unsigned long long)s.resolved,
            (unsigned long long)s.resolvedBytes, (unsigned long long)s.unresolved,
            (unsigned long long)s.inserted, (unsigned long long)s.writeFailures,
            (unsigned long long)hits, (unsigned long long)misses, archiveSaved ? 1 : 0);
    }
    if (const auto store = caboose::gpuv2::currentUploadStore()) {
        const auto s = store->stats();
        std::fprintf(stderr,
            "CABOOSE_GPU_CACHES uploads=%llu upload_packs=%llu stored=%llu duplicates=%llu resolved=%llu "
            "unresolved=%llu write_failures=%llu dropped_packs=%llu budget_bytes=%llu\n",
            (unsigned long long)s.pieces, (unsigned long long)s.packs, (unsigned long long)s.stored,
            (unsigned long long)s.duplicates, (unsigned long long)s.resolved, (unsigned long long)s.unresolved,
            (unsigned long long)s.writeFailures, (unsigned long long)s.droppedPacksAtOpen,
            (unsigned long long)s.budgetBytes);
    }
    return 0;
}
