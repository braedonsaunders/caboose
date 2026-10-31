// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// Real provider and generated decoder, under an external watchdog.
#include "native_runtime.h"
#include "decode_diagnostic.h"
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <dlfcn.h>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>
namespace {
void* loader = nullptr;
void* resolve(const char* name) { return dlsym(loader, name); }
bool transfer(int fd, void* data, size_t size, bool write) {
    auto* p = static_cast<unsigned char*>(data);
    while (size) {
        ssize_t n = write ? send(fd, p, size, 0) : recv(fd, p, size, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        p += n; size -= static_cast<size_t>(n);
    }
    return true;
}
bool run(uint32_t opcode) {
    uint64_t token = 0;
    if (caboose_gpu_runtime_open(&token)) return false;
    int fd[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fd)) return false;
    uint64_t entries = 0; int result = EIO;
    caboose::gpuv2::DecodeDiagnostic diagnostic;
    std::thread worker([&] {
        result = caboose_gpu_runtime_run_counted(token, fd[1], 65536, 65536, &entries);
        diagnostic = caboose::gpuv2::lastDecodeDiagnosticForTesting();
    });
    uint32_t flags = 0;
    uint32_t query[] = {20137, 12, 0}; // real vkEnumerateInstanceVersion
    uint32_t reply[2] = {};
    bool ok = transfer(fd[0], &flags, sizeof(flags), true) &&
              transfer(fd[0], query, sizeof(query), true) &&
              transfer(fd[0], reply, sizeof(reply), false) &&
              reply[0] >= VK_API_VERSION_1_0 && reply[1] == VK_SUCCESS;
    // The packet body is intentionally absent. If admitted, the generated
    // decoder entry counter changes; the profile must reject after the header.
    uint32_t forbidden[] = {opcode, 8};
    if (ok) ok = transfer(fd[0], forbidden, sizeof(forbidden), true);
    shutdown(fd[0], SHUT_WR);
    if (!ok) shutdown(fd[0], SHUT_RDWR);
    worker.join(); close(fd[0]); close(fd[1]);
    const int stop = caboose_gpu_runtime_stop(token);
    const int finish = stop ? stop : caboose_gpu_runtime_finish(token);
    if (!ok || result != ENOTSUP || entries != 1 || finish ||
        diagnostic.stage != caboose::gpuv2::DecodeStage::profile ||
        !diagnostic.headerPresent || diagnostic.opcode != opcode || diagnostic.declared != 8 ||
        diagnostic.lastOpcode != 20137 || diagnostic.completed != 1) {
        std::fprintf(stderr, "opcode %u: io=%d result=%d decoder_entries=%llu cleanup=%d\n",
                     opcode, ok, result, static_cast<unsigned long long>(entries), finish);
        return false;
    }
    return true;
}
}
int main(int argc, char** argv) {
    if (argc != 2) return 2;
    loader = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!loader) return 2;
    auto get = reinterpret_cast<PFN_vkGetInstanceProcAddr>(resolve("vkGetInstanceProcAddr"));
    if (!get || caboose_gpu_runtime_start_v4(get, resolve)) return 1;
    constexpr uint32_t restricted[] = {
#include "v4-forbidden-opcodes.inc"
    };
    for (uint32_t opcode : restricted) if (!run(opcode)) return 1;
    std::printf("real decoder rejected %zu restricted opcodes before entry\n", sizeof(restricted) / sizeof(restricted[0]));
    return 0;
}
