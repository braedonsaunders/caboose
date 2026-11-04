// SPDX-License-Identifier: MIT
// Coherent memory delivered by completion records: which captures count as delivered, that the
// driver is told of them before the batch completes, and what the invalidate after a wait
// still reads (the driver's use of takeDelivered, with a fake feed).
#include "completion_feed.h"

#include <atomic>
#include <cassert>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <thread>
#include <vector>

using namespace caboose::completion;
using caboose::memory::gpu::Span;
using caboose::memory::gpu::Spans;
namespace p = caboose::completion::payloads;

namespace {
template <class T> void put(std::vector<uint8_t>& b, T v) {
    const size_t at = b.size();
    b.resize(at + sizeof(T));
    std::memcpy(b.data() + at, &v, sizeof(T));
}
void memoryCapture(std::vector<uint8_t>& b, int32_t status, uint64_t handle, uint64_t offset,
                   const std::vector<uint8_t>& bytes) {
    put(b, p::kMemoryRange); put(b, status); put(b, handle); put(b, offset); put(b, uint64_t(bytes.size()));
    b.insert(b.end(), bytes.begin(), bytes.end());
    while (b.size() % 8) b.push_back(0);
}

constexpr uint64_t kMemory = 0xA1, kHandle = 0x55, kQueue = 0x9, kDevice = 0xD1;
uint8_t shadow[1 << 16];
Tracker* current = nullptr;
std::atomic<int> notes{0};
std::atomic<bool> notedBeforeCompletion{true};
std::atomic<bool> holdNotes{false}, inNote{false};
uint64_t watchedSerial = 0;

void hooks(Tracker& t) {
    current = &t;
    t.memoryHooks(
        [](uint64_t memory, Tracker::MemoryTarget* out) {
            if (memory != kMemory) return false;
            out->base = shadow;
            out->begin = 0;
            out->end = sizeof(shadow);
            out->allocation = sizeof(shadow);
            return true;
        },
        [](uint64_t, const Tracker::MemoryTarget&, uint64_t, uint64_t) {
            // The flush shadow and write watch are told while the batch is still outstanding.
            if (watchedSerial && current->serialCompleted(watchedSerial)) notedBeforeCompletion = false;
            inNote = true;
            while (holdNotes.load()) std::this_thread::sleep_for(std::chrono::milliseconds(1));
            ++notes;
        });
}

uint64_t submit(Tracker& t, const std::vector<std::pair<uint64_t, uint64_t>>& writes) {
    Tracker::Captures captures;
    for (const auto& [offset, size] : writes) captures.memory.push_back({kMemory, kHandle, offset, size});
    return t.submitted(0, {}, kQueue, kDevice, {}, &captures);
}

// The invalidate after the wait for `serial`, as the driver runs it: the batch's written spans
// less what its record delivered.
Spans toRead(Tracker& t, uint64_t serial, const Spans& written) {
    assert(t.serialCompleted(serial));
    Spans rest = written;
    Spans delivered;
    if (t.takeDelivered(kMemory, serial, &delivered)) rest.subtract(delivered);
    return rest;
}
Spans spansOf(const std::vector<std::pair<uint64_t, uint64_t>>& writes) {
    Spans s;
    for (const auto& [offset, size] : writes) s.add(offset, offset + size);
    return s;
}
}  // namespace

