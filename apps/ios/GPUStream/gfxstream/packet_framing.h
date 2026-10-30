// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <cstddef>
#include <cstdint>
namespace caboose::gpuv2 {
enum class FrameStatus { need_more, ready, invalid, unsupported };
struct FrameResult { FrameStatus status; size_t size; };
// Framing only; generated Vulkan command fields are not generally bounds checked.
// Data contains one upstream packet, possibly fragmented. max_size bounds the
// entire packet including the flush extension payload, not just its header length.
FrameResult inspectFrame(const uint8_t* data, size_t size, size_t max_size, bool sequenced);
}
