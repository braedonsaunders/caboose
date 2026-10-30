// SPDX-License-Identifier: MIT
#include "flush_packet.h"
#include <cassert>
#include <stdexcept>
#include <vector>
using namespace caboose::memory;

int main() {
    constexpr size_t bytes = 32 * 1024 * 1024;
    std::shared_ptr<uint8_t> shadow(new uint8_t[bytes], std::default_delete<uint8_t[]>());
    std::vector<uint8_t> remote(bytes, 0);
    for (size_t i = 0; i < bytes; ++i) shadow.get()[i] = uint8_t((i * 17 + i / 97) & 255);
    unsigned packets = 0, replies = 0, invalidated = 0, fragments = 0;
    uint64_t sent = 0;
    FlushPacket packet{
        [&](const FlushFragment* parts, size_t count, uint64_t wireBytes) {
            assert(count > 0 && count <= 8 && wireBytes <= 512 * 1024);
            uint64_t actualWire = 20;
            for (size_t i = 0; i < count; ++i) {
                const auto& f = parts[i];
                assert(f.range == 0 && f.offset == sent && f.size <= payloadBytes);
                assert(f.offset % 64 == 0 && (f.size % 64 == 0 || f.offset + f.size == bytes));
                std::memcpy(remote.data() + f.offset, shadow.get() + f.offset, size_t(f.size));
                sent += f.size; actualWire += 40 + f.size; ++fragments;
            }
            assert(actualWire == wireBytes); ++packets; return 0;
        }, [&](int& result) { ++replies; result = 0; return true; }, [&] { ++invalidated; }};
    assert(transact(false, 1, [&](uint32_t, Range& r) {
        r.base = shadow.get(); r.lifetime = shadow; r.mapEnd = r.allocation = bytes;
        r.atom = 64; r.whole = true; return true;
    }, [&](uint32_t i, uint64_t offset, uint64_t size, uint8_t*) {
        return packet.push(i, offset, size);
    }) == 0);
    assert(packet.finish() == 0);
    assert(packets == 65 && replies == 65 && fragments == 513 && sent == bytes && !invalidated);
    assert(std::memcmp(remote.data(), shadow.get(), bytes) == 0);
    assert(processBudget.used() == 0);

    // A partial packet preserves range order, including repeated/overlapping offsets.
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

    // Transport loss invalidates once, prevents all later sends, and is never
    // mistaken for an actual provider error with a consumed response.
    unsigned sends = 0, lost = 0;
    {
        FlushPacket failure{
            [&](const FlushFragment*, size_t, uint64_t) { ++sends; return 0; },
            [](int&) { return false; }, [&] { ++lost; }};
        assert(failure.push(0, 0, 64) == 0);
        assert(failure.finish() == -4 && sends == 1 && lost == 1);
        assert(failure.push(0, 64, 64) == -4 && failure.finish() == -4);
    }
    assert(sends == 1 && lost == 1);
    {
        FlushPacket failure{
            [](const FlushFragment*, size_t, uint64_t) -> int { throw std::runtime_error("serialization"); },
            [](int&) { assert(false); return false; }, [&] { ++lost; }};
        assert(failure.push(0, 0, 64) == 0);
        try { failure.finish(); assert(false); } catch (const std::runtime_error&) {}
    }
    assert(lost == 2);
}
