// SPDX-License-Identifier: MIT
#include "rpc_timing.h"
#include <cassert>
#include <cstdio>
#include <limits>
#include <vector>

using namespace caboose::memory;

int main() {
    // Verify all 10 selected opcodes map to distinct indices 0..9.
    const uint32_t expected[10] = {
        20018u, 20019u, 20020u, 20037u, 20039u,
        20076u, 20077u, 20090u, 20091u, 20092u,
    };
    for (int i = 0; i < 10; ++i) {
        assert(timedRpcIndex(expected[i]) == i);
    }
    assert(timedRpcIndex(20025u) == -1);

    // Verify 128 periodic emissions + 1 overflow marker (129 total callbacks), while totals continue accumulating.
    uint64_t now_us = 0;
    RpcTimingCollector<128, 2000000ull> bounded;
    std::vector<unsigned> ordinals;
    auto clock = [&]() noexcept -> uint64_t { return now_us; };
    auto sink = [&](const RpcCallRecord& rec) noexcept {
        bounded.recordWith(
            rec,
            [&](unsigned ordinal, uint64_t, const RpcTimingSnapshot&, const RpcTimingSnapshot&) {
                ordinals.push_back(ordinal);
            });
    };

    for (unsigned i = 0; i < 140; ++i) {
        BasicRpcCallScope scope{expected[i % 10], true, clock, sink};
        scope.lock([&] { now_us += 100000ull; });
        now_us += 1900000ull; // 2.0 s total per call -> 1 period per call
        // Positive VkResult (e.g. VK_TIMEOUT = 2) is not an error; negative VkResult is an error.
        const int rc = (i == 3) ? 2 : ((i == 7) ? -4 : 0);
        assert(scope.finish(rc) == rc);
    }

    assert(ordinals.size() == 129);
    assert(ordinals.front() == 0 && ordinals[127] == 127 && ordinals.back() == 128);
    const auto tot = bounded.totals();
    assert(tot.calls == 140 && tot.errors == 1);
    assert(tot.elapsed_sum_us == 140 * 2000000ull);
    assert(tot.lock_wait_sum_us == 140 * 100000ull);

    std::puts("PASS rpc timing: 10-opcode index table, positive VkResult non-error, 128-period cap and cumulative totals");
}
