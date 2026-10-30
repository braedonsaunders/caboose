// SPDX-License-Identifier: MIT
#include "flush_packet.h"
#include <cassert>
#include <cstdio>
#include <stdexcept>
#include <vector>
using namespace caboose::memory;

int main() {
    // 1. A 32 MiB atom-aligned flush (513 fragments = 65 packets) pipelines in
    // windows of up to 8 packets (8 * 8 + 1 = 9 windows total), preserving order.
    constexpr size_t bytes = 32 * 1024 * 1024;
    std::shared_ptr<uint8_t> shadow(new uint8_t[bytes], std::default_delete<uint8_t[]>());
    std::vector<uint8_t> remote(bytes, 0);
    for (size_t i = 0; i < bytes; ++i) shadow.get()[i] = uint8_t((i * 17 + i / 97) & 255);
    unsigned packets = 0, replies = 0, windows = 0, invalidated = 0, fragments = 0;
    size_t inFlight = 0, maxInFlight = 0;
    bool draining = false;
    uint64_t sent = 0;
    FlushPacket packet{
        [&](const FlushFragment* parts, size_t count, uint64_t wireBytes) {
            if (draining) {
                assert(inFlight == 0);
                draining = false;
            }
            assert(count > 0 && count <= flushFragmentCapacity && wireBytes <= 512 * 1024);
            uint64_t actualWire = 20;
            for (size_t i = 0; i < count; ++i) {
                const auto& f = parts[i];
                assert(f.range == 0 && f.offset == sent && f.size <= payloadBytes);
                assert(f.offset % 64 == 0 && (f.size % 64 == 0 || f.offset + f.size == bytes));
                std::memcpy(remote.data() + f.offset, shadow.get() + f.offset, size_t(f.size));
                sent += f.size; actualWire += 40 + f.size; ++fragments;
            }
            assert(actualWire == wireBytes);
            ++packets;
            ++inFlight;
            assert(inFlight <= flushWindowCapacity);
            if (inFlight > maxInFlight) maxInFlight = inFlight;
            return 0;
        }, [&](int& result) {
            assert(replies < packets && inFlight > 0 && inFlight <= flushWindowCapacity);
            if (!draining) {
                assert(windows < 8 ? inFlight == flushWindowCapacity : inFlight == 1);
                draining = true;
                ++windows;
            }
            --inFlight;
            ++replies;
            result = 0;
            return true;
        }, [&] { ++invalidated; }};
    assert(transact(false, 1, [&](uint32_t, Range& r) {
        r.base = shadow.get(); r.lifetime = shadow; r.mapEnd = r.allocation = bytes;
        r.atom = 64; r.whole = true; return true;
    }, [&](uint32_t i, uint64_t offset, uint64_t size, uint8_t*) {
        return packet.push(i, offset, size);
    }) == 0);
    // 512 fragments filled 64 packets (8 full 8-packet windows); fragment 513 is still buffered.
    assert(packets == 64 && replies == 64 && windows == 8 && inFlight == 0);
    assert(packet.finish() == 0);
    assert(packets == 65 && replies == 65 && windows == 9 && maxInFlight == 8 && inFlight == 0);
    assert(fragments == 513 && sent == bytes && !invalidated);
    assert(std::memcmp(remote.data(), shadow.get(), bytes) == 0);
    assert(processBudget.used() == 0);

    // 2. A partial packet preserves range order, including repeated/overlapping offsets.
    std::vector<FlushFragment> observed;
    unsigned readCount = 0;
    FlushPacket partial{
        [&](const FlushFragment* p, size_t n, uint64_t wire) {
            observed.assign(p, p + n); assert(wire == 20 + 3 * 40 + 3 * 64); return 0;
        }, [&](int& result) { ++readCount; result = -2; return true; }, [&] { assert(false); }};
    assert(partial.push(2, 64, 64) == 0);
    assert(partial.push(0, 0, 64) == 0);
    assert(partial.push(1, 0, 64) == 0);
    assert(observed.empty());
    assert(partial.finish() == -2 && readCount == 1);
    assert(observed.size() == 3 && observed[0].range == 2 && observed[1].range == 0 && observed[2].range == 1);
    assert(partial.push(3, 0, 64) == -2 && partial.finish() == -2 && readCount == 1);

    // 3. Every provider-error position in an 8-packet window drains all 8 replies in
    // that window, records the earliest error, and sends no subsequent packet or window.
    for (int fail = 0; fail < int(flushWindowCapacity); ++fail) {
        int sentPackets = 0, readReplies = 0, inv = 0;
        FlushPacket winErr{
            [&](const FlushFragment*, size_t n, uint64_t) {
                assert(n == flushFragmentCapacity);
                ++sentPackets;
                return 0;
            },
            [&](int& result) {
                result = (readReplies++ == fail) ? -1 : (readReplies == 8 ? -2 : 0);
                return true;
            },
            [&] { ++inv; }};
        for (int i = 0; i < 63; ++i) {
            assert(winErr.push(0, uint64_t(i) * 64, 64) == 0);
            assert(readReplies == 0);
        }
        assert(sentPackets == 7 && readReplies == 0);
        assert(winErr.push(0, 63 * 64, 64) == -1);
        assert(sentPackets == 8 && readReplies == 8 && inv == 0);
        assert(winErr.push(0, 64 * 64, 64) == -1 && sentPackets == 8 && readReplies == 8);
        assert(winErr.finish() == -1 && sentPackets == 8 && readReplies == 8 && inv == 0);
    }

    // 4. Transport loss invalidates once, outranks earlier provider errors in the
    // same window, prevents all later sends, and never reuses replies.
    for (int fail = 0; fail < int(flushWindowCapacity); ++fail) {
        int sentPackets = 0, readReplies = 0, inv = 0;
        FlushPacket winLost{
            [&](const FlushFragment*, size_t, uint64_t) { ++sentPackets; return 0; },
            [&](int& result) { result = -1; return readReplies++ != fail; },
            [&] { ++inv; }};
        for (int i = 0; i < 63; ++i) assert(winLost.push(0, uint64_t(i) * 64, 64) == 0);
        assert(winLost.push(0, 63 * 64, 64) == -4);
        assert(inv == 1 && sentPackets == 8 && readReplies == fail + 1);
        assert(winLost.push(0, 64 * 64, 64) == -4 && winLost.finish() == -4 && sentPackets == 8);
    }

    // 5. Failed or throwing sends poison the stream once even when earlier packets
    // in the current window are already awaiting replies; abandonment also invalidates once.
    for (int fail = 0; fail < int(flushWindowCapacity); ++fail) {
        for (bool throws : {false, true}) {
            int sentPackets = 0, readReplies = 0, inv = 0;
            FlushPacket sendFail{
                [&](const FlushFragment*, size_t, uint64_t) -> int {
                    if (sentPackets++ == fail) {
                        if (throws) throw std::runtime_error("serialization");
                        return -4;
                    }
                    return 0;
                },
                [&](int& result) { ++readReplies; result = 0; return true; },
                [&] { ++inv; }};
            for (int i = 0; i < fail * int(flushFragmentCapacity); ++i) {
                assert(sendFail.push(0, uint64_t(i) * 64, 64) == 0);
            }
            for (int i = 0; i < int(flushFragmentCapacity) - 1; ++i) {
                assert(sendFail.push(0, uint64_t(i) * 64, 64) == 0);
            }
            try {
                assert(sendFail.push(0, 7 * 64, 64) == -4 && !throws);
            } catch (const std::runtime_error&) {
                assert(throws);
            }
            assert(inv == 1 && readReplies == 0 && sendFail.finish() == -4);
        }
    }
    int abandonedInvalidated = 0;
    {
        FlushPacket abandoned{
            [](const FlushFragment*, size_t, uint64_t) { return 0; },
            [](int&) { return true; },
            [&] { ++abandonedInvalidated; }};
        for (size_t i = 0; i < flushFragmentCapacity; ++i) {
            assert(abandoned.push(0, i * 64, 64) == 0);
        }
    }
    assert(abandonedInvalidated == 1);
    std::puts("PASS flush packet: 32MiB 9-window pipeline, partial order, window error drain, and single invalidation on loss/throw/abandon");
}
