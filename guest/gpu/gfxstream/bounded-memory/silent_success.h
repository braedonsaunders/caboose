// SPDX-License-Identifier: MIT
#pragma once
#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <iterator>
#include <mutex>
#include <unordered_map>

#include "completion_feed.h"

// Silent success (docs/gpu-live.md, "Silent success"). With hello feature 0x800000, granted
// with guest-assigned handles and the completion feed, a process switches each device stream
// with one REPLY_MODE packet; from then on the decoder writes no reply for the commands in
// kOpcodes when they succeed. One that fails writes no reply either: the decoder sends a FAULT
// record on the feed, and the process treats it as the loss of its device. The process then
// neither queues nor reads those replies, so they never count against the deferred-reply
// bounds and no drain waits for them.
namespace caboose::silent {

inline constexpr uint32_t kHelloBit = 0x800000;

// REPLY_MODE: an ordinary 8-byte packet header (opcode, total size 16), mode u32, reserved u32
// zero. No reply. Sent once per device stream, before the first command whose reply the
// process will not read, and only while the process's feed is running.
inline constexpr uint32_t kReplyModeOpcode = 0x4342FE06;
inline constexpr uint32_t kReplyModePacketSize = 16;
inline constexpr uint32_t kModeSilentSuccess = 1;
inline void encodeReplyMode(uint8_t out[kReplyModePacketSize]) {
    const uint32_t opcode = kReplyModeOpcode, size = kReplyModePacketSize, mode = kModeSilentSuccess,
                   reserved = 0;
    std::memcpy(out, &opcode, 4);
    std::memcpy(out + 4, &size, 4);
    std::memcpy(out + 8, &mode, 4);
    std::memcpy(out + 12, &reserved, 4);
}

// The commands whose reply silent success leaves out, by opcode. The decoder's list is
// apps/ios/GPUStream/gfxstream/silent-success-opcodes.inc; test_silent_success_list.py fails
// when the two differ, and driver/check_silent_success.py when the encoder defers a reply this
// list does not name or reads one it does.
inline constexpr uint32_t kOpcodes[] = {
    20018u,      // vkQueueSubmit
    20021u,      // vkAllocateMemory
    20028u,      // vkBindBufferMemory
    20029u,      // vkBindImageMemory
    20035u,      // vkCreateFence
    20040u,      // vkCreateSemaphore
    20045u,      // vkSetEvent
    20046u,      // vkResetEvent
    20047u,      // vkCreateQueryPool
    20050u,      // vkCreateBuffer
    20052u,      // vkCreateBufferView
    20054u,      // vkCreateImage
    20057u,      // vkCreateImageView
    20059u,      // vkCreateShaderModule
    20061u,      // vkCreatePipelineCache
    20065u,      // vkCreateGraphicsPipelines
    20066u,      // vkCreateComputePipelines
    20068u,      // vkCreatePipelineLayout
    20070u,      // vkCreateSampler
    20072u,      // vkCreateDescriptorSetLayout
    20074u,      // vkCreateDescriptorPool
    20077u,      // vkAllocateDescriptorSets
    20080u,      // vkCreateFramebuffer
    20082u,      // vkCreateRenderPass
    20085u,      // vkCreateCommandPool
    20088u,      // vkAllocateCommandBuffers
    20089u,      // vkFreeCommandBuffers (no reply either way)
    20138u,      // vkBindBufferMemory2
    20139u,      // vkBindImageMemory2
    20225u,      // vkCreateRenderPass2KHR
    20246u,      // vkBindBufferMemory2KHR
    20247u,      // vkBindImageMemory2KHR
    279590827u,  // vkCreateRenderPass2
    275454371u,  // vkQueueSubmit2
    293024240u,  // vkQueueSubmit2KHR
};
inline bool silentOpcode(uint32_t opcode) {
    return std::find(std::begin(kOpcodes), std::end(kOpcodes), opcode) != std::end(kOpcodes);
}

// Feed records (docs/gpu-live.md, "Completion feed"): a 16-byte header, serial u64, status i32
// and payload_bytes u32, then payload_bytes of payload. A FAULT is serial 0 with kFaultStatus
// and an 8-byte payload: the failed command's opcode u32 and its result i32.
inline constexpr size_t kRecordHeaderSize = 16;
inline constexpr uint64_t kFaultSerial = 0;
inline constexpr int32_t kFaultStatus = 0x7FFF0001;
inline constexpr uint32_t kFaultPayloadBytes = 8;
// A payload larger than this is a protocol error: the reader ends the feed.
inline constexpr uint32_t kMaxRecordPayload = 1u << 20;

struct Record {
    enum class Kind { Completion, Fault, Other } kind = Kind::Completion;
    uint64_t serial = 0;
    int32_t status = 0;
    uint32_t opcode = 0;  // Fault: the failed command
    int32_t result = 0;   // Fault: its result
};
// Reads one record with `read(void*, size_t) -> bool`, which fills the bytes or fails. False
// when the stream ended or the record is malformed. A payload this process does not own is
// read and skipped (Kind::Other).
template <class Read> bool readRecord(Read&& read, Record& record) {
    uint8_t header[kRecordHeaderSize];
    if (!read(header, sizeof(header))) return false;
    uint32_t payloadBytes = 0;
    std::memcpy(&record.serial, header, 8);
    std::memcpy(&record.status, header + 8, 4);
    std::memcpy(&payloadBytes, header + 12, 4);
    record.opcode = 0;
    record.result = 0;
    if (record.serial == kFaultSerial && record.status == kFaultStatus) {
        if (payloadBytes != kFaultPayloadBytes) return false;
        uint8_t payload[kFaultPayloadBytes];
        if (!read(payload, sizeof(payload))) return false;
        std::memcpy(&record.opcode, payload, 4);
        std::memcpy(&record.result, payload + 4, 4);
        record.kind = Record::Kind::Fault;
        return true;
    }
    if (payloadBytes > kMaxRecordPayload) return false;
    uint8_t skip[256];
    for (uint32_t left = payloadBytes; left;) {
        const uint32_t n = std::min<uint32_t>(left, sizeof(skip));
        if (!read(skip, n)) return false;
        left -= n;
    }
    record.kind = payloadBytes ? Record::Kind::Other : Record::Kind::Completion;
    return true;
}

// Which device streams have switched, per encoder (each encoder writes one stream). A switch
// holds for the executor connection generation it was made under; a stream reconnected to a
// new executor switches again. Callers hold the encoder's lock.
class ReplyMode {
public:
    // The executor connection's hello: whether silent success and everything it needs were
    // granted (guest-assigned handles, handle arrays, query pools and buffer views, and the feed).
    void granted(bool value) { granted_.store(value, std::memory_order_release); }
    bool granted() const { return granted_.load(std::memory_order_acquire); }

