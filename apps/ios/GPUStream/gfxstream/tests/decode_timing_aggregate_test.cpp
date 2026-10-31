// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "decode_timing_aggregate.h"
#include <cassert>
#include <cstdio>
#include <limits>

using namespace caboose::gpuv2;

int main() {
    DecodeTimingAggregator agg(1000);
    agg.recordRead(65472, 300);
    agg.recordDecode(20025, 1200);
    agg.recordFlush(80);
    agg.recordRead(24, 50);
    agg.recordDecode(20324, 4500);
    agg.recordFlush(120);
    agg.recordDecode(20025, 200);
    agg.recordDecode(20065, 3200);
    agg.recordDecode(20021, 1800);

    DecodeTimingSnapshot period{};
    uint64_t elapsed = 0;
    assert(!agg.pollPeriod(2000999, period, elapsed));
    assert(agg.pollPeriod(2001000, period, elapsed));
    assert(elapsed == 2000000);
    assert(period.decode_all.count == 5 && period.decode_all.sum_us == 10900 && period.decode_all.max_us == 4500);
    assert(period.decode_20025.count == 2 && period.decode_20025.sum_us == 1400 && period.decode_20025.max_us == 1200);
    assert(period.decode_20065.count == 1 && period.decode_20065.sum_us == 3200 && period.decode_20065.max_us == 3200);
    assert(period.decode_20021.count == 1 && period.decode_20021.sum_us == 1800 && period.decode_20021.max_us == 1800);
    assert(period.read_wait.count == 2 && period.read_wait.sum_us == 350 && period.read_wait.max_us == 300);
    assert(period.read_bytes == 65496);
    assert(period.flush.count == 2 && period.flush.sum_us == 200 && period.flush.max_us == 120);

    // Period resets while stream total preserves all observations.
    agg.recordDecode(20025, 900);
    agg.recordDecode(20065, 450);
    assert(!agg.pollPeriod(3000000, period, elapsed));
    assert(agg.pollPeriod(4001000, period, elapsed));
    assert(period.decode_all.count == 2 && period.decode_all.sum_us == 1350);
    assert(period.decode_20065.count == 1 && period.decode_20065.sum_us == 450);
    const auto& total = agg.total();
    assert(total.decode_all.count == 7 && total.decode_all.sum_us == 12250 && total.decode_all.max_us == 4500);
    assert(total.decode_20025.count == 3 && total.decode_20025.sum_us == 2300 && total.decode_20025.max_us == 1200);
    assert(total.decode_20065.count == 2 && total.decode_20065.sum_us == 3650 && total.decode_20065.max_us == 3200);
    assert(total.decode_20021.count == 1 && total.decode_20021.sum_us == 1800 && total.decode_20021.max_us == 1800);

    // Saturating addition never wraps on count or sum overflow.
    DecodeDurationSample sat{};
    sat.count = std::numeric_limits<uint64_t>::max();
    sat.sum_us = std::numeric_limits<uint64_t>::max() - 10;
    sat.add(25);
    assert(sat.count == std::numeric_limits<uint64_t>::max());
    assert(sat.sum_us == std::numeric_limits<uint64_t>::max());
    assert(sat.max_us == 25);

    DecodeTimingBudget<64> streamBudget;
    for (unsigned i = 0; i < 65; ++i) assert(streamBudget.take() == i);
    for (unsigned i = 0; i < 100; ++i) assert(streamBudget.take() == 65);

    DecodeTimingBudget<128> periodBudget;
    for (unsigned i = 0; i < 129; ++i) assert(periodBudget.take() == i);
    for (unsigned i = 0; i < 100; ++i) assert(periodBudget.take() == 129);

    std::puts("decode timing aggregate counter/period/budget PASS");
}
