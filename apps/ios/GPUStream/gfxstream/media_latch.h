// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// LATCH packets in a process's Vulkan stream (docs/gpu-media.md, "Latch").
#pragma once
#include <cstddef>
#include <cstdint>

namespace caboose::gpuv2 {
// The longest a latch waits for the pictures it names.
constexpr unsigned kLatchWaitMilliseconds = 200;
// Fills the images one LATCH packet names, on its queue, for the stream's context.
// `data` holds the whole packet of `size` bytes. Returns 0, or EPROTO when the packet is
// malformed. An entry that cannot be filled (an object the context does not own, a picture
// that does not arrive in time, a format the image cannot hold) leaves that image as it was.
int executeLatch(uint32_t contextId, const uint8_t* data, size_t size);
}
