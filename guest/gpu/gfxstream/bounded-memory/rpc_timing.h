// SPDX-License-Identifier: MIT
#pragma once
#include "flush_timing.h"
#include <array>
#include <cinttypes>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <utility>

namespace caboose::memory {

// Fixed table of the 10 selected synchronous encoder RPC opcodes.
// Whole-call elapsed_us spans encoder entry (including pre-lock/validation,
// lock acquisition wait, request marshaling, buffered IOStream write,
// synchronous reply read, and unlock). It is NOT a pure network RTT metric.
inline constexpr size_t kTimedRpcCount = 10;
inline constexpr std::array<uint32_t, kTimedRpcCount> kTimedRpcOpcodes = {
    20018u, // OP_vkQueueSubmit
    20019u, // OP_vkQueueWaitIdle
    20020u, // OP_vkDeviceWaitIdle
    20037u, // OP_vkResetFences
    20039u, // OP_vkWaitForFences
    20076u, // OP_vkResetDescriptorPool
    20077u, // OP_vkAllocateDescriptorSets
    20090u, // OP_vkBeginCommandBuffer
    20091u, // OP_vkEndCommandBuffer
    20092u, // OP_vkResetCommandBuffer
};

inline constexpr int timedRpcIndex(uint32_t opcode) noexcept {
    for (size_t i = 0; i < kTimedRpcCount; ++i) {
        if (kTimedRpcOpcodes[i] == opcode) return static_cast<int>(i);
    }
    return -1;
}

struct RpcCallRecord {
    uint32_t opcode = 0;
    uint64_t elapsed_us = 0;
    uint64_t lock_wait_us = 0;
    uint64_t completed_at_us = 0;
    int result = -4;
};

struct RpcOpcodeSample {
    uint64_t calls = 0;
    uint64_t errors = 0;
    uint64_t elapsed_sum_us = 0;
    uint64_t elapsed_max_us = 0;
    uint64_t lock_wait_sum_us = 0;
    uint64_t lock_wait_max_us = 0;

    void add(const RpcCallRecord& call) noexcept {
        saturateAdd(calls, 1u);
        if (call.result < 0) saturateAdd(errors, 1u);
        saturateAdd(elapsed_sum_us, call.elapsed_us);
        if (call.elapsed_us > elapsed_max_us) elapsed_max_us = call.elapsed_us;
        saturateAdd(lock_wait_sum_us, call.lock_wait_us);
        if (call.lock_wait_us > lock_wait_max_us) lock_wait_max_us = call.lock_wait_us;
    }

    void merge(const RpcOpcodeSample& other) noexcept {
        saturateAdd(calls, other.calls);
        saturateAdd(errors, other.errors);
        saturateAdd(elapsed_sum_us, other.elapsed_sum_us);
        if (other.elapsed_max_us > elapsed_max_us) elapsed_max_us = other.elapsed_max_us;
        saturateAdd(lock_wait_sum_us, other.lock_wait_sum_us);
        if (other.lock_wait_max_us > lock_wait_max_us) lock_wait_max_us = other.lock_wait_max_us;
    }
};

struct RpcTimingSnapshot {
    uint64_t calls = 0;
    uint64_t errors = 0;
    uint64_t elapsed_sum_us = 0;
    uint64_t elapsed_max_us = 0;
    uint64_t lock_wait_sum_us = 0;
    uint64_t lock_wait_max_us = 0;
    std::array<RpcOpcodeSample, kTimedRpcCount> by_opcode{};

    bool accumulate(const RpcCallRecord& call) noexcept {
        const int idx = timedRpcIndex(call.opcode);
        if (idx < 0) return false;
        saturateAdd(calls, 1u);
        if (call.result < 0) saturateAdd(errors, 1u);
        saturateAdd(elapsed_sum_us, call.elapsed_us);
        if (call.elapsed_us > elapsed_max_us) elapsed_max_us = call.elapsed_us;
        saturateAdd(lock_wait_sum_us, call.lock_wait_us);
        if (call.lock_wait_us > lock_wait_max_us) lock_wait_max_us = call.lock_wait_us;
        by_opcode[static_cast<size_t>(idx)].add(call);
        return true;
    }
};

template<unsigned Limit = 128, uint64_t PeriodUs = 2000000ull>
class RpcTimingCollector {
public:
    static constexpr unsigned kLimit = Limit;
    static constexpr uint64_t kPeriodUs = PeriodUs;

    ~RpcTimingCollector() noexcept {
        flushPending();
    }

