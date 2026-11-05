// SPDX-License-Identifier: MIT
// Completion payloads: COMPLETION_WATCH2's bytes, record payloads, vkGetQueryPoolResults
// written from captured values, and the tracker fed records through a socket as the feed
// stream would carry them.
#include "completion_feed.h"

#include <cassert>
#include <cstdio>
#include <cstring>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>
#include <vector>

using namespace caboose::completion;
namespace p = caboose::completion::payloads;

namespace {
uint32_t u32(const std::vector<uint8_t>& b, size_t at) { uint32_t v; std::memcpy(&v, b.data() + at, 4); return v; }
uint64_t u64(const std::vector<uint8_t>& b, size_t at) { uint64_t v; std::memcpy(&v, b.data() + at, 8); return v; }
template <class T> void put(std::vector<uint8_t>& b, T v) {
    const size_t at = b.size();
    b.resize(at + sizeof(T));
    std::memcpy(b.data() + at, &v, sizeof(T));
}
// A capture as the phone writes it: the 32-byte head, then its data padded to 8.
void capture(std::vector<uint8_t>& b, uint32_t kind, int32_t status, uint64_t handle, uint64_t a, uint64_t count,
             const std::vector<uint64_t>& words, const std::vector<uint8_t>& bytes = {}) {
    put(b, kind); put(b, status); put(b, handle); put(b, a); put(b, count);
    for (uint64_t w : words) put(b, w);
    b.insert(b.end(), bytes.begin(), bytes.end());
    while (b.size() % 8) b.push_back(0);
}
std::vector<uint8_t> record(uint64_t serial, int32_t status, const std::vector<uint8_t>& payload) {
    std::vector<uint8_t> out;
    put(out, serial); put(out, status); put(out, uint32_t(payload.size()));
    out.insert(out.end(), payload.begin(), payload.end());
    return out;
}
bool recvAll(int fd, void* data, size_t size) {
    auto* at = static_cast<uint8_t*>(data);
    while (size) {
        const ssize_t got = recv(fd, at, size, 0);
        if (got <= 0) return false;
        at += got;
        size -= size_t(got);
    }
    return true;
}
}  // namespace

