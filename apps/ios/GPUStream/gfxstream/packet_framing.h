// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <cstddef>
#include <cstdint>
namespace caboose::gpuv2 {
enum class FrameStatus { need_more, ready, invalid, unsupported };
struct FrameResult { FrameStatus status; size_t size; };
struct FrameDiagnostic {
    uint32_t rangeCount = 0, rangeIndex = 0;
    bool tailPresent = false;
    uint64_t tailBytes = 0, tailOffset = 0;
};
// Framing only; generated Vulkan command fields are not generally bounds checked.
// Data contains one upstream packet, possibly fragmented. max_size bounds the
// entire packet including the flush extension payload, not just its header length.
FrameResult inspectFrame(const uint8_t* data, size_t size, size_t max_size, bool sequenced,
                         FrameDiagnostic* diagnostic = nullptr);
// V4 private profile excludes deferred/async/Android queue work before decoder entry.
bool forbiddenV4Opcode(uint32_t opcode);
}
