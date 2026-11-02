// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// The Linux executor's counterpart of the phone's caboose_gpu_live_start_v4: the phone links
// MoltenVK statically, this opens the system Vulkan loader once for the process lifetime.
#include "native_runtime.h"
#include <cerrno>
#include <cstdio>
#include <dlfcn.h>
#include <mutex>

namespace {
std::mutex mutex;
void* loader = nullptr;
void* resolve(const char* name) { return loader ? dlsym(loader, name) : nullptr; }
}

extern "C" __attribute__((visibility("default"))) int caboose_gpu_executor_start(const char* loader_path) {
    std::lock_guard<std::mutex> lock(mutex);
    if (!loader) {
        loader = dlopen(loader_path && *loader_path ? loader_path : "libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
        if (!loader) {
            std::fprintf(stderr, "caboose-executor: dlopen: %s\n", dlerror());
            return ENOENT;
        }
    }
    auto get = reinterpret_cast<PFN_vkGetInstanceProcAddr>(resolve("vkGetInstanceProcAddr"));
    if (!get) return ENOTSUP;
    return caboose_gpu_runtime_start_v4(get, resolve);
}
