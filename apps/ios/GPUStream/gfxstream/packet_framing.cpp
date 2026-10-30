// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "packet_framing.h"
#include <algorithm>
#include <cstring>
#include <iterator>

namespace caboose::gpuv2 {
namespace {
constexpr uint32_t opcodes[] = {
#include "decoder-opcodes.inc"
};
constexpr uint32_t flushOpcode = 20025; // OP_vkFlushMappedMemoryRanges at the pin.
constexpr uint32_t mappedMemoryRangeType = 6; // VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE.
uint32_t u32(const uint8_t* p) { uint32_t x; std::memcpy(&x, p, sizeof(x)); return x; }
uint64_t u64(const uint8_t* p) { uint64_t x; std::memcpy(&x, p, sizeof(x)); return x; }
FrameResult need(size_t size) { return {FrameStatus::need_more, size}; }
FrameResult invalid() { return {FrameStatus::invalid, 0}; }
}
FrameResult inspectFrame(const uint8_t* data, size_t size, size_t max_size, bool sequenced) {
    if (max_size < 8 || size > max_size || (size && !data)) return invalid();
    if (size < 8) return need(8);
    const uint32_t opcode = u32(data);
    const uint32_t declared = u32(data + 4);
    if (!std::binary_search(std::begin(opcodes), std::end(opcodes), opcode)) return invalid();
    if (declared < 8 || declared > max_size) return invalid();
    if (size < declared) return need(declared);
    if (opcode != flushOpcode) return {FrameStatus::ready, declared};

    // Pinned upstream non-direct flush: optional seqno, device, count,
    // VkMappedMemoryRange values, then a uint64 length and bytes per range.
    // Reject extensions rather than guessing their generated wire shape.
    const size_t count_offset = 8 + (sequenced ? 4 : 0) + 8;
    if (declared < count_offset + 4) return invalid();
    const uint32_t count = u32(data + count_offset);
    const size_t ranges_offset = count_offset + 4;
    constexpr size_t range_size = 32;
    if (count > (declared - ranges_offset) / range_size ||
        ranges_offset + size_t(count) * range_size != declared) return invalid();
    for (uint32_t i = 0; i < count; ++i) {
        const auto* range = data + ranges_offset + size_t(i) * range_size;
        if (u32(range) != mappedMemoryRangeType) return invalid();
        // BE pNext size; zero has the same representation on both byte orders.
        if (u32(range + 4) != 0) return {FrameStatus::unsupported, 0};
    }
    size_t position = declared;
    for (uint32_t i = 0; i < count; ++i) {
        if (max_size - position < 8) return invalid();
        if (size - position < 8) return need(position + 8);
        const uint64_t bytes = u64(data + position);
        position += 8;
        if (bytes > max_size - position) return invalid();
        position += static_cast<size_t>(bytes);
        if (size < position) return need(position);
    }
    return {FrameStatus::ready, position};
}
}
