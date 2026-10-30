// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// Manual fixture: real gfxstream framebuffer and a supplied Vulkan loader.
// It does not send a Vulkan command or establish coherent-memory correctness.
#include "headless_framebuffer.h"
#include "process_registry.h"
#include "vulkan_dispatch.h"
#include "gfxstream/host/features.h"
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <dlfcn.h>
#include <sys/socket.h>
#include <unistd.h>

namespace {
void* loader;
void* resolve(const char* name) { return dlsym(loader, name); }
bool expect(const char* what, int actual, int expected) {
    if (actual == expected) return true;
    std::fprintf(stderr, "%s: got %d, expected %d\n", what, actual, expected);
    return false;
}
}
int main(int argc, char** argv) {
    if (argc != 2) { std::fprintf(stderr, "usage: %s /absolute/path/to/vulkan-loader.so\n", argv[0]); return 2; }
    loader = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!loader) { std::fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    auto get = reinterpret_cast<PFN_vkGetInstanceProcAddr>(resolve("vkGetInstanceProcAddr"));
    if (!get || !gfxstream::host::vk::installVulkanLoader(get, resolve)) {
        std::fprintf(stderr, "could not install the supplied Vulkan loader\n"); return 1;
    }
    gfxstream::host::FeatureSet features;
    features.Vulkan.setEnabled(true);
    features.GuestVulkanOnly.setEnabled(true);
    features.GlDirectMem.setEnabled(false);
    features.VirtioGpuNext.setEnabled(false);
    features.ExternalBlob.setEnabled(false);
    features.VulkanSnapshots.setEnabled(false);
    features.VulkanNativeSwapchain.setEnabled(false);
    features.VulkanNullOptionalStrings.setEnabled(true);
    if (!caboose::gpuv2::initializeHeadlessFramebuffer(features)) {
        std::fprintf(stderr, "real gfxstream framebuffer initialization failed\n"); return 1;
    }
    bool ok = true;
    caboose_gfx_registry* registry = nullptr;
    int result = caboose_gfx_registry_create(&registry);
    if (result) { std::fprintf(stderr, "registry create: %d\n", result); caboose::gpuv2::finalizeHeadlessFramebuffer(); return 1; }
    constexpr uint64_t first = 1, second = (uint64_t{1} << 32) | 1;
    ok &= expect("open first", caboose_gfx_process_open(registry, first), 0);
    ok &= expect("open second", caboose_gfx_process_open(registry, second), 0);
    ok &= expect("duplicate", caboose_gfx_process_open(registry, first), EEXIST);
    int sockets[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) != 0) {
        std::perror("socketpair"); ok = false;
    } else {
        const uint32_t flags = 0;
        const ssize_t sent = write(sockets[0], &flags, sizeof(flags));
        if (sent != sizeof(flags)) { std::perror("write flags"); ok = false; }
        shutdown(sockets[0], SHUT_WR);
        ok &= expect("decode EOF", caboose_gfx_process_run(registry, first, sockets[1], 65536, 65536), 0);
        close(sockets[0]); close(sockets[1]);
    }
    ok &= expect("stop first", caboose_gfx_process_stop(registry, first), 0);
    ok &= expect("finish first", caboose_gfx_process_finish(registry, first), 0);
    ok &= expect("stop second", caboose_gfx_process_stop(registry, second), 0);
    ok &= expect("finish second", caboose_gfx_process_finish(registry, second), 0);
    result = caboose_gfx_registry_destroy(registry);
    ok &= expect("destroy", result, 0);
    if (result == 0) caboose::gpuv2::finalizeHeadlessFramebuffer();
    // Keep loader alive for process lifetime: the upstream dispatch singleton owns pointers.
    if (ok) std::puts("real framebuffer, socket EOF, and process cleanup passed");
    return ok ? 0 : 1;
}