    // True once, when `encoder` must send REPLY_MODE now: granted, the feed is running, the
    // executor is there, and its stream has not switched under this connection generation.
    // The caller sends the packet before anything else under the same lock hold.
    bool due(const void* encoder, bool feedRunning) {
        if (!granted() || !feedRunning || completion::executorLost.load(std::memory_order_acquire)) return false;
        const uint64_t generation = completion::connectionGeneration.load(std::memory_order_acquire);
        std::lock_guard<std::mutex> lock(mutex_);
        State& state = states_[encoder];
        if (state.generation == generation) return false;
        state = State{generation, false};
        active_.store(true, std::memory_order_release);
        return true;
    }

    // True when `encoder`'s stream sends without replies for kOpcodes.
    bool silent(const void* encoder) const {
        if (!active_.load(std::memory_order_acquire)) return false;
        const uint64_t generation = completion::connectionGeneration.load(std::memory_order_acquire);
        std::lock_guard<std::mutex> lock(mutex_);
        auto found = states_.find(encoder);
        return found != states_.end() && found->second.generation == generation;
    }
    // True when some stream of this process is silent under the current generation.
    bool anySilent() const {
        if (!active_.load(std::memory_order_acquire)) return false;
        const uint64_t generation = completion::connectionGeneration.load(std::memory_order_acquire);
        std::lock_guard<std::mutex> lock(mutex_);
        for (const auto& entry : states_)
            if (entry.second.generation == generation) return true;
        return false;
    }

    // A command sent silently: nothing yet shows the device decoded it.
    void sentSilently(const void* encoder) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto found = states_.find(encoder);
        if (found != states_.end()) found->second.unconfirmed = true;
    }
    // True, once, when a command went silently since the last call: before another channel
    // names what the stream made, the caller waits for one reply sent after them.
    bool takeUnconfirmed(const void* encoder) {
        if (!active_.load(std::memory_order_acquire)) return false;
        std::lock_guard<std::mutex> lock(mutex_);
        auto found = states_.find(encoder);
        if (found == states_.end() || !found->second.unconfirmed) return false;
        found->second.unconfirmed = false;
        return true;
    }

private:
    struct State { uint64_t generation = 0; bool unconfirmed = false; };
    std::atomic<bool> granted_{false};
    std::atomic<bool> active_{false};
    mutable std::mutex mutex_;
    std::unordered_map<const void*, State> states_;
};

// Never destroyed, like the tracker: the feed reader may run during static destruction.
inline ReplyMode& replyMode() {
    static ReplyMode* instance = new ReplyMode;
    return *instance;
}

// A FAULT record: a silent command failed, and what the process has since built on it does not
// exist on the device. The process's device is lost, as when the executor ends its streams
// (docs/gpu-live.md, "Invalid commands"); an application that recovers creates a new instance.
inline void fault(uint32_t opcode, int32_t result) {
    std::fprintf(stderr, "CABOOSE_GPU_SILENT_FAULT opcode=%u result=%d\n", opcode, result);
    completion::markExecutorLost();
}

}  // namespace caboose::silent
