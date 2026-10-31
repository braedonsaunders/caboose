// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <atomic>
#include <cstddef>
#include <cstdint>

namespace caboose::gpuv2 {

struct DecodeDurationSample {
    uint64_t count = 0;
    uint64_t sum_us = 0;
    uint64_t max_us = 0;

    void add(uint64_t elapsed_us) {
        if (count < UINT64_MAX) ++count;
        if (elapsed_us <= UINT64_MAX - sum_us) sum_us += elapsed_us;
        else sum_us = UINT64_MAX;
        if (elapsed_us > max_us) max_us = elapsed_us;
    }
};

struct DecodeTimingSnapshot {
    // Pinned opcodes:
    //   20021 = OP_vkCreateComputePipelines
    //   20025 = OP_vkFlushMappedMemoryRanges
    //   20065 = OP_vkCreateGraphicsPipelines
    DecodeDurationSample decode_all{};
    DecodeDurationSample decode_20021{};
    DecodeDurationSample decode_20025{};
    DecodeDurationSample decode_20065{};
    DecodeDurationSample read_wait{};
    uint64_t read_bytes = 0;
    DecodeDurationSample flush{};

    void recordDecode(uint32_t opcode, uint64_t elapsed_us) {
        decode_all.add(elapsed_us);
        if (opcode == 20021u) decode_20021.add(elapsed_us);
        else if (opcode == 20025u) decode_20025.add(elapsed_us);
        else if (opcode == 20065u) decode_20065.add(elapsed_us);
    }

    void recordRead(size_t bytes, uint64_t elapsed_us) {
        read_wait.add(elapsed_us);
        const uint64_t value = static_cast<uint64_t>(bytes);
        if (value <= UINT64_MAX - read_bytes) read_bytes += value;
        else read_bytes = UINT64_MAX;
    }

    void recordFlush(uint64_t elapsed_us) {
        flush.add(elapsed_us);
    }
};

template<unsigned Limit>
class DecodeTimingBudget {
public:
    static constexpr unsigned kLimit = Limit;
    // Returns 0..Limit-1 for valid records, Limit once for the overflow marker,
    // and Limit+1 when suppressed.
    unsigned take() {
        unsigned value = count_.load(std::memory_order_relaxed);
        while (value <= Limit && !count_.compare_exchange_weak(value, value + 1,
                                                               std::memory_order_relaxed)) {}
        return value;
    }
private:
    std::atomic_uint count_{0};
};

class DecodeTimingAggregator {
public:
    explicit DecodeTimingAggregator(uint64_t started_us = 0)
        : period_started_us_(started_us) {}

    void recordDecode(uint32_t opcode, uint64_t elapsed_us) {
        total_.recordDecode(opcode, elapsed_us);
        period_.recordDecode(opcode, elapsed_us);
    }

    void recordRead(size_t bytes, uint64_t elapsed_us) {
        total_.recordRead(bytes, elapsed_us);
        period_.recordRead(bytes, elapsed_us);
    }

    void recordFlush(uint64_t elapsed_us) {
        total_.recordFlush(elapsed_us);
        period_.recordFlush(elapsed_us);
    }

    bool pollPeriod(uint64_t now_us, DecodeTimingSnapshot& out, uint64_t& elapsed_us,
                    uint64_t interval_us = 2000000ull) {
        if (now_us < period_started_us_ || now_us - period_started_us_ < interval_us) return false;
        elapsed_us = now_us - period_started_us_;
        out = period_;
        period_ = {};
        period_started_us_ = now_us;
        return true;
    }

    const DecodeTimingSnapshot& total() const { return total_; }

private:
    uint64_t period_started_us_ = 0;
    DecodeTimingSnapshot total_{};
    DecodeTimingSnapshot period_{};
};

} // namespace caboose::gpuv2
