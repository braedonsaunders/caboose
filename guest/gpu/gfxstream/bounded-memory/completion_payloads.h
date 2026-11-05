// SPDX-License-Identifier: MIT
#pragma once
// Completion payloads (docs/gpu-live.md, "Completion payloads"). With hello feature 0x200000
// (granted with the completion feed, 0x200) a watched submission that ends queries or writes
// coherent memory is watched with COMPLETION_WATCH2, which also names those query ranges and
// memory ranges. Once its marker completes the phone captures them and sends the captures in
// the watch's record. The process keeps query values per query and answers
// vkGetQueryPoolResults from them, every flag and layout included, without a request on the
// device stream; captured memory is stored in the allocation's guest shadow.
//
// This header holds the wire format, the record payload's parsing, the number of values a
// query type reports, and the writing of vkGetQueryPoolResults' output from known values.
// completion_feed.h's tracker keeps what the records bring.
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

namespace caboose::completion::payloads {

// COMPLETION_WATCH2, on the device stream with the ordinary 8-byte packet header (opcode,
// size u32 = 32 + 32 * count, both counted in the size like COMPLETION_WATCH's), little-endian:
// boxed queue u64, serial u64 (both nonzero), count u32 (1..kMaxEntries), flags u32 = 0; then,
// from byte 32, `count` 32-byte entries: kind u32,
// reserved u32 = 0, handle u64 (the boxed VkQueryPool or VkDeviceMemory), a u64, b u64
// (queries: a = first query, b = query count; memory: a = offset, b = size).
inline constexpr uint32_t kWatch2Opcode = 0x4342FE05;
inline constexpr uint32_t kWatch2HeaderSize = 32;
inline constexpr uint32_t kEntrySize = 32;
inline constexpr uint32_t kMaxEntries = 256;
inline constexpr uint32_t kQueryRange = 1;
inline constexpr uint32_t kMemoryRange = 2;

// A record under the feature: serial u64, status i32, payload bytes u32 (0 without the
// feature, and whenever the captures would pass kMaxPayload), then the payload: per capture a
// 32-byte head (kind u32, status i32 = the capture's VkResult, handle u64, a u64, b u64) and
// its data, padded to 8 bytes: b × {value u64, availability u64} for a query range (64-bit,
// with availability), b bytes for a memory range. A reader stops at a kind it does not know.
// Records with serial 0 are not completions (a fault report); a reader skips those it does
// not know.
inline constexpr size_t kRecordHeadSize = 16;
inline constexpr uint32_t kMaxPayload = 1u << 20;
inline constexpr int32_t kFaultStatus = 0x7FFF0001;

struct Entry {
    uint32_t kind;
    uint64_t handle, a, b;
    bool operator==(const Entry& o) const { return kind == o.kind && handle == o.handle && a == o.a && b == o.b; }
};

inline uint32_t watch2Size(size_t entries) { return kWatch2HeaderSize + uint32_t(entries) * kEntrySize; }

// The packet for `entries` (1..kMaxEntries of them, handles as the phone names them).
inline std::vector<uint8_t> encodeWatch2(uint64_t boxedQueue, uint64_t serial, const std::vector<Entry>& entries) {
    std::vector<uint8_t> out(watch2Size(entries.size()), 0);
    const uint32_t opcode = kWatch2Opcode, size = uint32_t(out.size()), count = uint32_t(entries.size());
    std::memcpy(out.data(), &opcode, 4);
    std::memcpy(out.data() + 4, &size, 4);
    std::memcpy(out.data() + 8, &boxedQueue, 8);
    std::memcpy(out.data() + 16, &serial, 8);
    std::memcpy(out.data() + 24, &count, 4);
    for (size_t i = 0; i < entries.size(); ++i) {
        uint8_t* p = out.data() + kWatch2HeaderSize + i * kEntrySize;
        std::memcpy(p, &entries[i].kind, 4);
        std::memcpy(p + 8, &entries[i].handle, 8);
        std::memcpy(p + 16, &entries[i].a, 8);
        std::memcpy(p + 24, &entries[i].b, 8);
    }
    return out;
}

inline uint64_t padded(uint64_t bytes) { return (bytes + 7) / 8 * 8; }
// The payload bytes a capture of `entry` takes.
inline uint64_t captureSize(const Entry& entry) {
    return kEntrySize + padded(entry.kind == kQueryRange ? entry.b * 16 : entry.b);
}

// One capture of a record's payload.
struct Capture {
    Entry entry;
    int32_t status;
    const uint8_t* data;  // b × {value, availability} u64 pairs, or b bytes
};

// The captures of a payload, in order; stops at a kind it does not know. False when a capture
// runs past the payload (a malformed record: nothing of it is used).
inline bool parsePayload(const uint8_t* payload, size_t size, std::vector<Capture>* out) {
    out->clear();
    size_t offset = 0;
    while (size - offset >= kEntrySize) {
        Capture capture;
        const uint8_t* p = payload + offset;
        std::memcpy(&capture.entry.kind, p, 4);
        std::memcpy(&capture.status, p + 4, 4);
        std::memcpy(&capture.entry.handle, p + 8, 8);
        std::memcpy(&capture.entry.a, p + 16, 8);
        std::memcpy(&capture.entry.b, p + 24, 8);
        if (capture.entry.kind != kQueryRange && capture.entry.kind != kMemoryRange) return true;
        const uint64_t room = size - offset - kEntrySize;
        const uint64_t count = capture.entry.b;
        if (capture.entry.kind == kQueryRange ? count > room / 16 : count > room) {
            out->clear();
            return false;
        }
        const uint64_t data = padded(capture.entry.kind == kQueryRange ? count * 16 : count);
        if (data > room) {
            out->clear();
            return false;
        }
        capture.data = p + kEntrySize;
        out->push_back(capture);
        offset += kEntrySize + size_t(data);
    }
    if (offset != size) {
        out->clear();
        return false;
    }
    return true;
}

// Whether queries of this VkQueryType are captured: occlusion and timestamp pools, one value
// per query. Every other pool (pipeline statistics, transform feedback, ...) is asked about
// on the device.
inline bool capturedType(int32_t queryType) { return queryType == 0 || queryType == 2; }

// VkQueryResultFlagBits.
inline constexpr uint32_t k64Bit = 0x1, kWait = 0x2, kWithAvailability = 0x4, kPartial = 0x8;

// One query as the process knows it: available with its value, not available yet, or not
// known here (the device must be asked).
struct Known {
    enum State { Available, Unavailable, Unknown } state = Unknown;
    uint64_t value = 0;
};
inline constexpr int32_t kAskDevice = -1;

// Writes vkGetQueryPoolResults' output for `count` queries of one value each from known(i)
// (i from 0): VK_SUCCESS (0) when all are available, VK_NOT_READY (1) when one is not, or
// kAskDevice, writing nothing, when any query is unknown, the flags are not ones answered
// here, the layout does not fit `dataSize`, or WAIT is set and a query is not available.
// An unavailable query's value is left untouched unless PARTIAL, which writes zero (an
// intermediate value); WITH_AVAILABILITY writes each query's availability after its value.
// 32-bit results keep the low half of each value.
template <class KnownAt>
inline int32_t writeResults(uint32_t count, size_t dataSize, void* data, uint64_t stride, uint32_t flags,
                            KnownAt known) {
    if (!count || !data || (flags & ~(k64Bit | kWait | kWithAvailability | kPartial))) return kAskDevice;
    const uint64_t word = (flags & k64Bit) ? 8 : 4;
    const uint64_t element = ((flags & kWithAvailability) ? 2 : 1) * word;
    if (stride % word || (count > 1 && stride < element)) return kAskDevice;
    if (uint64_t(count - 1) * stride + element > dataSize) return kAskDevice;
    bool ready = true;
    for (uint32_t i = 0; i < count; ++i) {
        const Known k = known(i);
        if (k.state == Known::Unknown) return kAskDevice;
        if (k.state == Known::Unavailable) {
            if (flags & kWait) return kAskDevice;
            ready = false;
        }
    }
    auto put = [&](uint8_t* at, uint64_t value) {
        if (word == 8) std::memcpy(at, &value, 8);
        else { const uint32_t low = uint32_t(value); std::memcpy(at, &low, 4); }
    };
    for (uint32_t i = 0; i < count; ++i) {
        const Known k = known(i);
        uint8_t* base = static_cast<uint8_t*>(data) + uint64_t(i) * stride;
        const bool available = k.state == Known::Available;
        if (available || (flags & kPartial)) put(base, available ? k.value : 0);
        if (flags & kWithAvailability) put(base + word, available ? 1 : 0);
    }
    return ready ? 0 : 1;
}

}  // namespace caboose::completion::payloads
