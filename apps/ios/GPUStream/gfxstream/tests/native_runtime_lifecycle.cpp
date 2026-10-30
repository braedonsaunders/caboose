// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// Real backend lifecycle smoke check. The caller supplies a real Vulkan provider.
#include "native_runtime.h"
#include <cerrno>
#include <cstdio>
#include <dlfcn.h>
#include <thread>
#include <sys/socket.h>
#include <unistd.h>

namespace {
void* loader;
void* resolve(const char* name) { return dlsym(loader, name); }
bool check(const char* step, int actual, int expected) {
    if (actual == expected) return true;
    std::fprintf(stderr, "%s: got %d expected %d\n", step, actual, expected);
    return false;
}
}
int main(int argc, char** argv) {
    if (argc != 2) return 2;
    loader = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!loader) return 2;
    auto get = reinterpret_cast<PFN_vkGetInstanceProcAddr>(resolve("vkGetInstanceProcAddr"));
    if (!get || !check("start", caboose_gpu_runtime_start(get, resolve), 0) ||
        !check("repeat start", caboose_gpu_runtime_start(get, resolve), 0)) return 1;
    uint64_t first = 0, second = 0, third = 0;
    if (!check("first open", caboose_gpu_runtime_open(&first), 0) ||
        !check("second open", caboose_gpu_runtime_open(&second), 0) ||
        !first || !second || first == second) return 1;
    if (!check("finish before stop", caboose_gpu_runtime_finish(first), EBUSY) ||
        !check("stop first", caboose_gpu_runtime_stop(first), 0) ||
        !check("repeat stop", caboose_gpu_runtime_stop(first), 0) ||
        !check("finish first", caboose_gpu_runtime_finish(first), 0) ||
        !check("finished first", caboose_gpu_runtime_stop(first), ENOENT) ||
        !check("third open", caboose_gpu_runtime_open(&third), 0) ||
        !third || third == first || third == second) return 1;
    int fd[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fd)) return 1;
    int runResult = EIO;
    std::thread runner([&] { runResult = caboose_gpu_runtime_run(second, fd[0], 65536, 65536); });
    // Stop is safe whether or not the worker has reached admission. Join before
    // closing either caller-owned descriptor and before finishing the session.
    int stopResult = caboose_gpu_runtime_stop(second);
    runner.join();
    close(fd[0]); close(fd[1]);
    if (!check("stop second", stopResult, 0) ||
        !(runResult == 0 || runResult == ECANCELED) ||
        !check("finish second", caboose_gpu_runtime_finish(second), 0) ||
        !check("stop third", caboose_gpu_runtime_stop(third), 0) ||
        !check("finish third", caboose_gpu_runtime_finish(third), 0)) return 1;
    // Deliberately keep the single provider loaded until process exit.
    std::puts("real process lifetime lifecycle passed");
    return 0;
}
