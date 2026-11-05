// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// The executor's always-on counters (executor_stats.h).
#include "executor_stats.h"
#include <cstdio>

namespace {
int failures = 0;
void check(bool ok, const char* what) {
    if (!ok) { std::fprintf(stderr, "FAIL %s\n", what); ++failures; }
}
}  // namespace

int main() {
    using namespace caboose::gpuv2::stats;
    noteDecode(10);
    noteDecode(5);
    noteRead(100, 7);
    noteFlush(3);
    const uint64_t first = noteSubmitted();
    const uint64_t second = noteSubmitted();
    caboose_gpu_executor_stats s{};
    s.size = sizeof(s);
    read(s);
    check(s.commands == 2 && s.decode_us == 15, "decode totals");
    check(s.read_bytes == 100 && s.read_wait_us == 7 && s.flush_us == 3, "read and flush totals");
    check(s.submitted == 2 && s.outstanding == 2 && s.outstanding_max == 2, "two watches waiting");
    noteCompleted(first, true);
    noteCompleted(second, false);
    read(s);
    check(s.completed == 1, "only the completed watch counts as completed");
    check(s.outstanding == 0, "both watches ended");
    check(s.outstanding_max == 2, "the deepest queue since the last read");
    read(s);
    check(s.outstanding_max == 0, "a read restarts the deepest queue");
    // Overlapping watches count the GPU's time once.
    const uint64_t a = noteSubmitted(), b = noteSubmitted();
    noteCompleted(a, true);
    noteCompleted(b, true);
    caboose_gpu_executor_stats t{};
    t.size = sizeof(t);
    read(t);
    check(t.gpu_busy_us <= t.completion_us, "busy time is never more than the summed latency");
    if (!failures) std::puts("executor stats: ok");
    return failures ? 1 : 0;
}
