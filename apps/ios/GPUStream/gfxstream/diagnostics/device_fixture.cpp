// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "device_fixture.h"
#include "headless_framebuffer.h"
#include "process_registry.h"
#include "vulkan_dispatch.h"
#include "frame_buffer.h"
#include "gfxstream/host/features.h"
#include <array>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <mutex>
#include <new>
#include <set>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

namespace {
// Packet cap includes framing and range metadata around the 64 KiB guest data cap.
constexpr size_t kMaxPacket = 256 * 1024;
constexpr std::array<uint8_t, 48> kHello = {
    'C','B','G','L','R','E','F','1', 1,0,0,0, 0,0,0,0,
    0x20,0xd3,0xbb,0x2e,0x30,0x33,0x7c,0xab,0xf0,0xfe,0xbb,0x00,0x6e,0xd1,0x02,0xab,
    0x25,0xcc,0xf6,0xd9,0xdd,0xbf,0xaf,0x62,0x4c,0x7e,0x68,0xf9,0x04,0x09,0x69,0xc0,
};
std::mutex lifecycleMutex;
bool lifecycleClaimed = false;
int transfer(int fd, uint8_t* bytes, size_t len, bool writing,
             std::chrono::steady_clock::time_point deadline) {
    while (len) {
        const auto now = std::chrono::steady_clock::now();
        if (now >= deadline) return ETIMEDOUT;
        const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now);
        const int wait = static_cast<int>(remaining.count() > 0 ? remaining.count() : 1);
        pollfd pfd{fd, static_cast<short>(writing ? POLLOUT : POLLIN), 0};
        int ready = poll(&pfd, 1, wait);
        if (ready < 0 && errno == EINTR) continue;
        if (ready < 0) return errno;
        if (ready == 0) return ETIMEDOUT;
        if (pfd.revents & POLLNVAL) return EBADF;
        ssize_t n = writing ? send(fd, bytes, len, MSG_DONTWAIT) : recv(fd, bytes, len, MSG_DONTWAIT);
        if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (n <= 0) return n == 0 ? ECONNRESET : errno;
        bytes += n; len -= static_cast<size_t>(n);
    }
    return 0;
}
}
struct caboose_gpu_diagnostic {
    std::array<uint8_t, 16> session;
    uint64_t generation;
    uint64_t process;
    caboose_gfx_registry* registry = nullptr;
    std::mutex mutex;
    std::set<int> streams;
    bool stopping = false;
    int stopResult = 0;
};
extern "C" int caboose_gpu_diagnostic_start(const uint8_t session_id[16], uint64_t generation,
                                             uint64_t process_id, PFN_vkGetInstanceProcAddr get,
                                             caboose_gpu_resolve_export resolve,
                                             caboose_gpu_diagnostic** out) {
    if (!session_id || !generation || !process_id || !get || !resolve || !out) return EINVAL;
    *out = nullptr;
    bool nonzero = false;
    for (size_t i = 0; i < 16; ++i) nonzero |= session_id[i] != 0;
    if (!nonzero) return EINVAL;
    std::lock_guard<std::mutex> lock(lifecycleMutex);
    if (lifecycleClaimed) return EBUSY;
    auto* d = new (std::nothrow) caboose_gpu_diagnostic;
    if (!d) return ENOMEM;
    std::memcpy(d->session.data(), session_id, d->session.size());
    d->generation = generation; d->process = process_id;
    // The upstream dispatch singleton cannot be reset or replaced. Claim this
    // lifetime even if initialization fails; start a new process to retry.
    lifecycleClaimed = true;
    if (!gfxstream::host::vk::installVulkanLoader(get, resolve)) { delete d; return EBUSY; }
    gfxstream::host::FeatureSet features;
    features.Vulkan.setEnabled(true);
    features.GuestVulkanOnly.setEnabled(true);
    features.GlDirectMem.setEnabled(false);
    features.VirtioGpuNext.setEnabled(false);
    features.ExternalBlob.setEnabled(false);
    features.VulkanSnapshots.setEnabled(false);
    features.VulkanNativeSwapchain.setEnabled(false);
    features.VulkanQueueSubmitWithCommands.setEnabled(false);
    if (!caboose::gpuv2::initializeHeadlessFramebuffer(features)) { delete d; return EIO; }
    const auto& actual = gfxstream::host::FrameBuffer::getFB()->getFeatures();
    if (actual.GlDirectMem.enabled() || actual.VirtioGpuNext.enabled() ||
        actual.ExternalBlob.enabled() || actual.VulkanQueueSubmitWithCommands.enabled()) {
        caboose::gpuv2::finalizeHeadlessFramebuffer(); delete d; return EPROTO;
    }
    int result = caboose_gfx_registry_create(&d->registry);
    if (!result) result = caboose_gfx_process_open(d->registry, process_id);
    if (result) {
        if (d->registry) caboose_gfx_registry_destroy(d->registry);
        caboose::gpuv2::finalizeHeadlessFramebuffer(); delete d; return result;
    }
    *out = d;
    return 0;
}
extern "C" int caboose_gpu_diagnostic_identity(const caboose_gpu_diagnostic* d,
                                                uint8_t session_id[16], uint64_t* generation,
                                                uint64_t* process_id) {
    if (!d || !session_id || !generation || !process_id) return EINVAL;
    std::memcpy(session_id, d->session.data(), d->session.size());
    *generation = d->generation;
    *process_id = d->process;
    return 0;
}
extern "C" int caboose_gpu_diagnostic_run(caboose_gpu_diagnostic* d, int fd, uint32_t timeout_ms) {
    if (!d || fd < 0 || !timeout_ms || timeout_ms > 60000) return EINVAL;
    {
        std::lock_guard<std::mutex> lock(d->mutex);
        if (d->stopping) return ECANCELED;
        try { if (!d->streams.insert(fd).second) return EBUSY; }
        catch (const std::bad_alloc&) { return ENOMEM; }
    }
    int error = 0;
#ifdef SO_NOSIGPIPE
    int one = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)) != 0) error = errno;
#endif
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
    std::array<uint8_t, kHello.size()> hello{};
    if (!error) error = transfer(fd, hello.data(), hello.size(), false, deadline);
    if (!error && hello != kHello) error = EPROTO;
    if (!error) error = transfer(fd, hello.data(), hello.size(), true, deadline);
    if (!error) error = caboose_gfx_process_run(d->registry, d->process, fd, kMaxPacket, kMaxPacket);
    if (error) shutdown(fd, SHUT_RDWR);
    {
        std::lock_guard<std::mutex> lock(d->mutex);
        d->streams.erase(fd);
    }
    return error;
}
extern "C" int caboose_gpu_diagnostic_stop(caboose_gpu_diagnostic* d) {
    if (!d) return EINVAL;
    std::lock_guard<std::mutex> lock(d->mutex);
    if (d->stopping) return d->stopResult;
    d->stopping = true;
    for (int fd : d->streams) shutdown(fd, SHUT_RDWR);
    d->stopResult = caboose_gfx_process_stop(d->registry, d->process);
    return d->stopResult;
}
extern "C" int caboose_gpu_diagnostic_finish(caboose_gpu_diagnostic* d) {
    if (!d) return EINVAL;
    {
        std::lock_guard<std::mutex> lock(d->mutex);
        if (!d->stopping || !d->streams.empty()) return EBUSY;
    }
    int error = caboose_gfx_process_finish(d->registry, d->process);
    if (error) return error;
    error = caboose_gfx_registry_destroy(d->registry);
    if (error) return error;
    caboose::gpuv2::finalizeHeadlessFramebuffer();
    delete d;
    return 0;
}