    template<class Emit>
    void recordWith(const RpcCallRecord& call, Emit&& emit) noexcept {
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!totals_.accumulate(call)) return;
            (void)period_.accumulate(call);
            const uint64_t now_us = call.completed_at_us;
            if (!window_started_) {
                window_started_ = true;
                window_started_us_ = now_us >= call.elapsed_us ? now_us - call.elapsed_us : 0u;
            }
            last_completed_us_ = now_us;
            const uint64_t window_us = now_us >= window_started_us_ ? now_us - window_started_us_ : 0u;
            if (window_us >= PeriodUs) {
                const unsigned ordinal = emitted_ <= Limit ? emitted_++ : Limit + 1u;
                const RpcTimingSnapshot snap = period_;
                period_ = RpcTimingSnapshot{};
                window_started_us_ = now_us;
                if (ordinal <= Limit) {
                    emit(ordinal, window_us, snap, totals_);
                }
            }
        } catch (...) {}
    }

    template<class Emit>
    void flushPendingWith(Emit&& emit) noexcept {
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            if (period_.calls == 0 || emitted_ > Limit) return;
            const unsigned ordinal = emitted_++;
            const uint64_t window_us =
                last_completed_us_ >= window_started_us_ ? last_completed_us_ - window_started_us_ : 0u;
            const RpcTimingSnapshot snap = period_;
            period_ = RpcTimingSnapshot{};
            window_started_us_ = last_completed_us_;
            emit(ordinal, window_us, snap, totals_);
        } catch (...) {}
    }

    void record(const RpcCallRecord& call) noexcept {
        recordWith(call, &RpcTimingCollector::emitStderr);
    }

    void flushPending() noexcept {
        flushPendingWith(&RpcTimingCollector::emitStderr);
    }

    RpcTimingSnapshot totals() const noexcept {
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            return totals_;
        } catch (...) {
            return {};
        }
    }

    RpcTimingSnapshot currentPeriod() const noexcept {
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            return period_;
        } catch (...) {
            return {};
        }
    }

    unsigned emitted() const noexcept {
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            return emitted_;
        } catch (...) {
            return 0;
        }
    }

private:
    static void emitStderr(
        unsigned ordinal,
        uint64_t window_us,
        const RpcTimingSnapshot& period,
        const RpcTimingSnapshot& tot) noexcept {
        if (ordinal < Limit) {
            std::fprintf(
                stderr,
                "CABOOSE_GPU_RPC_TIMING ordinal=%u window_us=%" PRIu64 " "
                "calls=%" PRIu64 " errors=%" PRIu64 " "
                "elapsed_sum_us=%" PRIu64 " elapsed_max_us=%" PRIu64 " "
                "lock_wait_sum_us=%" PRIu64 " lock_wait_max_us=%" PRIu64 " "
                "total_calls=%" PRIu64 " total_errors=%" PRIu64 " "
                "total_elapsed_sum_us=%" PRIu64 " total_elapsed_max_us=%" PRIu64 " "
                "total_lock_wait_sum_us=%" PRIu64 " total_lock_wait_max_us=%" PRIu64,
                ordinal, window_us,
                period.calls, period.errors,
                period.elapsed_sum_us, period.elapsed_max_us,
                period.lock_wait_sum_us, period.lock_wait_max_us,
                tot.calls, tot.errors,
                tot.elapsed_sum_us, tot.elapsed_max_us,
                tot.lock_wait_sum_us, tot.lock_wait_max_us);
            for (size_t i = 0; i < kTimedRpcCount; ++i) {
                const uint32_t op = kTimedRpcOpcodes[i];
                const auto& p = period.by_opcode[i];
                const auto& t = tot.by_opcode[i];
                std::fprintf(
                    stderr,
                    " op_%" PRIu32 "_calls=%" PRIu64 " op_%" PRIu32 "_errors=%" PRIu64
                    " op_%" PRIu32 "_elapsed_sum_us=%" PRIu64 " op_%" PRIu32 "_elapsed_max_us=%" PRIu64
                    " op_%" PRIu32 "_lock_wait_sum_us=%" PRIu64 " op_%" PRIu32 "_lock_wait_max_us=%" PRIu64
                    " total_op_%" PRIu32 "_calls=%" PRIu64 " total_op_%" PRIu32 "_elapsed_sum_us=%" PRIu64
                    " total_op_%" PRIu32 "_lock_wait_sum_us=%" PRIu64,
                    op, p.calls, op, p.errors,
                    op, p.elapsed_sum_us, op, p.elapsed_max_us,
                    op, p.lock_wait_sum_us, op, p.lock_wait_max_us,
                    op, t.calls, op, t.elapsed_sum_us,
                    op, t.lock_wait_sum_us);
            }
            std::fputc('\n', stderr);
            std::fflush(stderr);
        } else if (ordinal == Limit) {
            std::fprintf(
                stderr,
                "CABOOSE_GPU_RPC_TIMING limit=%u total_calls=%" PRIu64 " total_errors=%" PRIu64 " "
                "total_elapsed_sum_us=%" PRIu64 " total_elapsed_max_us=%" PRIu64 " "
                "total_lock_wait_sum_us=%" PRIu64 " total_lock_wait_max_us=%" PRIu64,
                Limit, tot.calls, tot.errors,
                tot.elapsed_sum_us, tot.elapsed_max_us,
                tot.lock_wait_sum_us, tot.lock_wait_max_us);
            for (size_t i = 0; i < kTimedRpcCount; ++i) {
                const uint32_t op = kTimedRpcOpcodes[i];
                const auto& t = tot.by_opcode[i];
                std::fprintf(
                    stderr,
                    " total_op_%" PRIu32 "_calls=%" PRIu64 " total_op_%" PRIu32 "_errors=%" PRIu64
                    " total_op_%" PRIu32 "_elapsed_sum_us=%" PRIu64 " total_op_%" PRIu32 "_elapsed_max_us=%" PRIu64
                    " total_op_%" PRIu32 "_lock_wait_sum_us=%" PRIu64 " total_op_%" PRIu32 "_lock_wait_max_us=%" PRIu64,
                    op, t.calls, op, t.errors,
                    op, t.elapsed_sum_us, op, t.elapsed_max_us,
                    op, t.lock_wait_sum_us, op, t.lock_wait_max_us);
            }
            std::fputc('\n', stderr);
            std::fflush(stderr);
        }
    }

    mutable std::mutex mutex_;
    unsigned emitted_ = 0;
    bool window_started_ = false;
    uint64_t window_started_us_ = 0;
    uint64_t last_completed_us_ = 0;
    RpcTimingSnapshot period_{};
    RpcTimingSnapshot totals_{};
};