int main() {
    // A batch writes two ranges; its record brings both: nothing is read back, and the
    // driver heard of both before the batch completed.
    {
        Tracker t;
        hooks(t);
        const std::vector<std::pair<uint64_t, uint64_t>> writes{{64, 4}, {40000, 8}};
        const uint64_t s = submit(t, writes);
        watchedSerial = s;
        std::vector<uint8_t> payload;
        memoryCapture(payload, 0, kHandle, 64, {1, 2, 3, 4});
        memoryCapture(payload, 0, kHandle, 40000, {5, 6, 7, 8, 9, 10, 11, 12});
        notes = 0;
        t.completeRecord(s, kCompleted, payload.data(), payload.size());
        assert(notes == 2 && notedBeforeCompletion);
        assert(shadow[64] == 1 && shadow[40007] == 12);
        assert(toRead(t, s, spansOf(writes)).empty());
        // Handed out once.
        Spans again;
        assert(!t.takeDelivered(kMemory, s, &again) && t.deliveredEntries() == 0);
        watchedSerial = 0;
    }
    // Only part delivered (the rest past the record's entries or bytes): the rest is read.
    {
        Tracker t;
        hooks(t);
        const std::vector<std::pair<uint64_t, uint64_t>> writes{{0, 16}, {1024, 16}};
        const uint64_t s = submit(t, writes);
        std::vector<uint8_t> payload;
        memoryCapture(payload, 0, kHandle, 0, std::vector<uint8_t>(16, 3));
        t.completeRecord(s, kCompleted, payload.data(), payload.size());
        const Spans rest = toRead(t, s, spansOf(writes));
        assert(rest.size() == 1 && rest[0] == (Span{1024, 1040}));
    }
    // A capture of memory a later batch also writes is not delivered; the later batch's is.
    {
        Tracker t;
        hooks(t);
        const uint64_t older = submit(t, {{256, 4}});
        const uint64_t newer = submit(t, {{256, 4}});
        std::vector<uint8_t> payload;
        memoryCapture(payload, 0, kHandle, 256, {1, 1, 1, 1});
        t.completeRecord(older, kCompleted, payload.data(), payload.size());
        assert(toRead(t, older, spansOf({{256, 4}})).bytes() == 4);
        payload.clear();
        memoryCapture(payload, 0, kHandle, 256, {2, 2, 2, 2});
        t.completeRecord(newer, kCompleted, payload.data(), payload.size());
        assert(shadow[256] == 2 && toRead(t, newer, spansOf({{256, 4}})).empty());
    }
    // No payload (over the phone's bound, or no captures granted), a failed capture, or a
    // capture of another allocation: everything is read.
    {
        Tracker t;
        hooks(t);
        const uint64_t bare = submit(t, {{512, 8}});
        t.completeRecord(bare, kCompleted, nullptr, 0);
        assert(toRead(t, bare, spansOf({{512, 8}})).bytes() == 8);
        const uint64_t failed = submit(t, {{512, 8}});
        std::vector<uint8_t> payload;
        memoryCapture(payload, -2, kHandle, 512, std::vector<uint8_t>(8, 9));
        t.completeRecord(failed, kCompleted, payload.data(), payload.size());
        assert(shadow[512] != 9 && toRead(t, failed, spansOf({{512, 8}})).bytes() == 8);
        const uint64_t plain = t.submitted(0, {}, kQueue, kDevice, {}, nullptr);  // a plain watch
        t.complete(plain, kCompleted);
        Spans none;
        assert(!t.takeDelivered(kMemory, plain, &none));
        // A lost device's record stores nothing.
        const uint64_t lost = submit(t, {{512, 8}});
        t.completeRecord(lost, kDeviceLost, payload.data(), payload.size());
        assert(!t.takeDelivered(kMemory, lost, &none));
    }
    // An idle wait that completed the batch before its record: nothing is stored or delivered.
    {
        Tracker t;
        hooks(t);
        const uint64_t s = submit(t, {{600, 2}});
        t.idle(kQueue, kDevice, s);
        std::vector<uint8_t> payload;
        memoryCapture(payload, 0, kHandle, 600, {7, 7});
        t.completeRecord(s, kCompleted, payload.data(), payload.size());
        assert(shadow[600] != 7 && toRead(t, s, spansOf({{600, 2}})).bytes() == 2);
    }
    // An idle wait while a record is being stored waits until the driver has noted it, then
    // the stored bytes count as delivered.
    {
        Tracker t;
        hooks(t);
        const uint64_t s = submit(t, {{700, 2}});
        std::vector<uint8_t> payload;
        memoryCapture(payload, 0, kHandle, 700, {8, 8});
        holdNotes = true;
        inNote = false;
        std::thread feed([&] { t.completeRecord(s, kCompleted, payload.data(), payload.size()); });
        while (!inNote.load()) std::this_thread::sleep_for(std::chrono::milliseconds(1));
        assert(!t.serialCompleted(s));
        std::atomic<bool> idled{false};
        std::thread waiter([&] { t.idle(kQueue, kDevice, s); idled = true; });
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        assert(!idled.load());
        holdNotes = false;
        feed.join();
        waiter.join();
        assert(idled.load() && shadow[700] == 8 && toRead(t, s, spansOf({{700, 2}})).empty());
    }
    // More disjoint captures of one allocation than the spans hold exactly: the ones left out
    // are read back, never assumed delivered.
    {
        Tracker t;
        hooks(t);
        std::vector<std::pair<uint64_t, uint64_t>> writes;
        for (uint64_t i = 0; i <= Spans::kMaxSpans; ++i) writes.push_back({2048 + i * 100, 4});
        const uint64_t s = submit(t, writes);
        std::vector<uint8_t> payload;
        for (const auto& [offset, size] : writes) memoryCapture(payload, 0, kHandle, offset, std::vector<uint8_t>(size, 5));
        t.completeRecord(s, kCompleted, payload.data(), payload.size());
        Spans written;
        for (const auto& [offset, size] : writes) written.add(offset, offset + size);
        const Spans rest = toRead(t, s, written);
        assert(rest.bytes() >= 4);
        const auto& last = writes.back();
        assert(rest.covers(last.first, last.first + last.second));
    }
    // Delivered ranges nobody takes are bounded, and a new executor forgets them.
    {
        Tracker t;
        hooks(t);
        std::vector<uint8_t> payload;
        memoryCapture(payload, 0, kHandle, 0, {1});
        uint64_t first = 0;
        for (int i = 0; i < 4100; ++i) {
            const uint64_t s = submit(t, {{0, 1}});
            if (!first) first = s;
            t.completeRecord(s, kCompleted, payload.data(), payload.size());
        }
        assert(t.deliveredEntries() == 4096);
        Spans got;
        assert(!t.takeDelivered(kMemory, first, &got));  // the oldest went first
        t.revive();
        assert(t.deliveredEntries() == 0);
    }
    std::printf("delivered memory: ok\n");
}
