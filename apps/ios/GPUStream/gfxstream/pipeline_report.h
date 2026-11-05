// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
// Where the phone's pipeline time goes while a computer's processes load (docs/gpu-live.md,
// "Launch timeline"): every ten seconds in which a pipeline was compiled or waited for, one
//
//   CABOOSE_GPU_PIPELINES window_ms=… lane=… lane_ms=… in_place=… in_place_ms=… longest_ms=…
//       waits=… wait_ms=… archive_hits=… archive_misses=…
//
// line: pipelines the decoder's compile lane made and the time its jobs ran, pipelines it made
// in place on a decode thread, the longest single job, how often and how long a decode thread
// waited for a compile it needed, and the Metal binary archive's hits and misses in the window.
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <string>

namespace caboose::gpuv2 {

struct PipelineWindow {
    uint64_t laneCompiled = 0, laneUs = 0, longestUs = 0, inPlace = 0, inPlaceUs = 0, waits = 0, waitUs = 0;
};

class PipelineReport {
public:
    static constexpr int64_t kWindowMs = 10000;
    // Adds what compiling took since the last call, and the archive's counts since launch.
    void add(const PipelineWindow& w, uint64_t archiveHits, uint64_t archiveMisses) {
        window_.laneCompiled += w.laneCompiled; window_.laneUs += w.laneUs;
        if (w.longestUs > window_.longestUs) window_.longestUs = w.longestUs;
        window_.inPlace += w.inPlace; window_.inPlaceUs += w.inPlaceUs;
        window_.waits += w.waits; window_.waitUs += w.waitUs;
        hits_ = archiveHits; misses_ = archiveMisses;
    }
    // The window's line once it has lasted kWindowMs, when anything was compiled or waited
    // for in it; empty otherwise. The window starts again either way once it has ended.
    std::string take(int64_t nowMs) {
        if (start_ < 0) { start_ = nowMs; hitsAtStart_ = hits_; missesAtStart_ = misses_; }
        if (nowMs - start_ < kWindowMs) return {};
        const PipelineWindow w = window_;
        const uint64_t hits = hits_ - hitsAtStart_, misses = misses_ - missesAtStart_;
        const int64_t elapsed = nowMs - start_;
        window_ = PipelineWindow{};
        start_ = nowMs; hitsAtStart_ = hits_; missesAtStart_ = misses_;
        if (!w.laneCompiled && !w.inPlace && !w.waits && !hits && !misses) return {};
        char line[512];
        std::snprintf(line, sizeof line,
            "CABOOSE_GPU_PIPELINES window_ms=%" PRId64 " lane=%" PRIu64 " lane_ms=%" PRIu64 " in_place=%" PRIu64
            " in_place_ms=%" PRIu64 " longest_ms=%" PRIu64 " waits=%" PRIu64 " wait_ms=%" PRIu64
            " archive_hits=%" PRIu64 " archive_misses=%" PRIu64 "\n",
            elapsed, w.laneCompiled, w.laneUs / 1000, w.inPlace, w.inPlaceUs / 1000, w.longestUs / 1000, w.waits,
            w.waitUs / 1000, hits, misses);
        return line;
    }

private:
    PipelineWindow window_;
    int64_t start_ = -1;
    uint64_t hits_ = 0, misses_ = 0, hitsAtStart_ = 0, missesAtStart_ = 0;
};

}  // namespace caboose::gpuv2
