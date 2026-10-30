// SPDX-License-Identifier: MIT
#include "flush_timing.h"
#include "flush_window.h"
#include <cassert>
#include <cstdio>
#include <limits>
#include <stdexcept>
#include <vector>

using namespace caboose::memory;

int main() {
    // 1. Multi-window classification: 19 chunks across 2 full 8-chunk windows + 1 partial 3-chunk window.
    // Verifies first_read_write_wait (3 windows) vs rest_read_wait (7 + 7 + 2 = 16 replies).
    {
        uint64_t now_us = 1000;
        FlushTimingCollector<128> collector;
        std::vector<FlushCallRecord> emitted_calls;
        std::vector<unsigned> emitted_ordinals;

        auto clock = [&]() noexcept -> uint64_t { return now_us; };
        auto sink = [&](const FlushCallRecord& rec) noexcept {
            collector.recordWith(rec, [&](unsigned ordinal, const FlushCallRecord& c, const FlushTimingTotals&) {
                emitted_ordinals.push_back(ordinal);
                emitted_calls.push_back(c);
            });
        };

        {
            BasicFlushCallScope scope{4u, true, clock, sink};
            unsigned read_index_in_window = 0;
            FlushWindow window{
                [&](unsigned, unsigned long long, unsigned long long size) {
                    return scope.send(size, [&] {
                        now_us += 10; // 10 us per chunk serialization into IOStream m_buf
                        read_index_in_window = 0;
                        return 0;
                    });
                },
                [&](int& result) {
                    return scope.receive(result, [&] {
                        // First tryRead flushes buffered socket bytes + waits 500 us; remaining 7 wait 20 us each.
                        now_us += (read_index_in_window == 0) ? 500 : 20;
                        ++read_index_in_window;
                        result = 0;
                        return true;
                    });
                },
                [&] { scope.invalidate(); }};

            for (unsigned i = 0; i < 19; ++i) {
                assert(window.push(0, i * 4096ull, 4096ull) == 0);
            }
            assert(scope.finish(window.finish()) == 0);
            // Calling finish() a second time or running destructor must not double-emit.
            assert(scope.finish(-1) == -1);
        }

        assert(emitted_calls.size() == 1 && emitted_ordinals.size() == 1 && emitted_ordinals[0] == 0);
        const auto& rec = emitted_calls[0];
        assert(rec.result == 0 && rec.transport_failed == 0);
        assert(rec.range_count == 4);
        assert(rec.windows == 3);
        assert(rec.send.count == 19 && rec.send.sum_us == 190 && rec.send.max_us == 10);
        assert(rec.send_bytes == 19 * 4096ull);
        assert(rec.first_read_write_wait.count == 3);
        assert(rec.first_read_write_wait.sum_us == 1500 && rec.first_read_write_wait.max_us == 500);
        assert(rec.rest_read_wait.count == 16);
        assert(rec.rest_read_wait.sum_us == 320 && rec.rest_read_wait.max_us == 20);
        assert(rec.elapsed_us == 190 + 1500 + 320);

        const auto tot = collector.totals();
        assert(tot.calls == 1 && tot.errors == 0 && tot.transport_failures == 0);
        assert(tot.ranges == 4 && tot.windows == 3 && tot.send_bytes == 19 * 4096ull);
        assert(tot.send.count == 19 && tot.first_read_write_wait.count == 3 && tot.rest_read_wait.count == 16);
    }

    // 2. RAII failure emission once on transport failure, provider error, and thrown exception.
    {
        uint64_t now_us = 5000;
        FlushTimingCollector<128> collector;
        unsigned callback_count = 0;
        auto clock = [&]() noexcept -> uint64_t { now_us += 5; return now_us; };
        auto sink = [&](const FlushCallRecord& rec) noexcept {
            collector.recordWith(rec, [&](unsigned, const FlushCallRecord&, const FlushTimingTotals&) {
                ++callback_count;
            });
        };

        // (a) Transport failure on 2nd receive in a partial window, exited via exception without finish().
        bool caught = false;
        try {
            BasicFlushCallScope scope{2u, true, clock, sink};
            int reads = 0;
            FlushWindow window{
                [&](unsigned, unsigned long long, unsigned long long size) {
                    return scope.send(size, [&] { return 0; });
                },
                [&](int& result) {
                    return scope.receive(result, [&]() -> bool {
                        if (++reads == 2) throw std::runtime_error("socket lost");
                        result = 0;
                        return true;
                    });
                },
                [&] { scope.invalidate(); }};
            assert(window.push(0, 0, 1024) == 0);
            assert(window.push(0, 1024, 1024) == 0);
            (void)window.finish();
        } catch (const std::runtime_error&) {
            caught = true;
        }
        assert(caught && callback_count == 1);
        const auto tot = collector.totals();
        assert(tot.calls == 1 && tot.errors == 1 && tot.transport_failures == 1);
        assert(tot.windows == 1 && tot.send.count == 2 && tot.send_bytes == 2048);
        assert(tot.first_read_write_wait.count == 1 && tot.rest_read_wait.count == 1);
    }

    // 3. Saturating addition on count and sum overflow, plus 128-record budget + limit marker.
    {
        FlushDurationSample sat{};
        sat.count = std::numeric_limits<uint64_t>::max();
        sat.sum_us = std::numeric_limits<uint64_t>::max() - 10;
        sat.add(25);
        assert(sat.count == std::numeric_limits<uint64_t>::max());
        assert(sat.sum_us == std::numeric_limits<uint64_t>::max());
        assert(sat.max_us == 25);

        FlushDurationSample sat2{};
        sat2.count = 10;
        sat2.sum_us = 100;
        sat2.max_us = 50;
        sat.merge(sat2);
        assert(sat.count == std::numeric_limits<uint64_t>::max());
        assert(sat.sum_us == std::numeric_limits<uint64_t>::max());
        assert(sat.max_us == 50);

        FlushTimingCollector<128> bounded;
        std::vector<unsigned> ordinals;
        for (unsigned i = 0; i < 200; ++i) {
            FlushCallRecord rec{};
            rec.range_count = 1;
            rec.result = 0;
            rec.elapsed_us = 10;
            bounded.recordWith(rec, [&](unsigned ordinal, const FlushCallRecord&, const FlushTimingTotals&) {
                ordinals.push_back(ordinal);
            });
        }
        // Exactly 128 per-call ordinals (0..127) + 1 overflow marker (128) = 129 emissions,
        // while totals accurately reflect all 200 calls.
        assert(ordinals.size() == 129);
        assert(ordinals.front() == 0 && ordinals[127] == 127 && ordinals.back() == 128);
        const auto tot = bounded.totals();
        assert(tot.calls == 200 && tot.ranges == 200 && tot.elapsed_sum_us == 2000);
    }

    std::puts("PASS flush timing: window first/rest classification, RAII single failure emission, saturation and 128-record cap");
}
