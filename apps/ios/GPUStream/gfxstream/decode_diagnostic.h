// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <atomic>
#include <cstdint>
#include "packet_framing.h"

namespace caboose::gpuv2 {
// Adapter metadata only. No packet bodies, Vulkan handles, addresses or strings.
enum class DecodeStage : uint32_t {
    validation = 1, flags = 2, input = 3, profile = 4, framing = 5,
    unsupportedFrame = 6, decoder = 7, consumption = 8, flush = 9,
    allocation = 10, stopped = 11, eof = 12, exception = 13,
};
struct DecodeDiagnostic {
    DecodeStage stage = DecodeStage::validation;
    uint32_t headerPresent = 0, opcode = 0, declared = 0;
    uint32_t lastOpcodePresent = 0, lastOpcode = 0;
    uint64_t buffered = 0, frameSize = 0, consumed = 0, completed = 0;
    FrameDiagnostic frame;
    int socketError = 0;
    bool eof = false, stopped = false;
};
// At most 64 terminal records and one overflow marker for a process. Saturates.
class DecodeDiagnosticBudget {
public:
    unsigned take() {
        unsigned current = count.load(std::memory_order_relaxed);
        while (current < 65 && !count.compare_exchange_weak(current, current + 1,
                std::memory_order_relaxed)) {}
        return current;
    }
private:
    std::atomic_uint count{0};
};
#ifdef CABOOSE_GPU_DECODER_TESTING
// Same-thread fixture access only; absent from production builds.
DecodeDiagnostic lastDecodeDiagnosticForTesting();
#endif
}
