// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "process_registry.h"
#include "completion_feed.h"
#include "decode_connection.h"
#include "frame_buffer.h"
#include "render_thread_info.h"
#ifdef CABOOSE_GPU_PRESENTATION_LEASE
#include "process_registry_presentation.h"
#include "vk_decoder_global_state.h"
#include <vector>
#endif
#include <atomic>
#include <cerrno>
#include <cstdint>
#ifdef CABOOSE_GPU_MEMORY_AUDIT
#include <cstdio>
#include <cinttypes>
#endif
#include <map>
#include <memory>
#include <mutex>
#include <new>
#include <set>
#include <sys/socket.h>

using gfxstream::host::FrameBuffer;
using gfxstream::host::ProcessResources;
using gfxstream::host::RenderThreadInfo;
namespace {
std::mutex singletonMutex;
bool registryExists = false;
struct Process {
    uint32_t context;
    std::shared_ptr<const ProcessResources> resources;
    // Completion feedback for this guest process, shared by all its streams.
    std::shared_ptr<caboose::gpuv2::CompletionFeed> completions;
    std::atomic_bool stopped{false};
    std::set<int> sockets;
#ifdef CABOOSE_GPU_MEMORY_AUDIT
    caboose::gpuv2::DecodeDiagnosticBudget terminalBudget;
#endif
};
}
struct caboose_gfx_registry {
    std::mutex mutex;
    std::map<uint64_t, std::shared_ptr<Process>> processes;
    std::set<int> activeSockets;
    uint64_t nextContext = 1;
    bool synchronousOnly = false;
};
static int createRegistry(caboose_gfx_registry** out, bool synchronousOnly) {
    if (!out) return EINVAL;
    *out = nullptr;
    std::lock_guard<std::mutex> lock(singletonMutex);
    if (registryExists) return EBUSY;
    if (!FrameBuffer::getFB() || !FrameBuffer::getFB()->hasEmulationVk()) return ENODEV;
    try { *out = new caboose_gfx_registry; } catch (const std::bad_alloc&) { return ENOMEM; }
    (*out)->synchronousOnly = synchronousOnly;
    registryExists = true;
    return 0;
}
extern "C" int caboose_gfx_registry_create(caboose_gfx_registry** out) {
    return createRegistry(out, false);
}
extern "C" int caboose_gfx_registry_create_synchronous(caboose_gfx_registry** out) {
    return createRegistry(out, true);
}
extern "C" int caboose_gfx_registry_destroy(caboose_gfx_registry* registry) {
    if (!registry) return EINVAL;
    // Caller must serialize destroy against all calls, including new opens.
    std::lock_guard<std::mutex> singletonLock(singletonMutex);
    {
        std::lock_guard<std::mutex> lock(registry->mutex);
        if (!registry->processes.empty()) return EBUSY;
    }
    FrameBuffer::getFB()->waitForAllPendingCleanups();
    delete registry;
    registryExists = false;
    return 0;
}
extern "C" int caboose_gfx_process_open(caboose_gfx_registry* registry, uint64_t puid) {
    if (!registry || !puid) return EINVAL;
    std::lock_guard<std::mutex> lock(registry->mutex);
    if (registry->processes.count(puid)) return EEXIST;
    auto* fb = FrameBuffer::getFB();
    if (!fb) return ENODEV;
    // IDs are never reused during this registry's lifetime, including after
    // asynchronous cleanup; skip any resources owned outside this registry.
    while (registry->nextContext < UINT32_MAX &&
           fb->getProcessResources(registry->nextContext)) ++registry->nextContext;
    if (registry->nextContext >= UINT32_MAX) return ENOSPC;
    const uint32_t context = static_cast<uint32_t>(registry->nextContext++);
    try {
        auto process = std::make_shared<Process>();
        process->context = context;
        process->completions = std::make_shared<caboose::gpuv2::CompletionFeed>(
            [context](uint64_t boxedQueue) -> caboose::gpuv2::CompletionFeed::Waiter {
                auto* state = gfxstream::host::vk::VkDecoderGlobalState::get();
                std::unique_ptr<gfxstream::host::vk::CabooseCompletionMarker> marker;
                if (!state || state->submitCabooseCompletionMarker(context,
                        (VkQueue)(uintptr_t)boxedQueue, &marker) != VK_SUCCESS)
                    return {};
                std::shared_ptr<gfxstream::host::vk::CabooseCompletionMarker> held(std::move(marker));
                return [held]() -> int32_t {
                    VkResult result = held->vk->vkWaitForFences(held->device, 1, &held->fence,
                                                                VK_TRUE, UINT64_MAX);
                    held->vk->vkDestroyFence(held->device, held->fence, nullptr);
                    held->fence = VK_NULL_HANDLE;
                    return result;
                };
            });
        auto [it, inserted] = registry->processes.emplace(puid, process);
        if (!inserted) return EEXIST;
        try {
            fb->createGraphicsProcessResources(context);
            process->resources = fb->getProcessResources(context);
        } catch (...) {
            if (fb->getProcessResources(context)) fb->signalGuestProcessDead(context);
            registry->processes.erase(it);
            throw;
        }
        if (!process->resources) { registry->processes.erase(it); return EIO; }
        return 0;
    } catch (const std::bad_alloc&) { return ENOMEM; }
      catch (...) { return EIO; }
}
#ifdef CABOOSE_GPU_MEMORY_AUDIT
static void emitDecodeTerminal(Process& process, uint64_t token,
    const caboose::gpuv2::DecodeDiagnostic& d, int result, size_t maxPacket, size_t maxReply) {
    const unsigned record = process.terminalBudget.take();
    if (record > 64) return;
    if (record == 64) {
        std::fprintf(stderr, "CABOOSE_GPU_DECODE_TERMINAL token=%" PRIu64 " context=%u overflow=1\n",
                     token, process.context);
        return;
    }
    std::fprintf(stderr,
        "CABOOSE_GPU_DECODE_TERMINAL token=%" PRIu64 " context=%u record=%u stage=%u result=%d "
        "header=%u opcode=%u declared=%u buffered=%" PRIu64 " frame=%" PRIu64 " consumed=%" PRIu64 " "
        "last_present=%u last_opcode=%u completed=%" PRIu64 " socket_errno=%d eof=%u stopped=%u "
        "max_packet=%zu max_reply=%zu ranges=%u range_index=%u tail_present=%u "
        "tail_bytes=%" PRIu64 " tail_offset=%" PRIu64 "\n",
        token, process.context, record, static_cast<unsigned>(d.stage), result,
        d.headerPresent, d.opcode, d.declared, d.buffered, d.frameSize, d.consumed,
        d.lastOpcodePresent, d.lastOpcode, d.completed, d.socketError,
        unsigned(d.eof), unsigned(d.stopped), maxPacket, maxReply, d.frame.rangeCount,
        d.frame.rangeIndex, unsigned(d.frame.tailPresent), d.frame.tailBytes, d.frame.tailOffset);
}
#endif
static int runProcess(caboose_gfx_registry* registry, uint64_t puid, int fd,
                      size_t max_packet, size_t max_reply_buffer, uint64_t* decoderEntries) {
    if (!registry || fd < 0) return EINVAL;
    if (RenderThreadInfo::get() || gfxstream::host::vk::RenderThreadInfoVk::get()) return EBUSY;
    std::shared_ptr<Process> process;
    try {
        // Registration and TLS creation happen under the same admission lock as
        // stop: upstream cleanup must see this thread before it can be signalled.
        std::unique_lock<std::mutex> lock(registry->mutex);
        auto it = registry->processes.find(puid);
        if (it == registry->processes.end()) return ENOENT;
        process = it->second;
        if (process->stopped) return ECANCELED;
        if (!registry->activeSockets.insert(fd).second) return EBUSY;
        try {
            process->sockets.insert(fd);
            RenderThreadInfo threadInfo;
            threadInfo.m_vkInfo.emplace();
            threadInfo.setPuid(process->context);
            threadInfo.setProcessResources(process->resources);
            lock.unlock();
            caboose::gpuv2::DecodeDiagnostic* diagnostic = nullptr;
#ifdef CABOOSE_GPU_MEMORY_AUDIT
            caboose::gpuv2::DecodeDiagnostic terminal;
            if (FrameBuffer::getFB()->getFeatures().CabooseMemoryAudit.enabled()) diagnostic = &terminal;
#endif
            int result;
            try {
                result = caboose::gpuv2::decodeConnection(fd, max_packet, max_reply_buffer,
                    threadInfo, process->stopped, registry->synchronousOnly, decoderEntries, diagnostic,
                    process->completions.get());
            } catch (const std::bad_alloc&) {
#ifdef CABOOSE_GPU_MEMORY_AUDIT
                if (diagnostic) emitDecodeTerminal(*process, puid, terminal, ENOMEM, max_packet, max_reply_buffer);
#endif
                throw;
            } catch (...) {
#ifdef CABOOSE_GPU_MEMORY_AUDIT
                if (diagnostic) emitDecodeTerminal(*process, puid, terminal, EIO, max_packet, max_reply_buffer);
#endif
                throw;
            }
#ifdef CABOOSE_GPU_MEMORY_AUDIT
            if (diagnostic) emitDecodeTerminal(*process, puid, terminal, result, max_packet, max_reply_buffer);
#endif
            // Decoder work has ended. Clear the TLS identities while admission is locked;
            // the TLS object is destroyed before that lock is released.
            if (result != 0) shutdown(fd, SHUT_RDWR);
            lock.lock();
            threadInfo.setProcessResources(nullptr);
            threadInfo.setPuid(0);
            process->sockets.erase(fd);
            registry->activeSockets.erase(fd);
            return result;
        } catch (...) {
            shutdown(fd, SHUT_RDWR);
            if (!lock.owns_lock()) lock.lock();
            process->sockets.erase(fd);
            registry->activeSockets.erase(fd);
            throw;
        }
    } catch (const std::bad_alloc&) { return ENOMEM; }
      catch (...) { return EIO; }
}
extern "C" int caboose_gfx_process_run(caboose_gfx_registry* registry, uint64_t puid, int fd,
                                       size_t max_packet, size_t max_reply_buffer) {
    return runProcess(registry, puid, fd, max_packet, max_reply_buffer, nullptr);
}
#ifdef CABOOSE_GPU_DECODER_TESTING
extern "C" int caboose_gfx_process_run_counted(caboose_gfx_registry* registry, uint64_t puid, int fd,
    size_t max_packet, size_t max_reply_buffer, uint64_t* entries) {
    if (!entries) return EINVAL;
    *entries = 0;
    return runProcess(registry, puid, fd, max_packet, max_reply_buffer, entries);
}
#endif
extern "C" int caboose_gfx_process_stop(caboose_gfx_registry* registry, uint64_t puid) {
    if (!registry) return EINVAL;
    std::lock_guard<std::mutex> lock(registry->mutex);
    auto it = registry->processes.find(puid);
    if (it == registry->processes.end()) return ENOENT;
    auto& process = *it->second;
    if (process.stopped.exchange(true)) return 0;
    if (process.completions) process.completions->cancelOrders();
    FrameBuffer::getFB()->signalGuestProcessDead(process.context);
    for (int fd : process.sockets) shutdown(fd, SHUT_RDWR);
    return 0;
}
extern "C" int caboose_gfx_process_wait_order(caboose_gfx_registry* registry, uint64_t puid,
                                              uint64_t serial) {
    if (!registry || !serial) return EINVAL;
    std::shared_ptr<caboose::gpuv2::CompletionFeed> completions;
    {
        std::lock_guard<std::mutex> lock(registry->mutex);
        auto it = registry->processes.find(puid);
        if (it == registry->processes.end()) return ENOENT;
        if (it->second->stopped) return ECANCELED;
        completions = it->second->completions;
    }
    return completions ? completions->waitOrdered(serial) : ENOTSUP;
}
extern "C" int caboose_gfx_process_finish(caboose_gfx_registry* registry, uint64_t puid) {
    if (!registry) return EINVAL;
    std::unique_lock<std::mutex> lock(registry->mutex);
    auto it = registry->processes.find(puid);
    if (it == registry->processes.end()) return ENOENT;
    if (!it->second->stopped || !it->second->sockets.empty()) return EBUSY;
    // Upstream retains the resources in its asynchronous cleanup closure. IDs
    // are not reused while that cleanup may still be running.
    auto completions = std::move(it->second->completions);
    registry->processes.erase(it);
    lock.unlock();
    // Outstanding completion markers each hold their device; they finish with the GPU.
    completions.reset();
    return 0;
}
#ifdef CABOOSE_GPU_MEMORY_AUDIT
extern "C" int caboose_gfx_process_memory_receipts(caboose_gfx_registry* registry, uint64_t token,
    caboose_gpu_memory_receipt* out, size_t capacity, size_t* count) {
    if (!registry || !token || !count || capacity > 256 || (capacity && !out)) return EINVAL;
    *count = 0;
    std::lock_guard<std::mutex> lock(registry->mutex);
    auto it = registry->processes.find(token);
    if (it == registry->processes.end()) return ENOENT;
    auto* fb = FrameBuffer::getFB();
    if (!fb || !fb->getFeatures().CabooseMemoryAudit.enabled()) return ENOTSUP;
    auto* state = gfxstream::host::vk::VkDecoderGlobalState::get();
    if (!state) return ENODEV;
    return state->readCabooseMemoryAudit(it->second->context, out, capacity, count) ? 0 : EOVERFLOW;
}
#endif
#ifdef CABOOSE_GPU_PRESENTATION_LEASE
namespace caboose::gpuv2 {
VkResult acquireMappedSources(caboose_gfx_registry* registry, uint64_t token,
    uint64_t boxedInstance, uint64_t boxedDevice, uint32_t format, uint32_t width, uint32_t height,
    uint32_t usage, uint32_t count, const uint64_t* boxedImages,
    std::unique_ptr<gfxstream::host::vk::CabooseMappedSources>* out) {
    static_assert(sizeof(uintptr_t) == sizeof(uint64_t), "64-bit boxed Vulkan handles required");
    if (!out) return VK_ERROR_INITIALIZATION_FAILED;
    out->reset();
    if (!registry || !token || !boxedInstance || !boxedDevice || !count || count > 256 || !boxedImages)
        return VK_ERROR_INITIALIZATION_FAILED;
    try {
        std::vector<VkImage> images;
        images.reserve(count);
        for (uint32_t i = 0; i < count; ++i) images.push_back((VkImage)(uintptr_t)boxedImages[i]);
        std::lock_guard<std::mutex> lock(registry->mutex);
        auto it = registry->processes.find(token);
        if (it == registry->processes.end() || it->second->stopped) return VK_ERROR_INITIALIZATION_FAILED;
        return gfxstream::host::vk::VkDecoderGlobalState::get()->acquireCabooseMappedSources(
            it->second->context, (VkInstance)(uintptr_t)boxedInstance, (VkDevice)(uintptr_t)boxedDevice,
            static_cast<VkFormat>(format), width, height, usage, count, images.data(), out);
    } catch (const std::bad_alloc&) { return VK_ERROR_OUT_OF_HOST_MEMORY; }
}
VkResult acquireSwapchainDevice(caboose_gfx_registry* registry, uint64_t token,
    uint64_t boxedInstance, uint64_t boxedDevice,
    std::unique_ptr<gfxstream::host::vk::CabooseSwapchainDevice>* out) {
    static_assert(sizeof(uintptr_t) == sizeof(uint64_t), "64-bit boxed Vulkan handles required");
    if (!out) return VK_ERROR_INITIALIZATION_FAILED;
    out->reset();
    if (!registry || !token || !boxedInstance || !boxedDevice) return VK_ERROR_INITIALIZATION_FAILED;
    std::lock_guard<std::mutex> lock(registry->mutex);
    auto it = registry->processes.find(token);
    if (it == registry->processes.end() || it->second->stopped) return VK_ERROR_INITIALIZATION_FAILED;
    return gfxstream::host::vk::VkDecoderGlobalState::get()->acquireCabooseSwapchainDevice(
        it->second->context, (VkInstance)(uintptr_t)boxedInstance, (VkDevice)(uintptr_t)boxedDevice, out);
}
VkResult acquirePresentationSync(caboose_gfx_registry* registry, uint64_t token,
    uint64_t boxedInstance, uint64_t boxedDevice, uint64_t boxedSemaphore, uint64_t boxedFence,
    std::unique_ptr<gfxstream::host::vk::CabooseAcquireSync>* out) {
    static_assert(sizeof(uintptr_t) == sizeof(uint64_t), "64-bit boxed Vulkan handles required");
    if (!out) return VK_ERROR_INITIALIZATION_FAILED;
    out->reset();
    if (!registry || !token || !boxedInstance || !boxedDevice || (!boxedSemaphore && !boxedFence))
        return VK_ERROR_INITIALIZATION_FAILED;
    std::lock_guard<std::mutex> lock(registry->mutex);
    auto it = registry->processes.find(token);
    if (it == registry->processes.end() || it->second->stopped) return VK_ERROR_INITIALIZATION_FAILED;
    return gfxstream::host::vk::VkDecoderGlobalState::get()->acquireCabooseAcquireSync(
        it->second->context, (VkInstance)(uintptr_t)boxedInstance, (VkDevice)(uintptr_t)boxedDevice,
        (VkSemaphore)(uintptr_t)boxedSemaphore, (VkFence)(uintptr_t)boxedFence, out);
}
VkResult acquirePresentationInstance(caboose_gfx_registry* registry, uint64_t token,
    uint64_t boxedInstance, std::unique_ptr<gfxstream::host::vk::CaboosePresentationInstance>* out) {
    static_assert(sizeof(uintptr_t) == sizeof(uint64_t), "64-bit boxed Vulkan handles required");
    if (!out) return VK_ERROR_INITIALIZATION_FAILED;
    out->reset();
    if (!registry || !token || !boxedInstance) return VK_ERROR_INITIALIZATION_FAILED;
    std::lock_guard<std::mutex> lock(registry->mutex);
    auto it = registry->processes.find(token);
    if (it == registry->processes.end() || it->second->stopped) return VK_ERROR_INITIALIZATION_FAILED;
    return gfxstream::host::vk::VkDecoderGlobalState::get()->acquireCaboosePresentationInstance(
        it->second->context, (VkInstance)(uintptr_t)boxedInstance, out);
}
VkResult acquirePresentationPhysicalDevice(caboose_gfx_registry* registry, uint64_t token,
    uint64_t boxedInstance, uint64_t boxedPhysicalDevice,
    std::unique_ptr<gfxstream::host::vk::CaboosePresentationPhysicalDevice>* out) {
    static_assert(sizeof(uintptr_t) == sizeof(uint64_t), "64-bit boxed Vulkan handles required");
    if (!out) return VK_ERROR_INITIALIZATION_FAILED;
    out->reset();
    if (!registry || !token || !boxedInstance || !boxedPhysicalDevice) return VK_ERROR_INITIALIZATION_FAILED;
    std::lock_guard<std::mutex> lock(registry->mutex);
    auto it = registry->processes.find(token);
    if (it == registry->processes.end() || it->second->stopped) return VK_ERROR_INITIALIZATION_FAILED;
    return gfxstream::host::vk::VkDecoderGlobalState::get()->acquireCaboosePresentationPhysicalDevice(
        it->second->context, (VkInstance)(uintptr_t)boxedInstance,
        (VkPhysicalDevice)(uintptr_t)boxedPhysicalDevice, out);
}
VkResult acquirePresentationDevice(caboose_gfx_registry* registry, uint64_t token,
    uint64_t boxedInstance, uint64_t boxedDevice, uint64_t boxedQueue, uint32_t queueFamily,
    std::unique_ptr<gfxstream::host::vk::CaboosePresentationDevice>* out) {
    static_assert(sizeof(uintptr_t) == sizeof(uint64_t), "64-bit boxed Vulkan handles required");
    if (!out) return VK_ERROR_INITIALIZATION_FAILED;
    out->reset();
    if (!registry || !token || !boxedInstance || !boxedDevice || !boxedQueue)
        return VK_ERROR_INITIALIZATION_FAILED;
    std::lock_guard<std::mutex> lock(registry->mutex);
    auto it = registry->processes.find(token);
    if (it == registry->processes.end() || it->second->stopped) return VK_ERROR_INITIALIZATION_FAILED;
    return gfxstream::host::vk::VkDecoderGlobalState::get()->acquireCaboosePresentationDevice(
        it->second->context, (VkInstance)(uintptr_t)boxedInstance, (VkDevice)(uintptr_t)boxedDevice,
        (VkQueue)(uintptr_t)boxedQueue, queueFamily, out);
}
VkResult acquirePresentationObjects(caboose_gfx_registry* registry,
    uint64_t boxedInstance, const caboose_gpu_present_info& info,
    std::unique_ptr<gfxstream::host::vk::CaboosePresentationObjects>* out) {
    static_assert(sizeof(uintptr_t) == sizeof(uint64_t), "64-bit boxed Vulkan handles required");
    if (!out) return VK_ERROR_INITIALIZATION_FAILED;
    out->reset();
    if (!registry || !info.identity.process_token || !boxedInstance ||
        info.wait_semaphore_count > CABOOSE_GPU_PRESENT_MAX_WAIT_SEMAPHORES ||
        (info.wait_semaphore_count && !info.boxed_wait_semaphores))
        return VK_ERROR_INITIALIZATION_FAILED;
    try {
        std::vector<VkSemaphore> waits;
        waits.reserve(info.wait_semaphore_count);
        for (uint32_t i = 0; i < info.wait_semaphore_count; ++i)
            waits.push_back((VkSemaphore)(uintptr_t)info.boxed_wait_semaphores[i]);
        // Process stop takes this same lock; no new lease can be admitted after
        // stop marks the process dead and schedules upstream cleanup.
        std::lock_guard<std::mutex> lock(registry->mutex);
        auto it = registry->processes.find(info.identity.process_token);
        if (it == registry->processes.end() || it->second->stopped)
            return VK_ERROR_INITIALIZATION_FAILED;
        return gfxstream::host::vk::VkDecoderGlobalState::get()->acquireCaboosePresentationObjects(
            it->second->context, (VkInstance)(uintptr_t)boxedInstance,
            (VkDevice)(uintptr_t)info.boxed_device, (VkQueue)(uintptr_t)info.boxed_queue,
            (VkImage)(uintptr_t)info.boxed_image, (VkFormat)info.vk_format,
            info.width, info.height, info.queue_family,
            info.wait_semaphore_count, waits.data(), out);
    } catch (const std::bad_alloc&) {
        out->reset();
        return VK_ERROR_OUT_OF_HOST_MEMORY;
    }
}
}
#endif
