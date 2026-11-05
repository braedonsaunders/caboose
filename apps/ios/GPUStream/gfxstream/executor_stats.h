// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
// The executor's always-on counters (docs/gpu-live.md, "Executor stats"): totals since the
// runtime started, read once a second and sent to the computer as EXECUTOR_STATS. Counters
// only; never handles, payloads or identities. Each note is a few relaxed atomic adds.
#include <atomic>
#include <chrono>
#include <cstdint>
#include "executor_stats_abi.h"

namespace caboose::gpuv2::stats {

struct Counters {
    std::atomic<uint64_t> commands{0}, decodeUs{0}, readBytes{0}, readWaitUs{0}, flushUs{0};
    std::atomic<uint64_t> submitted{0}, completed{0}, completionUs{0}, gpuBusyUs{0};
    std::atomic<int64_t> outstanding{0};
    std::atomic<uint64_t> outstandingMax{0};
    // When the GPU last finished work, for busy time: overlapping completions count once.
    std::atomic<uint64_t> lastCompleteUs{0};
};

inline Counters& counters() {
    static Counters value;
    return value;
}

inline uint64_t nowUs() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}

inline void noteDecode(uint64_t us) {
    auto& c = counters();
    c.commands.fetch_add(1, std::memory_order_relaxed);
    c.decodeUs.fetch_add(us, std::memory_order_relaxed);
}
inline void noteRead(uint64_t bytes, uint64_t waitUs) {
    auto& c = counters();
    c.readBytes.fetch_add(bytes, std::memory_order_relaxed);
    c.readWaitUs.fetch_add(waitUs, std::memory_order_relaxed);
}
inline void noteFlush(uint64_t us) { counters().flushUs.fetch_add(us, std::memory_order_relaxed); }

// A completion watch submitted to a queue; the returned time is passed to noteCompleted.
inline uint64_t noteSubmitted() {
    auto& c = counters();
    c.submitted.fetch_add(1, std::memory_order_relaxed);
    const int64_t now = c.outstanding.fetch_add(1, std::memory_order_relaxed) + 1;
    uint64_t seen = c.outstandingMax.load(std::memory_order_relaxed);
    while (now > 0 && static_cast<uint64_t>(now) > seen &&
           !c.outstandingMax.compare_exchange_weak(seen, static_cast<uint64_t>(now), std::memory_order_relaxed)) {}
    return nowUs();
}

// The watch submitted at `submittedUs` finished (`done`: its work completed). Busy time is
// the part of [submitted, now] after the last completion, so the GPU's time is counted once
// however many queues and watches overlap.
inline void noteCompleted(uint64_t submittedUs, bool done) {
    auto& c = counters();
    c.outstanding.fetch_sub(1, std::memory_order_relaxed);
    if (!done) return;
    const uint64_t now = nowUs();
    c.completed.fetch_add(1, std::memory_order_relaxed);
    c.completionUs.fetch_add(now > submittedUs ? now - submittedUs : 0, std::memory_order_relaxed);
    uint64_t last = c.lastCompleteUs.load(std::memory_order_relaxed);
    while (last < now && !c.lastCompleteUs.compare_exchange_weak(last, now, std::memory_order_relaxed)) {}
    if (last >= now) return;
    const uint64_t from = submittedUs > last ? submittedUs : last;
    c.gpuBusyUs.fetch_add(now > from ? now - from : 0, std::memory_order_relaxed);
}

// Totals since start; the deepest queue since the previous read, which this read restarts.
inline void read(caboose_gpu_executor_stats& out) {
    auto& c = counters();
    out.size = sizeof(out);
    out.commands = c.commands.load(std::memory_order_relaxed);
    out.decode_us = c.decodeUs.load(std::memory_order_relaxed);
    out.read_bytes = c.readBytes.load(std::memory_order_relaxed);
    out.read_wait_us = c.readWaitUs.load(std::memory_order_relaxed);
    out.flush_us = c.flushUs.load(std::memory_order_relaxed);
    out.submitted = c.submitted.load(std::memory_order_relaxed);
    out.completed = c.completed.load(std::memory_order_relaxed);
    out.completion_us = c.completionUs.load(std::memory_order_relaxed);
    out.gpu_busy_us = c.gpuBusyUs.load(std::memory_order_relaxed);
    const int64_t outstanding = c.outstanding.load(std::memory_order_relaxed);
    out.outstanding = outstanding > 0 ? static_cast<uint64_t>(outstanding) : 0;
    out.outstanding_max = c.outstandingMax.exchange(out.outstanding, std::memory_order_relaxed);
}

}  // namespace caboose::gpuv2::stats
