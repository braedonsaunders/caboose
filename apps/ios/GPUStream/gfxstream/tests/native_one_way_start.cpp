// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// One-way start against the real decoder (README.md, "One-way start"). Run under an external
// watchdog with the Vulkan loader to use:
//
//   caboose_gpu_native_one_way_start LOADER
//
// A process's device stream sends REPLY_MODE(3) and then, without reading anything:
//   1. vkCreateInstance with an extension no driver has, under a guest-assigned handle: it fails,
//      and the process's completion feed carries a FAULT record (opcode 20000, its VkResult);
//   2. vkCreateInstance; a vkEnumeratePhysicalDevices naming two physical devices where there is
//      one (a FAULT, opcode 20002, VK_ERROR_INITIALIZATION_FAILED) and one naming the one; a
//      vkCreateDevice asking family 0 for one queue more than it has, which fails without
//      reaching the driver (a FAULT, opcode 20011, VK_ERROR_INITIALIZATION_FAILED); then
//      vkCreateDevice and vkGetDeviceQueue2, every handle the guest's own: the rest succeed and
//      write nothing;
//   3. vkQueueWaitIdle on the guest's queue and vkEnumerateInstanceVersion, whose replies are the
//      only bytes the stream reads back, then vkDestroyDevice and vkDestroyInstance by the guest's
//      handles. A handle the decoder did not take would end the stream as invalid guest input.
#include "completion_feed.h"
#include "native_runtime.h"
#include "silent_replies.h"
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <string>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>
#include <vector>

