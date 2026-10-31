// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>

namespace caboose::gpuv2::media {
// Process-wide counters for phone-decoded video (docs/gpu-media.md), printed as one
// CABOOSE_GPU_MEDIA line at most every two seconds while they change, and when a media
// connection ends. They describe what arrived and what was filled, not display timing.
struct Stats {
    std::atomic<uint64_t> connections{0}, units{0}, unitBytes{0}, pictures{0}, pictureFailures{0},
        latchPackets{0}, latchedPictures{0}, latchedPixels{0}, latchSkips{0};

    static Stats& instance() {
        static Stats stats;
        return stats;
    }
    void count(std::atomic<uint64_t>& counter, uint64_t n = 1) {
        counter.fetch_add(n, std::memory_order_relaxed);
        report(false);
    }
    void report(bool force) {
        const int64_t now = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count();
        int64_t last = lastReport_.load(std::memory_order_relaxed);
        if (!force && now - last < 2000) return;
        if (!lastReport_.compare_exchange_strong(last, now)) return;
        std::fprintf(stderr,
            "CABOOSE_GPU_MEDIA connections=%llu units=%llu unit_bytes=%llu pictures=%llu "
            "picture_failures=%llu latch_packets=%llu latched_pictures=%llu latched_pixels=%llu "
            "latch_skips=%llu\n",
            v(connections), v(units), v(unitBytes), v(pictures), v(pictureFailures), v(latchPackets),
            v(latchedPictures), v(latchedPixels), v(latchSkips));
    }
private:
    static unsigned long long v(const std::atomic<uint64_t>& a) { return a.load(std::memory_order_relaxed); }
    std::atomic<int64_t> lastReport_{0};
};
}
