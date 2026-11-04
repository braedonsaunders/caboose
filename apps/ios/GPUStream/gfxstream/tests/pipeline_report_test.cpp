// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "pipeline_report.h"
#include <cassert>
#include <string>

using caboose::gpuv2::PipelineReport;
using caboose::gpuv2::PipelineWindow;

int main() {
    PipelineReport report;
    // The first take opens the window.
    report.add({}, 100, 7);
    assert(report.take(1000).empty());
    PipelineWindow w;
    w.laneCompiled = 40; w.laneUs = 2500000; w.longestUs = 90000; w.inPlace = 2; w.inPlaceUs = 120000;
    w.waits = 12; w.waitUs = 1800000;
    report.add(w, 130, 17);
    PipelineWindow more; more.longestUs = 150000; more.laneCompiled = 1; more.laneUs = 150000;
    report.add(more, 131, 18);
    assert(report.take(10999).empty());
    const std::string line = report.take(11000);
    assert(line == "CABOOSE_GPU_PIPELINES window_ms=10000 lane=41 lane_ms=2650 in_place=2 in_place_ms=120 "
                   "longest_ms=150 waits=12 wait_ms=1800 archive_hits=31 archive_misses=11\n");
    // A window with nothing compiled, waited for or looked up writes nothing.
    report.add({}, 131, 18);
    assert(report.take(21000).empty());
    // Archive lookups alone are a window to report.
    report.add({}, 140, 18);
    assert(report.take(31000) == "CABOOSE_GPU_PIPELINES window_ms=10000 lane=0 lane_ms=0 in_place=0 in_place_ms=0 "
                                 "longest_ms=0 waits=0 wait_ms=0 archive_hits=9 archive_misses=0\n");
    return 0;
}
