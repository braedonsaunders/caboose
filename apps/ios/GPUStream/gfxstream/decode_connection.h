// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include "decode_diagnostic.h"

namespace gfxstream::host { struct RenderThreadInfo; }
namespace caboose::gpuv2 {
class CompletionFeed;
// Call only after the process-wide VkDecoderGlobalState has been initialized.
// One call per guest encoder connection; all connections for a guest process
// must share its real upstream ProcessResources. The caller retains fd and
// interrupts blocking I/O with shutdown; stop must remain alive until return.
// Returns 0 only for requested shutdown, otherwise an errno-style error.
// With `completions`, the process's completion feed commands (completion_feed.h) are
// served on this stream; without it they are a protocol error.
int decodeConnection(int fd, size_t max_packet, size_t max_reply_buffer,
                     gfxstream::host::RenderThreadInfo& thread_info,
                     std::atomic_bool& stop, bool synchronousOnly = false,
                     uint64_t* decoderEntries = nullptr, DecodeDiagnostic* diagnostic = nullptr,
                     CompletionFeed* completions = nullptr);
}