int main() {
    // COMPLETION_WATCH2: the 8-byte header counted in its size, queue, serial, count, flags 0,
    // then 32-byte entries from byte 32.
    {
        const auto packet = p::encodeWatch2(0x51, 7, {{p::kQueryRange, 0xCA00000100000009ull, 3, 2},
                                                      {p::kMemoryRange, 0x77, 4096, 300}});
        assert(packet.size() == 32 + 2 * 32 && p::watch2Size(2) == packet.size());
        assert(u32(packet, 0) == 0x4342FE05 && u32(packet, 4) == packet.size());
        assert(u64(packet, 8) == 0x51 && u64(packet, 16) == 7 && u32(packet, 24) == 2 && u32(packet, 28) == 0);
        assert(u32(packet, 32) == 1 && u32(packet, 36) == 0 && u64(packet, 40) == 0xCA00000100000009ull);
        assert(u64(packet, 48) == 3 && u64(packet, 56) == 2);
        assert(u32(packet, 64) == 2 && u64(packet, 72) == 0x77 && u64(packet, 80) == 4096 && u64(packet, 88) == 300);
        assert(p::captureSize({p::kQueryRange, 1, 0, 2}) == 32 + 32);
        assert(p::captureSize({p::kMemoryRange, 1, 0, 3}) == 32 + 8);
    }
    // Payloads: captures in order, padded to 8; a kind it does not know ends the walk; a
    // capture past the end, or bytes left over, make the payload unusable.
    {
        std::vector<uint8_t> payload;
        capture(payload, p::kQueryRange, 0, 0x9, 4, 2, {11, 1, 0, 0});
        capture(payload, p::kMemoryRange, 0, 0x8, 16, 3, {}, {1, 2, 3});
        std::vector<p::Capture> captures;
        assert(p::parsePayload(payload.data(), payload.size(), &captures) && captures.size() == 2);
        assert(captures[0].entry == (p::Entry{p::kQueryRange, 0x9, 4, 2}) && captures[0].status == 0);
        uint64_t first[2];
        std::memcpy(first, captures[0].data, 16);
        assert(first[0] == 11 && first[1] == 1);
        assert(captures[1].entry == (p::Entry{p::kMemoryRange, 0x8, 16, 3}) && captures[1].data[2] == 3);
        std::vector<uint8_t> unknown = payload;
        capture(unknown, 9, 0, 0, 0, 1000, {});
        assert(p::parsePayload(unknown.data(), unknown.size(), &captures) && captures.size() == 2);
        assert(!p::parsePayload(payload.data(), payload.size() - 8, &captures) && captures.empty());
        std::vector<uint8_t> extra = payload;
        extra.resize(extra.size() + 8);
        assert(!p::parsePayload(extra.data(), extra.size(), &captures));
        std::vector<uint8_t> huge;
        capture(huge, p::kQueryRange, 0, 0x9, 0, uint64_t(1) << 62, {});
        assert(!p::parsePayload(huge.data(), huge.size(), &captures));
        assert(p::parsePayload(nullptr, 0, &captures) && captures.empty());
    }
    // Only occlusion and timestamp pools are captured.
    assert(p::capturedType(0) && p::capturedType(2) && !p::capturedType(1) && !p::capturedType(1000028004) &&
           !p::capturedType(1000382000));
    // vkGetQueryPoolResults' layouts from known values.
    {
        using K = p::Known;
        const std::vector<K> known = {{K::Available, 0x100000005ull}, {K::Unavailable, 0}, {K::Available, 7}};
        auto at = [&](uint32_t i) { return known[i]; };
        uint64_t out[8];
        std::memset(out, 0xAB, sizeof(out));
        // 64-bit with availability, stride 16: values and availability; the unavailable
        // query's value is left untouched.
        assert(p::writeResults(3, sizeof(out), out, 16, p::k64Bit | p::kWithAvailability, at) == 1);
        assert(out[0] == 0x100000005ull && out[1] == 1 && out[2] == 0xABABABABABABABABull && out[3] == 0);
        assert(out[4] == 7 && out[5] == 1);
        // PARTIAL writes zero for it.
        assert(p::writeResults(3, sizeof(out), out, 16, p::k64Bit | p::kWithAvailability | p::kPartial, at) == 1);
        assert(out[2] == 0 && out[3] == 0);
        // 32-bit, tightly packed: the low half of each value.
        uint32_t small[3] = {9, 9, 9};
        assert(p::writeResults(3, sizeof(small), small, 4, 0, at) == 1);
        assert(small[0] == 5 && small[1] == 9 && small[2] == 7);
        // WAIT with a query not available is the device's to answer; all available succeeds.
        assert(p::writeResults(3, sizeof(out), out, 16, p::k64Bit | p::kWait | p::kWithAvailability, at) ==
               p::kAskDevice);
        auto first = [&](uint32_t) { return known[0]; };
        assert(p::writeResults(1, 8, out, 0, p::k64Bit | p::kWait, first) == 0 && out[0] == 0x100000005ull);
        // A layout that does not fit, a misaligned or short stride, unknown flags or an
        // unknown query: nothing written, the device answers.
        assert(p::writeResults(3, 40, out, 16, p::k64Bit | p::kWithAvailability, at) == p::kAskDevice);
        assert(p::writeResults(3, sizeof(out), out, 12, p::k64Bit, at) == p::kAskDevice);
        assert(p::writeResults(3, sizeof(out), out, 8, p::k64Bit | p::kWithAvailability, at) == p::kAskDevice);
        assert(p::writeResults(1, sizeof(out), out, 8, p::k64Bit | 0x10, first) == p::kAskDevice);
        auto unknown = [&](uint32_t i) { return i == 1 ? K{} : known[i]; };
        assert(p::writeResults(3, sizeof(out), out, 16, p::k64Bit, unknown) == p::kAskDevice);
        assert(p::writeResults(0, sizeof(out), out, 16, p::k64Bit, at) == p::kAskDevice);
    }
    // The tracker: a batch ends occlusion queries and writes coherent memory; its watch names
    // them; the record's captures answer vkGetQueryPoolResults and fill the shadow.
    static uint8_t shadow[4096];
    static uint64_t storedOffset = 0, storedSize = 0;
    {
        Tracker t;
        t.memoryHooks(
            [](uint64_t memory, Tracker::MemoryTarget* out) {
                if (memory != 0xA1) return false;
                out->base = shadow;
                out->begin = 0;
                out->end = sizeof(shadow);
                return true;
            },
            [](uint64_t, const Tracker::MemoryTarget&, uint64_t offset, uint64_t size) {
                storedOffset = offset;
                storedSize = size;
            });
        const uint64_t device = 0xD1, pool = 0x9001, stats = 0x9002, other = 0x9003;
        t.queryPoolCreated(pool, 0xCA00000100000010ull, device, 0);
        t.queryPoolCreated(stats, 0xCA00000100000011ull, device, 1);
        t.queryPoolCreated(other, 0xCA00000100000012ull, 0xD2, 2);
        t.queriesReset(pool, 0, 8);
        t.queriesReset(stats, 0, 1);
        t.queriesReset(other, 0, 1);
        t.commandBufferBegun(0xc1);
        t.commandBufferQueries(0xc1, pool, 2, 1, true);
        t.commandBufferQueries(0xc1, pool, 3, 1, true);
        t.commandBufferQueries(0xc1, pool, 5, 1, true);
        t.commandBufferQueries(0xc1, stats, 0, 1, true);
        t.commandBufferQueries(0xc1, other, 0, 1, true);
        Tracker::Captures captures;
        captures.memory.push_back({0xA1, 0x55, 64, 4});
        const uint64_t s1 = t.submitted(0, {}, 0x9, device, {0xc1}, &captures);
        // Queries 2-3 and 5 of the occlusion pool and the memory: not the statistics pool,
        // nor a pool of another device.
        assert(captures.entries.size() == 3);
        assert(captures.entries[0] == (p::Entry{p::kQueryRange, 0xCA00000100000010ull, 2, 2}));
        assert(captures.entries[1] == (p::Entry{p::kQueryRange, 0xCA00000100000010ull, 5, 1}));
        assert(captures.entries[2] == (p::Entry{p::kMemoryRange, 0x55, 64, 4}));
        assert(t.queryValues(pool, 2, 2) == Tracker::Values::Pending);
        assert(t.queryValues(stats, 0, 1) == Tracker::Values::AskDevice);
        uint64_t out[4] = {};
        assert(t.queryResults(pool, 2, 2, sizeof(out), out, 16, p::k64Bit | p::kWithAvailability) == 1);
        assert(out[1] == 0 && out[3] == 0);
        assert(t.poolCaptured(pool) && !t.poolCaptured(stats));
        // The record comes through a socket as the feed stream carries it, after a fault
        // report (serial 0) the reader does not know.
        std::vector<uint8_t> payload;
        capture(payload, p::kQueryRange, 0, 0xCA00000100000010ull, 2, 2, {40, 1, 41, 1});
        capture(payload, p::kQueryRange, 1, 0xCA00000100000010ull, 5, 1, {0, 0});
        capture(payload, p::kMemoryRange, 0, 0x55, 64, 4, {}, {9, 8, 7, 6});
        int fds[2];
        assert(socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0);
        std::vector<uint8_t> fault;
        put(fault, uint32_t(20049));
        put(fault, int32_t(-3));
        std::vector<uint8_t> bytes = record(0, p::kFaultStatus, fault);
        const auto r1 = record(s1, kCompleted, payload);
        bytes.insert(bytes.end(), r1.begin(), r1.end());
        assert(write(fds[1], bytes.data(), bytes.size()) == ssize_t(bytes.size()));
        auto recv = [&](void* data, size_t size) { return recvAll(fds[0], data, size); };
        assert(readRecord(recv, t) && t.pendingWatches() == 1);  // the fault report
        assert(readRecord(recv, t) && t.pendingWatches() == 0);
        assert(shadow[64] == 9 && shadow[67] == 6 && storedOffset == 64 && storedSize == 4);
        assert(t.queryValues(pool, 2, 2) == Tracker::Values::Ready);
        assert(t.queryResults(pool, 2, 2, sizeof(out), out, 16, p::k64Bit | p::kWithAvailability | p::kWait) == 0);
        assert(out[0] == 40 && out[1] == 1 && out[2] == 41 && out[3] == 1);
        // Query 5 was captured unavailable (reset by later work): asked on the device.
        assert(t.queryValues(pool, 5, 1) == Tracker::Values::AskDevice);
        assert(t.queryResults(pool, 5, 1, 8, out, 8, p::k64Bit) == p::kAskDevice);
        assert(!t.poolCaptured(pool));
        // A reset forgets the values.
        t.queriesReset(pool, 2, 1);
        assert(t.queryResults(pool, 2, 1, 8, out, 8, p::k64Bit) == 1);
        // An idle wait completes a batch before its record: its queries wait for the record,
        // and its memory is not stored (the application may already use it).
        t.commandBufferBegun(0xc2);
        t.commandBufferQueries(0xc2, pool, 2, 1, true);
        Tracker::Captures second;
        second.memory.push_back({0xA1, 0x55, 128, 2});
        const uint64_t s2 = t.submitted(0, {}, 0x9, device, {0xc2}, &second);
        assert(second.entries.size() == 2);
        t.idle(0x9, device, s2);
        assert(t.serialCompleted(s2) && t.pendingValueRecords() == 1 && t.poolCaptured(pool));
        assert(t.queryValues(pool, 2, 1) == Tracker::Values::Pending);
        std::thread waiter([&] { assert(t.waitQueryValues(pool, 2, 1) == Tracker::Values::Ready); });
        std::thread destroyer([&] { t.waitPoolCaptures(pool); });
        payload.clear();
        capture(payload, p::kQueryRange, 0, 0xCA00000100000010ull, 2, 1, {77, 1});
        capture(payload, p::kMemoryRange, 0, 0x55, 128, 2, {}, {5, 5});
        const auto r2 = record(s2, kCompleted, payload);
        assert(write(fds[1], r2.data(), r2.size()) == ssize_t(r2.size()));
        assert(readRecord(recv, t));
        waiter.join();
        destroyer.join();
        assert(shadow[128] == 0 && t.pendingValueRecords() == 0 && !t.poolCaptured(pool));
        assert(t.queryResults(pool, 2, 1, 8, out, 8, p::k64Bit) == 0 && out[0] == 77);
        // Memory a later batch also writes is left to that batch's capture.
        t.commandBufferBegun(0xc3);
        Tracker::Captures third, fourth;
        third.memory.push_back({0xA1, 0x55, 256, 1});
        fourth.memory.push_back({0xA1, 0x55, 256, 1});
        const uint64_t s3 = t.submitted(0, {}, 0x9, device, {0xc3}, &third);
        const uint64_t s4 = t.submitted(0, {}, 0x9, device, {0xc3}, &fourth);
        payload.clear();
        capture(payload, p::kMemoryRange, 0, 0x55, 256, 1, {}, {3});
        t.completeRecord(s3, kCompleted, payload.data(), payload.size());
        assert(shadow[256] == 0);
        payload.clear();
        capture(payload, p::kMemoryRange, 0, 0x55, 256, 1, {}, {4});
        t.completeRecord(s4, kCompleted, payload.data(), payload.size());
        assert(shadow[256] == 4);
        // A record without payload (over the phone's bound, or an older phone) completes the
        // batch; its queries are then asked on the device.
        t.commandBufferBegun(0xc4);
        t.commandBufferQueries(0xc4, pool, 6, 1, true);
        Tracker::Captures fifth;
        const uint64_t s5 = t.submitted(0, {}, 0x9, device, {0xc4}, &fifth);
        assert(fifth.entries.size() == 1);
        const auto r5 = record(s5, kCompleted, {});
        assert(write(fds[1], r5.data(), r5.size()) == ssize_t(r5.size()));
        assert(readRecord(recv, t) && t.serialCompleted(s5) && !t.poolCaptured(pool));
        assert(t.queryValues(pool, 6, 1) == Tracker::Values::AskDevice);
        // A record announcing more than a record may carry ends the feed.
        std::vector<uint8_t> big;
        put(big, uint64_t(99)); put(big, int32_t(0)); put(big, uint32_t(p::kMaxPayload + 1));
        assert(write(fds[1], big.data(), big.size()) == ssize_t(big.size()));
        assert(!readRecord(recv, t));
        // A batch nobody watches leaves its queries to the device until they are reset.
        t.commandBufferBegun(0xc5);
        t.commandBufferQueries(0xc5, pool, 2, 1, true);
        t.queriesUntracked({0xc5});
        assert(t.queryValues(pool, 2, 1) == Tracker::Values::AskDevice);
        // A lost or ended feed: nothing is answered here and no destroy waits.
        t.commandBufferBegun(0xc6);
        t.commandBufferQueries(0xc6, pool, 1, 1, true);
        Tracker::Captures sixth;
        t.submitted(0, {}, 0x9, device, {0xc6}, &sixth);
        assert(t.poolCaptured(pool));
        t.feedClosed();
        assert(!t.poolCaptured(pool) && !t.waitPoolCaptures(pool));
        assert(t.queryResults(pool, 2, 1, 8, out, 8, p::k64Bit) == p::kAskDevice);
        close(fds[0]);
        close(fds[1]);
    }
    std::printf("completion payloads: ok\n");
}