namespace {
void* loader;
void* resolve(const char* name) { return dlsym(loader, name); }
bool sendAll(int fd, const void* bytes, size_t size) {
    auto* p = static_cast<const unsigned char*>(bytes);
    while (size) {
        ssize_t n = send(fd, p, size, MSG_NOSIGNAL);
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

// A command packet as the guest's encoder writes it: opcode, total size, then the body.
struct Packet {
    std::vector<unsigned char> body;
    void u32(uint32_t v) { body.insert(body.end(), (unsigned char*)&v, (unsigned char*)&v + 4); }
    void u64(uint64_t v) { body.insert(body.end(), (unsigned char*)&v, (unsigned char*)&v + 8); }
    void be32(uint32_t v) { for (int i = 3; i >= 0; --i) body.push_back((unsigned char)(v >> (8 * i))); }
    void be64(uint64_t v) { for (int i = 7; i >= 0; --i) body.push_back((unsigned char)(v >> (8 * i))); }
    void f32(float v) { body.insert(body.end(), (unsigned char*)&v, (unsigned char*)&v + 4); }
    // A string array: its count, then each string's length and bytes (big-endian lengths).
    void strings(const std::vector<std::string>& values) {
        u32((uint32_t)values.size());
        be32((uint32_t)values.size());
        for (const auto& s : values) {
            be32((uint32_t)s.size());
            body.insert(body.end(), s.begin(), s.end());
        }
    }
    std::vector<unsigned char> finish(uint32_t opcode) const {
        std::vector<unsigned char> out;
        const uint32_t size = (uint32_t)(body.size() + 8);
        out.insert(out.end(), (unsigned char*)&opcode, (unsigned char*)&opcode + 4);
        out.insert(out.end(), (unsigned char*)&size, (unsigned char*)&size + 4);
        out.insert(out.end(), body.begin(), body.end());
        return out;
    }
};

std::vector<unsigned char> createInstance(uint64_t handle, const std::vector<std::string>& extensions) {
    Packet p;
    p.u32(1);  // VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
    p.be32(0); // no pNext
    p.u32(0);  // flags
    // An application info asking for Vulkan 1.1, as every guest's does: the decoder finds its
    // physical devices through properties only 1.1 instances have.
    p.be64(1);
    p.u32(0);  // VK_STRUCTURE_TYPE_APPLICATION_INFO
    p.be32(0);
    // The decoder's stream has null optional strings: each name is a pointer, here null.
    p.be64(0); p.u32(0);  // pApplicationName, applicationVersion
    p.be64(0); p.u32(0);  // pEngineName, engineVersion
    p.u32((1u << 22) | (1u << 12));  // VK_API_VERSION_1_1
    p.strings({});
    p.strings(extensions);
    p.be64(0); // no pAllocator
    p.u64(handle);
    return p.finish(20000);
}
std::vector<unsigned char> enumeratePhysicalDevices(uint64_t instance, const std::vector<uint64_t>& handles) {
    Packet p;
    p.u64(instance);
    p.be64(1); p.u32((uint32_t)handles.size());  // pPhysicalDeviceCount
    p.be64(1);                                    // pPhysicalDevices
    for (uint64_t h : handles) p.u64(h);
    return p.finish(20002);
}
std::vector<unsigned char> createDevice(uint64_t physicalDevice, uint64_t handle, uint32_t queues = 1) {
    Packet p;
    p.u64(physicalDevice);
    p.u32(3);  // VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
    p.be32(0);
    p.u32(0);  // flags
    p.u32(1);  // one queue create info
    p.u32(2);  // VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
    p.be32(0);
    p.u32(0); p.u32(0); p.u32(queues);  // flags, family 0, its queues
    for (uint32_t q = 0; q < queues; ++q) p.f32(1.0f);
    p.strings({});
    p.strings({});
    p.be64(0);  // no pEnabledFeatures
    p.be64(0);  // no pAllocator
    p.u64(handle);
    return p.finish(20011);
}
std::vector<unsigned char> getDeviceQueue2(uint64_t device, uint64_t handle) {
    Packet p;
    p.u64(device);
    p.u32(1000145003);  // VK_STRUCTURE_TYPE_DEVICE_QUEUE_INFO_2
    p.be32(0);
    p.u32(0); p.u32(0); p.u32(0);  // flags, family 0, queue 0
    p.u64(handle);
    return p.finish(20155);
}
std::vector<unsigned char> queueWaitIdle(uint64_t queue) { Packet p; p.u64(queue); return p.finish(20019); }
std::vector<unsigned char> destroy(uint32_t opcode, uint64_t handle) {
    Packet p; p.u64(handle); p.be64(0); return p.finish(opcode);
}
}  // namespace

int main(int argc, char** argv) {
    if (argc != 2) return 2;
    loader = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!loader) return 2;
    auto get = reinterpret_cast<PFN_vkGetInstanceProcAddr>(resolve("vkGetInstanceProcAddr"));
    if (!get || caboose_gpu_runtime_start(get, resolve)) return 1;
    uint64_t token = 0;
    if (caboose_gpu_runtime_open(&token)) return 1;
    using caboose::gpuv2::CompletionFeed;
    namespace sr = caboose::gpuv2::silent_replies;

    // The process's completion feed.
    int feed[2], device[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, feed) || socketpair(AF_UNIX, SOCK_STREAM, 0, device)) return 1;
    int feedResult = EIO, deviceResult = EIO;
    std::thread feedThread([&] { feedResult = caboose_gpu_runtime_run(token, feed[1], 65536, 65536); });
    const uint32_t flags = 0;
    const uint32_t feedPacket[4] = {CompletionFeed::kFeedOpcode, CompletionFeed::kFeedPacketSize,
                                    CompletionFeed::kFeedVersion, 0};
    bool ok = sendAll(feed[0], &flags, 4) && sendAll(feed[0], feedPacket, sizeof(feedPacket));

