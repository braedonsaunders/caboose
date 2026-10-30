// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// Private, single-connection diagnostic. Not a production listener.
#include "headless_framebuffer.h"
#include "process_registry.h"
#include "vulkan_dispatch.h"
#include "gfxstream/host/features.h"
#include "frame_buffer.h"
#include <array>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

namespace {
void* loader;
void* resolve(const char* name) { return dlsym(loader, name); }
bool transfer(int fd, void* data, size_t n, bool writing) {
    auto* p = static_cast<unsigned char*>(data);
    while (n) {
        ssize_t count = writing ? send(fd, p, n, MSG_NOSIGNAL) : recv(fd, p, n, 0);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return false;
        p += count; n -= static_cast<size_t>(count);
    }
    return true;
}
}
int main(int argc, char** argv) {
#if __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error This diagnostic protocol requires a little endian host
#endif
    if (argc != 3) { std::fprintf(stderr, "usage: %s loader private-directory\n", argv[0]); return 2; }
    struct stat st{};
    if (lstat(argv[2], &st) || !S_ISDIR(st.st_mode) || st.st_uid != geteuid() || (st.st_mode & 0777) != 0700) {
        std::fprintf(stderr, "private directory must be owned by this uid and mode 0700\n"); return 1;
    }
    sockaddr_un addr{}; addr.sun_family = AF_UNIX;
    if (std::snprintf(addr.sun_path, sizeof(addr.sun_path), "%s/decoder.sock", argv[2]) >= (int)sizeof(addr.sun_path)) return 1;
    loader = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!loader) { std::fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    auto get = reinterpret_cast<PFN_vkGetInstanceProcAddr>(resolve("vkGetInstanceProcAddr"));
    if (!get || !gfxstream::host::vk::installVulkanLoader(get, resolve)) return 1;
    gfxstream::host::FeatureSet features;
    features.Vulkan.setEnabled(true); features.GuestVulkanOnly.setEnabled(true);
    features.GlDirectMem.setEnabled(false); features.VirtioGpuNext.setEnabled(false);
    features.ExternalBlob.setEnabled(false); features.VulkanSnapshots.setEnabled(false);
    features.VulkanNativeSwapchain.setEnabled(false); features.VulkanQueueSubmitWithCommands.setEnabled(false);
    features.VulkanNullOptionalStrings.setEnabled(true);
    if (!caboose::gpuv2::initializeHeadlessFramebuffer(features)) return 1;
    const auto& actual = gfxstream::host::FrameBuffer::getFB()->getFeatures();
    bool ok = !actual.VulkanQueueSubmitWithCommands.enabled() && !actual.GlDirectMem.enabled() &&
              !actual.VirtioGpuNext.enabled() && !actual.ExternalBlob.enabled() &&
              actual.VulkanNullOptionalStrings.enabled();
    caboose_gfx_registry* registry = nullptr;
    if (!ok || caboose_gfx_registry_create(&registry)) { caboose::gpuv2::finalizeHeadlessFramebuffer(); return 1; }
    constexpr uint64_t process = 1;
    ok = caboose_gfx_process_open(registry, process) == 0;
    int server = -1, client = -1; bool bound = false;
    if (ok) server = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (server < 0) ok = false;
    if (ok && bind(server, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0) bound = true;
    else ok = false;
    if (ok && listen(server, 1) == 0) {
        std::printf("ready %s\n", addr.sun_path); std::fflush(stdout);
        pollfd pfd{server, POLLIN, 0};
        if (poll(&pfd, 1, 20000) > 0) client = accept4(server, nullptr, nullptr, SOCK_CLOEXEC);
    }
    if (client < 0) ok = false;
    if (ok) {
        ucred peer{}; socklen_t len = sizeof(peer);
        timeval timeout{5, 0};
        ok = getsockopt(client, SOL_SOCKET, SO_PEERCRED, &peer, &len) == 0 && peer.uid == geteuid() &&
             setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0 &&
             setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) == 0;
    }
    std::array<unsigned char, 48> expected = {'C','B','G','L','R','E','F','1',2,0,0,0,0x10,0,0,0,
        0x20,0xd3,0xbb,0x2e,0x30,0x33,0x7c,0xab,0xf0,0xfe,0xbb,0x00,0x6e,0xd1,0x02,0xab,
        0x25,0xcc,0xf6,0xd9,0xdd,0xbf,0xaf,0x62,0x4c,0x7e,0x68,0xf9,0x04,0x09,0x69,0xc0};
    std::array<unsigned char, 48> hello{};
    if (ok) ok = transfer(client, hello.data(), hello.size(), false) && hello == expected &&
                 transfer(client, expected.data(), expected.size(), true);
    if (ok) {
        int result = caboose_gfx_process_run(registry, process, client, 65536, 65536);
        std::printf("decoder returned %d\n", result);
        ok = result == ECONNRESET;
    } else std::fprintf(stderr, "connection or private handshake rejected\n");
    if (client >= 0) close(client);
    if (server >= 0) close(server);
    if (bound) unlink(addr.sun_path);
    if (caboose_gfx_process_stop(registry, process) != 0) ok = false;
    if (caboose_gfx_process_finish(registry, process) != 0) ok = false;
    int destroyed = caboose_gfx_registry_destroy(registry);
    if (destroyed == 0) caboose::gpuv2::finalizeHeadlessFramebuffer(); else ok = false;
    return ok ? 0 : 1;
}
