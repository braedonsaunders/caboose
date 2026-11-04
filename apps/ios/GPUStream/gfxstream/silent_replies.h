// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
// Silent-success replies (docs/gpu-live.md, "Silent-success replies").
//
// A device stream that sends REPLY_MODE(1) reads no reply of the commands listed in
// silent-success-opcodes.inc. The decoder holds such a command's reply while it decodes and
// drops it: on success nothing is written; on failure a FAULT record goes on the process's
// completion feed instead (CompletionFeed::fault), which the guest treats as device loss.
// REPLY_MODE(3), with hello 0x1000000 (one-way start), also silences the commands that start a
// process's Vulkan, whose handles the guest chooses itself (the fork's
// caboose_guest_dispatchable.h): vkCreateInstance, vkEnumeratePhysicalDevices, vkCreateDevice
// and vkGetDeviceQueue(2). Those return no VkResult of their own a queue could fail with: a
// queue lookup failed when its reply names no queue.
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <unordered_set>
#include <vector>

namespace caboose::gpuv2::silent_replies {

inline constexpr uint32_t kReplyModeOpcode = 0x4342FE06;
inline constexpr uint32_t kReplyModePacketSize = 16;
inline constexpr uint32_t kSilentSuccess = 1;
inline constexpr uint32_t kSilentStart = 2;  // with kSilentSuccess: REPLY_MODE(3)

inline constexpr uint32_t kCreateInstance = 20000u, kEnumeratePhysicalDevices = 20002u, kCreateDevice = 20011u,
                          kGetDeviceQueue = 20017u, kGetDeviceQueue2 = 20155u;

// Whether a stream in `mode` reads no reply of `opcode`.
inline bool listed(uint32_t opcode, uint32_t mode = kSilentSuccess) {
    static const std::unordered_set<uint32_t> opcodes = {
#include "silent-success-opcodes.inc"
    };
    if ((mode & kSilentStart) && (opcode == kCreateInstance || opcode == kEnumeratePhysicalDevices ||
                                  opcode == kCreateDevice || opcode == kGetDeviceQueue || opcode == kGetDeviceQueue2))
        return true;
    return (mode & kSilentSuccess) && opcodes.count(opcode) != 0;
}

// Listed commands that return void: their reply carries no result.
inline bool returnsVoid(uint32_t opcode) { return opcode == 20089u; /* vkFreeCommandBuffers */ }

// The VkResult a listed command's held reply ends with (0 for a void command). A queue's reply
// is its handle: none is VK_ERROR_INITIALIZATION_FAILED.
inline int32_t resultOf(uint32_t opcode, const std::vector<unsigned char>& reply) {
    if (opcode == kGetDeviceQueue || opcode == kGetDeviceQueue2) {
        uint64_t queue = 0;
        if (reply.size() < sizeof(queue)) return -3;
        std::memcpy(&queue, reply.data(), sizeof(queue));
        return queue ? 0 : -3;
    }
    if (returnsVoid(opcode)) return 0;
    // A command that should return a result and wrote none failed to answer.
    if (reply.size() < 4) return -1000;  // not a VkResult any command returns
    int32_t result;
    std::memcpy(&result, reply.data() + reply.size() - 4, 4);
    return result;
}

// Parses a complete REPLY_MODE packet: its mode, or 0 if malformed.
inline uint32_t parseReplyMode(const unsigned char* packet, size_t size) {
    uint32_t opcode, declared, mode, reserved;
    if (size != kReplyModePacketSize) return 0;
    std::memcpy(&opcode, packet, 4);
    std::memcpy(&declared, packet + 4, 4);
    std::memcpy(&mode, packet + 8, 4);
    std::memcpy(&reserved, packet + 12, 4);
    if (opcode != kReplyModeOpcode || declared != kReplyModePacketSize || reserved) return 0;
    return mode == kSilentSuccess || mode == (kSilentSuccess | kSilentStart) ? mode : 0;
}

}  // namespace caboose::gpuv2::silent_replies