    // A decoder that ends the stream early closes it, so the reads below fail instead of waiting.
    std::thread deviceThread([&] {
        deviceResult = caboose_gpu_runtime_run(token, device[1], 1 << 20, 1 << 20);
        shutdown(device[1], SHUT_RDWR);
    });
    const uint64_t failed = 0xCA0000AB00000001ull, instance = 0xCA0000AB00000002ull,
                   physical = 0xCA0000AB00000003ull, other = 0xCA0000AB00000004ull,
                   logical = 0xCA0000AB00000005ull, queue = 0xCA0000AB00000006ull,
                   wrong = 0xCA0000AB00000007ull;
    const uint32_t mode[4] = {sr::kReplyModeOpcode, sr::kReplyModePacketSize, sr::kSilentSuccess | sr::kSilentStart, 0};
    std::vector<unsigned char> stream;
    auto add = [&](const std::vector<unsigned char>& packet) { stream.insert(stream.end(), packet.begin(), packet.end()); };
    stream.insert(stream.end(), (const unsigned char*)&flags, (const unsigned char*)&flags + 4);
    stream.insert(stream.end(), (const unsigned char*)mode, (const unsigned char*)mode + sizeof(mode));
    add(createInstance(failed, {"VK_CABOOSE_no_such_extension"}));
    add(createInstance(instance, {}));
    // lavapipe has one physical device: naming two is a wrong prediction.
    add(enumeratePhysicalDevices(instance, {physical, other}));
    add(enumeratePhysicalDevices(instance, {physical}));
    // Family 0 of lavapipe's one physical device has one queue: two is a wrong prediction.
    add(createDevice(physical, wrong, 2));
    add(createDevice(physical, logical));
    add(getDeviceQueue2(logical, queue));
    add(queueWaitIdle(queue));
    add(destroy(20012, logical));   // vkDestroyDevice
    add(destroy(20001, instance));  // vkDestroyInstance
    const uint32_t version[3] = {20137, 12, 0};
    stream.insert(stream.end(), (const unsigned char*)version, (const unsigned char*)version + sizeof(version));
    ok = ok && sendAll(device[0], stream.data(), stream.size()) && shutdown(device[0], SHUT_WR) == 0;

    // The only replies: vkQueueWaitIdle's result and the instance version with its result.
    int32_t idle = -1;
    uint32_t versionReply[2] = {};
    ok = ok && readAll(device[0], &idle, sizeof(idle)) && readAll(device[0], versionReply, sizeof(versionReply));
    unsigned char extra = 0;
    const bool nothingElse = recv(device[0], &extra, 1, 0) == 0;
    deviceThread.join();

    // The failed creates' FAULTs, in order: serial 0, the fault status, the opcode and result.
    struct Fault { uint64_t serial = 1; int32_t status = 0; uint32_t opcode = 0; int32_t result = 0; };
    Fault faults[3];
    for (Fault& fault : faults) {
        unsigned char record[CompletionFeed::kRecordSize] = {};
        uint32_t payload = 0;
        unsigned char faultPayload[8] = {};
        ok = ok && readAll(feed[0], record, sizeof(record));
        std::memcpy(&fault.serial, record, 8); std::memcpy(&fault.status, record + 8, 4);
        std::memcpy(&payload, record + 12, 4);
        ok = ok && payload == 8 && readAll(feed[0], faultPayload, sizeof(faultPayload));
        std::memcpy(&fault.opcode, faultPayload, 4); std::memcpy(&fault.result, faultPayload + 4, 4);
    }
    shutdown(feed[0], SHUT_RDWR);
    feedThread.join();
    close(feed[0]); close(feed[1]); close(device[0]); close(device[1]);
    const int stop = caboose_gpu_runtime_stop(token);
    const int finish = stop ? stop : caboose_gpu_runtime_finish(token);

    auto faulted = [](const Fault& f, uint32_t opcode, int32_t result) {
        return f.serial == 0 && f.status == CompletionFeed::kFault && f.opcode == opcode && f.result == result;
    };
    const bool pass = ok && nothingElse && deviceResult == 0 && idle == 0 && versionReply[0] >= (1u << 22) &&
                      versionReply[1] == 0 && faulted(faults[0], sr::kCreateInstance, -7) &&
                      faulted(faults[1], sr::kEnumeratePhysicalDevices, -3) &&
                      faulted(faults[2], sr::kCreateDevice, -3) && !finish;
    std::printf("%s one-way start: device stream %d, idle %d, version 0x%x result %d, nothing else %d; "
                "feed records serial %llu status 0x%x opcode %u result %d, serial %llu status 0x%x opcode %u "
                "result %d, serial %llu status 0x%x opcode %u result %d; cleanup %d\n",
                pass ? "PASS" : "FAIL", deviceResult, idle, versionReply[0], (int)versionReply[1], nothingElse,
                (unsigned long long)faults[0].serial, (unsigned)faults[0].status, faults[0].opcode, faults[0].result,
                (unsigned long long)faults[1].serial, (unsigned)faults[1].status, faults[1].opcode, faults[1].result,
                (unsigned long long)faults[2].serial, (unsigned)faults[2].status, faults[2].opcode, faults[2].result,
                finish);
    return pass ? 0 : 1;
}
