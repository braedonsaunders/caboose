// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "process_registry.h"
#include "decode_connection.h"
#include "frame_buffer.h"
#include "render_thread_info.h"
#include <atomic>
#include <cerrno>
#include <cstdint>
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
    std::atomic_bool stopped{false};
    std::set<int> sockets;
};
}
struct caboose_gfx_registry {
    std::mutex mutex;
    std::map<uint64_t, std::shared_ptr<Process>> processes;
    std::set<int> activeSockets;
    uint64_t nextContext = 1;
};
extern "C" int caboose_gfx_registry_create(caboose_gfx_registry** out) {
    if (!out) return EINVAL;
    *out = nullptr;
    std::lock_guard<std::mutex> lock(singletonMutex);
    if (registryExists) return EBUSY;
    if (!FrameBuffer::getFB() || !FrameBuffer::getFB()->hasEmulationVk()) return ENODEV;
    try { *out = new caboose_gfx_registry; } catch (const std::bad_alloc&) { return ENOMEM; }
    registryExists = true;
    return 0;
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
extern "C" int caboose_gfx_process_run(caboose_gfx_registry* registry, uint64_t puid, int fd,
                                       size_t max_packet, size_t max_reply_buffer) {
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
            int result = caboose::gpuv2::decodeConnection(fd, max_packet, max_reply_buffer,
                                                           threadInfo, process->stopped);
            // Decoder work has ended. Clear the TLS identities while admission is locked;
            // the TLS object is destroyed before that lock is released.
            lock.lock();
            threadInfo.setProcessResources(nullptr);
            threadInfo.setPuid(0);
            process->sockets.erase(fd);
            registry->activeSockets.erase(fd);
            return result;
        } catch (...) {
            if (!lock.owns_lock()) lock.lock();
            process->sockets.erase(fd);
            registry->activeSockets.erase(fd);
            throw;
        }
    } catch (const std::bad_alloc&) { return ENOMEM; }
      catch (...) { return EIO; }
}
extern "C" int caboose_gfx_process_stop(caboose_gfx_registry* registry, uint64_t puid) {
    if (!registry) return EINVAL;
    std::lock_guard<std::mutex> lock(registry->mutex);
    auto it = registry->processes.find(puid);
    if (it == registry->processes.end()) return ENOENT;
    auto& process = *it->second;
    if (process.stopped.exchange(true)) return 0;
    FrameBuffer::getFB()->signalGuestProcessDead(process.context);
    for (int fd : process.sockets) shutdown(fd, SHUT_RDWR);
    return 0;
}
extern "C" int caboose_gfx_process_finish(caboose_gfx_registry* registry, uint64_t puid) {
    if (!registry) return EINVAL;
    std::lock_guard<std::mutex> lock(registry->mutex);
    auto it = registry->processes.find(puid);
    if (it == registry->processes.end()) return ENOENT;
    if (!it->second->stopped || !it->second->sockets.empty()) return EBUSY;
    // Upstream retains the resources in its asynchronous cleanup closure. IDs
    // are not reused while that cleanup may still be running.
    registry->processes.erase(it);
    return 0;
}
