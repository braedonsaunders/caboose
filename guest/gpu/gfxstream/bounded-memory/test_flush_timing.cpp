// SPDX-License-Identifier: MIT
#include "flush_packet.h"
#include "flush_timing.h"
#include "flush_window.h"
#include "rpc_timing.h"
#include <cassert>
#include <cstdio>
#include <limits>
#include <stdexcept>
#include <vector>

using namespace caboose::memory;

int main() {
    // 1. Multi-window classification + pre-validation and lock-wait phases:
    // 19 chunks across 2 full 8-chunk windows + 1 partial 3-chunk window.
    // Verifies validation_us, lock_wait_us, first_read_write_wait (3 windows) vs rest_read_wait (16 replies).
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
            const int valid = scope.validate([&] {
                now_us += 15; // 15 us validation before lock
                return 0;
            });
            assert(valid == 0);
            scope.lock([&] {
                now_us += 45; // 45 us waiting for encoder lock
            });
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
        assert(rec.validation_us == 15);
        assert(rec.lock_wait_us == 45);
        assert(rec.windows == 3);
        assert(rec.send.count == 19 && rec.send.sum_us == 190 && rec.send.max_us == 10);
        assert(rec.send_bytes == 19 * 4096ull);
        assert(rec.first_read_write_wait.count == 3);
        assert(rec.first_read_write_wait.sum_us == 1500 && rec.first_read_write_wait.max_us == 500);
        assert(rec.rest_read_wait.count == 16);
        assert(rec.rest_read_wait.sum_us == 320 && rec.rest_read_wait.max_us == 20);
        assert(rec.elapsed_us == 15 + 45 + 190 + 1500 + 320);

        const auto tot = collector.totals();
        assert(tot.calls == 1 && tot.errors == 0 && tot.transport_failures == 0);
        assert(tot.ranges == 4 && tot.windows == 3 && tot.send_bytes == 19 * 4096ull);
        assert(tot.validation_sum_us == 15 && tot.validation_max_us == 15);
        assert(tot.lock_wait_sum_us == 45 && tot.lock_wait_max_us == 45);
        assert(tot.send.count == 19 && tot.first_read_write_wait.count == 3 && tot.rest_read_wait.count == 16);
    }

    // 1b. Windowed multi-range FlushPacket timing:
    // 79 fragments pack into 10 multi-range packets across 2 windows (8 packets + 2 packets).
    // Verifies 2 first_read_write_wait samples and 8 rest_read_wait samples.
    {
        uint64_t now_us = 1000;
        FlushTimingCollector<128> collector;
        std::vector<FlushCallRecord> emitted_calls;
        auto clock = [&]() noexcept -> uint64_t { return now_us; };
        auto sink = [&](const FlushCallRecord& rec) noexcept {
            collector.recordWith(rec, [&](unsigned, const FlushCallRecord& c, const FlushTimingTotals&) {
                emitted_calls.push_back(c);
            });
        };
        {
            BasicFlushCallScope scope{1u, true, clock, sink};
            assert(scope.validate([&] { now_us += 10; return 0; }) == 0);
            scope.lock([&] { now_us += 20; });
            unsigned read_index_in_window = 0;
            FlushPacket packet{
                [&](const FlushFragment* fragments, size_t count, uint64_t) {
                    uint64_t payload = 0;
                    for (size_t i = 0; i < count; ++i) payload += fragments[i].size;
                    return scope.send(payload, [&] {
                        now_us += 30;
                        read_index_in_window = 0;
                        return 0;
                    });
                },
                [&](int& result) {
                    return scope.receive(result, [&] {
                        now_us += (read_index_in_window++ == 0) ? 400 : 15;
                        result = 0;
                        return true;
                    });
                },
                [&] { scope.invalidate(); }};
            for (unsigned i = 0; i < 79; ++i) {
                assert(packet.push(0, i * 4096ull, 4096ull) == 0);
            }
            assert(scope.finish(packet.finish()) == 0);
        }
        assert(emitted_calls.size() == 1);
        const auto& rec = emitted_calls[0];
        assert(rec.result == 0 && rec.transport_failed == 0);
        assert(rec.windows == 2);
        assert(rec.send.count == 10 && rec.send.sum_us == 300 && rec.send.max_us == 30);
        assert(rec.send_bytes == 79 * 4096ull);
        assert(rec.first_read_write_wait.count == 2 && rec.first_read_write_wait.sum_us == 800);
        assert(rec.rest_read_wait.count == 8 && rec.rest_read_wait.sum_us == 120);
        assert(rec.elapsed_us == 10 + 20 + 300 + 800 + 120);
    }

    // 2. Early validation failure records validation_us without acquiring lock or sending chunks.
    {
        uint64_t now_us = 2000;
        FlushTimingCollector<128> collector;
        auto clock = [&]() noexcept -> uint64_t { return now_us; };
        auto sink = [&](const FlushCallRecord& rec) noexcept {
            collector.recordWith(rec, [&](unsigned, const FlushCallRecord&, const FlushTimingTotals&) {});
        };
        {
            BasicFlushCallScope scope{2u, true, clock, sink};
            const int valid = scope.validate([&] {
                now_us += 12;
                return -2;
            });
            assert(valid == -2);
            assert(scope.finish(valid) == -2);
        }
        const auto tot = collector.totals();
        assert(tot.calls == 1 && tot.errors == 1 && tot.transport_failures == 0);
        assert(tot.validation_sum_us == 12 && tot.validation_max_us == 12);
        assert(tot.lock_wait_sum_us == 0 && tot.windows == 0 && tot.send.count == 0);
        assert(tot.elapsed_sum_us == 12);
    }

    // 3. RAII failure emission once on transport failure, provider error, and thrown exception.
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

    // 4. Saturating addition on count and sum overflow, plus 128-record budget + limit marker.
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
            rec.validation_us = 2;
            rec.lock_wait_us = 3;
            bounded.recordWith(rec, [&](unsigned ordinal, const FlushCallRecord&, const FlushTimingTotals&) {
                ordinals.push_back(ordinal);
            });
        }
        assert(ordinals.size() == 129);
        assert(ordinals.front() == 0 && ordinals[127] == 127 && ordinals.back() == 128);
        const auto tot = bounded.totals();
        assert(tot.calls == 200 && tot.ranges == 200 && tot.elapsed_sum_us == 2000);
        assert(tot.validation_sum_us == 400 && tot.lock_wait_sum_us == 600);
    }

    // 5. Whole-call RPC timing: 10-opcode table, periodic 2s window snapshots surviving startup burst,
    // lock_wait_us tracking, RAII failure emission, and 128-period cap.
    {
        uint64_t now_us = 10000;
        RpcTimingCollector<128, 2000000ull> rpc_collector;
        std::vector<unsigned> period_ordinals;
        std::vector<RpcTimingSnapshot> period_snaps;

        auto clock = [&]() noexcept -> uint64_t { return now_us; };
        auto sink = [&](const RpcCallRecord& rec) noexcept {
            rpc_collector.recordWith(
                rec,
                [&](unsigned ordinal, uint64_t, const RpcTimingSnapshot& period, const RpcTimingSnapshot&) {
                    period_ordinals.push_back(ordinal);
                    period_snaps.push_back(period);
                });
        };

        // Simulate 500 startup calls to vkAllocateDescriptorSets (20077) & vkBeginCommandBuffer (20090)
        // within a single 2s period (4,000 us each -> 500 * 4,000 = 2,000,000 us = 1st period snapshot).
        for (unsigned i = 0; i < 500; ++i) {
            const uint32_t op = (i % 2 == 0) ? 20077u : 20090u;
            BasicRpcCallScope scope{op, true, clock, sink};
            scope.lock([&] { now_us += 1000; }); // 1 ms lock wait
            now_us += 3000; // 3 ms body/read
            assert(scope.finish(0) == 0);
        }
        assert(period_ordinals.size() == 1 && period_ordinals[0] == 0);
        assert(period_snaps[0].calls == 500 && period_snaps[0].errors == 0);
        assert(period_snaps[0].elapsed_sum_us == 2000000ull && period_snaps[0].lock_wait_sum_us == 500000ull);
        assert(period_snaps[0].by_opcode[timedRpcIndex(20077u)].calls == 250);
        assert(period_snaps[0].by_opcode[timedRpcIndex(20090u)].calls == 250);

        // Unknown opcode is ignored safely.
        {
            BasicRpcCallScope unknown{99999u, true, clock, sink};
            now_us += 500;
            assert(unknown.finish(0) == 0);
        }
        assert(rpc_collector.totals().calls == 500);

        // Unfinished scope (exception) records error (-4) once on destruction; flushPending emits trailing period.
        {
            BasicRpcCallScope failed{20018u, true, clock, sink};
            failed.lock([&] { now_us += 200; });
            now_us += 800;
        }
        rpc_collector.flushPendingWith(
            [&](unsigned ordinal, uint64_t, const RpcTimingSnapshot& period, const RpcTimingSnapshot&) {
                period_ordinals.push_back(ordinal);
                period_snaps.push_back(period);
            });
        assert(period_ordinals.size() == 2 && period_ordinals[1] == 1);
        assert(period_snaps[1].calls == 1 && period_snaps[1].errors == 1);
        assert(period_snaps[1].by_opcode[timedRpcIndex(20018u)].calls == 1);
        assert(period_snaps[1].by_opcode[timedRpcIndex(20018u)].errors == 1);
        assert(period_snaps[1].by_opcode[timedRpcIndex(20018u)].lock_wait_sum_us == 200);
        assert(period_snaps[1].by_opcode[timedRpcIndex(20018u)].elapsed_sum_us == 1000);
    }

    std::puts("PASS flush + rpc timing: pre-validation/lock phases, windowed FlushPacket, 10-opcode periodic snapshots, RAII single failure emission, saturation and 128-record cap");
}
