// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// Real decoder/provider socketpair regression. Run under an external watchdog.
#include "native_runtime.h"
#include "socket_stream.h"
#include "decode_diagnostic.h"
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>

namespace {
void* loader;
void* resolve(const char* name) { return dlsym(loader, name); }
bool sendAll(int fd, const void* bytes, size_t size) {
    auto* p = static_cast<const unsigned char*>(bytes);
    while (size) {
#ifdef MSG_NOSIGNAL
        ssize_t n = send(fd, p, size, MSG_NOSIGNAL);
#else
        ssize_t n = send(fd, p, size, 0);
#endif
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        p += n; size -= static_cast<size_t>(n);
    }
    return true;
}
bool readAll(int fd, void* bytes, size_t size) {
    auto* p = static_cast<unsigned char*>(bytes);
    while (size) {
        ssize_t n = recv(fd, p, size, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        p += n; size -= static_cast<size_t>(n);
    }
    return true;
}
bool runCase(const char* label, size_t flagsBytes, size_t packetBytes,
             int expected, bool expectReply, bool rejectReply = false) {
    uint64_t token = 0;
    if (caboose_gpu_runtime_open(&token)) return false;
    int fd[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fd)) return false;
#ifdef SO_NOSIGPIPE
    int one = 1;
    if (setsockopt(fd[0], SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one))) return false;
#endif
    uint32_t flags = 0;
    // Pinned vkEnumerateInstanceVersion generated schema: opcode, total packet
    // length, then uint32 output storage; response is uint32 version + VkResult.
    const uint32_t packet[] = {20137, 12, 0};
    bool ok = sendAll(fd[0], &flags, flagsBytes);
    ok = ok && sendAll(fd[0], packet, packetBytes);
    ok = ok && shutdown(fd[0], SHUT_WR) == 0;
    if (rejectReply) { close(fd[0]); fd[0] = -1; }
    int result = EIO;
    caboose::gpuv2::DecodeDiagnostic diagnostic;
    std::thread worker([&] {
        result = caboose_gpu_runtime_run(token, fd[1], 65536, 65536);
        diagnostic = caboose::gpuv2::lastDecodeDiagnosticForTesting();
    });
    if (expectReply) {
        uint32_t reply[2] = {};
        ok = ok && readAll(fd[0], reply, sizeof(reply));
        ok = ok && reply[0] >= VK_API_VERSION_1_0 && reply[1] == VK_SUCCESS;
    }
    if (!ok && fd[0] >= 0) shutdown(fd[0], SHUT_RDWR);
    worker.join();
    if (fd[0] >= 0) close(fd[0]);
    close(fd[1]);
    const int stop = caboose_gpu_runtime_stop(token);
    const int finish = stop ? stop : caboose_gpu_runtime_finish(token);
#ifdef __APPLE__
    bool matched = rejectReply ? result == EINVAL : result == expected;
#else
    bool matched = rejectReply ? (result == EPIPE || result == ECONNRESET) : result == expected;
#endif
    using caboose::gpuv2::DecodeStage;
    bool metadata = rejectReply ?
        ((diagnostic.stage == DecodeStage::decoder || diagnostic.stage == DecodeStage::flush) &&
         diagnostic.headerPresent && diagnostic.opcode == 20137 && diagnostic.socketError != 0) :
        flagsBytes < 4 ? diagnostic.stage == DecodeStage::flags && diagnostic.eof :
        diagnostic.stage == DecodeStage::eof && diagnostic.eof &&
        diagnostic.headerPresent == (packetBytes >= 8 && packetBytes < 12);
    if (expectReply) metadata = metadata && diagnostic.lastOpcode == 20137 && diagnostic.completed == 1;
    if (!ok || !matched || finish || !metadata) {
        std::fprintf(stderr, "%s result=%d expected=%d cleanup=%d io=%d\n",
                     label, result, expected, finish, ok);
        return false;
    }
    std::printf("%s passed (result=%d)\n", label, result);
    return true;
}
}
int main(int argc, char** argv) {
    if (argc != 2) return 2;
    loader = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!loader) return 2;
    auto get = reinterpret_cast<PFN_vkGetInstanceProcAddr>(resolve("vkGetInstanceProcAddr"));
    if (!get || caboose_gpu_runtime_start(get, resolve)) return 1;
    for (size_t n = 0; n < sizeof(uint32_t); ++n)
        if (!runCase("truncated flags", n, 0, EPROTO, false)) return 1;
    if (!runCase("EOF after flags", 4, 0, 0, false)) return 1;
    for (size_t n = 1; n < 12; ++n)
        if (!runCase("truncated header/body", 4, n, EPROTO, false)) return 1;
    if (!runCase("query then EOF and reply", 4, 12, 0, true)) return 1;
    if (!runCase("closed peer before decoder entry", 4, 12, 0, false, true)) return 1;
    int fd[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fd)) return 1;
    caboose::gpuv2::SocketStream stream(fd[1], 4096);
    if (stream.error()) return 1;
    close(fd[0]);
    const uint32_t reply = 1;
    const int writeResult = stream.writeFully(&reply, sizeof(reply));
    const int writeError = stream.error();
    close(fd[1]);
    if (writeResult != -1 || (writeError != EPIPE && writeError != ECONNRESET)) {
        std::fprintf(stderr, "closed peer write result=%d errno=%d\n", writeResult, writeError);
        return 1;
    }
    std::printf("closed peer write failed (errno=%d)\n", writeError);
    // Provider remains loaded for process lifetime.
    return 0;
}