inline bool rpcTimingEnabled() noexcept {
    static const bool enabled = []() noexcept {
        const char* v = std::getenv("CABOOSE_PRIVATE_GPU_RPC_TIMING");
        return v && std::strcmp(v, "1") == 0;
    }();
    return enabled;
}

inline RpcTimingCollector<128>& processRpcTimingCollector() noexcept {
    static RpcTimingCollector<128> collector;
    return collector;
}

template<class Clock, class Sink>
class BasicRpcCallScope {
public:
    BasicRpcCallScope(uint32_t opcode, bool enabled, Clock clock, Sink sink) noexcept
        : clock_(std::move(clock)), sink_(std::move(sink)), enabled_(enabled && timedRpcIndex(opcode) >= 0) {
        if (enabled_) {
            record_.opcode = opcode;
            record_.result = 0;
            started_us_ = clock_();
        }
    }

    BasicRpcCallScope(const BasicRpcCallScope&) = delete;
    BasicRpcCallScope& operator=(const BasicRpcCallScope&) = delete;

    ~BasicRpcCallScope() noexcept {
        if (enabled_ && !completed_) {
            record_.result = -4;
            emitOnce();
        }
    }

    template<class Fn>
    void lock(Fn&& fn) {
        if (!enabled_) {
            fn();
            return;
        }
        const uint64_t start_us = clock_();
        struct LockGuard {
            BasicRpcCallScope* self;
            uint64_t start;
            ~LockGuard() noexcept {
                const uint64_t end = self->clock_();
                const uint64_t elapsed = end >= start ? end - start : 0u;
                saturateAdd(self->record_.lock_wait_us, elapsed);
            }
        } guard{this, start_us};
        fn();
    }

    int finish(int final_result) noexcept {
        if (enabled_ && !completed_) {
            record_.result = final_result;
            emitOnce();
        }
        return final_result;
    }

private:
    void emitOnce() noexcept {
        completed_ = true;
        try {
            const uint64_t end_us = clock_();
            record_.completed_at_us = end_us;
            record_.elapsed_us = end_us >= started_us_ ? end_us - started_us_ : 0u;
            sink_(record_);
        } catch (...) {}
    }

    Clock clock_;
    Sink sink_;
    RpcCallRecord record_{};
    uint64_t started_us_ = 0;
    bool enabled_ = false;
    bool completed_ = false;
};

class RpcCallScope {
public:
    explicit RpcCallScope(uint32_t opcode) noexcept
        : inner_(opcode, rpcTimingEnabled(), &steadyFlushMicros, DefaultSink{}) {}

    RpcCallScope(const RpcCallScope&) = delete;
    RpcCallScope& operator=(const RpcCallScope&) = delete;

    template<class Fn>
    void lock(Fn&& fn) {
        inner_.lock(std::forward<Fn>(fn));
    }

    int finish(int final_result) noexcept {
        return inner_.finish(final_result);
    }

private:
    struct DefaultSink {
        void operator()(const RpcCallRecord& rec) const noexcept {
            processRpcTimingCollector().record(rec);
        }
    };
    BasicRpcCallScope<uint64_t (*)() noexcept, DefaultSink> inner_;
};

} // namespace caboose::memory
