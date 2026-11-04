// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// Build: c++ -std=c++17 -Wall -Wextra -Werror -pthread -UNDEBUG -I apps/ios/GPUStream/gfxstream \
//   apps/ios/GPUStream/gfxstream/tests/completion_feed_test.cpp \
//   apps/ios/GPUStream/gfxstream/completion_feed.cpp -o /tmp/caboose-completion-feed-test
#include "completion_feed.h"
#include "silent_replies.h"
#include <atomic>
#include <cassert>
#include <cerrno>
#include <condition_variable>
#include <cstring>
#include <chrono>
#include <map>
#include <vector>
#include <thread>
#include <sys/socket.h>
#include <unistd.h>
using caboose::gpuv2::CompletionFeed;

namespace {
// A fake GPU: each submitted marker completes when the test releases its queue.
struct Gpu {
    std::mutex mutex;
    std::condition_variable changed;
    std::map<uint64_t, int> released;  // queue -> result, once released
    int submitted = 0, outstanding = 0;
    CompletionFeed::Submit submit() {
        return [this](uint64_t queue) -> CompletionFeed::Waiter {
            if (queue == 0xBAD) return {};
            std::lock_guard<std::mutex> lock(mutex);
            ++submitted; ++outstanding;
            return [this, queue](const CompletionFeed::AfterFence& afterFence) {
                int result;
                {
                    std::unique_lock<std::mutex> lock(mutex);
                    changed.wait(lock, [&] { return released.count(queue) != 0; });
                    result = released[queue];
                }
                // A fake capture: each query's value is handle + index, available; memory
                // bytes count up from the offset. A handle of 0xF41 fails its capture.
                if (result == 0) afterFence([](const CompletionFeed::Capture& c, unsigned char* out) -> int32_t {
                    if (c.handle == 0xF41) return -2;
                    if (c.kind == CompletionFeed::kCaptureQueries) {
                        for (uint64_t i = 0; i < c.b; ++i) {
                            const uint64_t value = c.handle + c.a + i, available = 1;
                            std::memcpy(out + i * 16, &value, 8);
                            std::memcpy(out + i * 16 + 8, &available, 8);
                        }
                    } else {
                        for (uint64_t i = 0; i < c.b; ++i) out[i] = (unsigned char)(c.a + i);
                    }
                    return 0;
                });
                std::lock_guard<std::mutex> lock(mutex);
                --outstanding;
                return result;
            };
        };
    }
    int pending() {
        std::lock_guard<std::mutex> lock(mutex);
        return outstanding;
    }
    void release(uint64_t queue, int result = 0) {
        std::lock_guard<std::mutex> lock(mutex);
        released[queue] = result;
        changed.notify_all();
    }
};
struct Record { uint64_t serial; int32_t status; std::vector<unsigned char> payload; };
void readExactly(int fd, unsigned char* out, size_t size) {
    size_t got = 0;
    while (got < size) {
        ssize_t n = read(fd, out + got, size - got);
        assert(n > 0);
        got += size_t(n);
    }
}
Record readRecord(int fd) {
    unsigned char raw[CompletionFeed::kRecordSize];
    readExactly(fd, raw, sizeof(raw));
    Record r;
    std::memcpy(&r.serial, raw, 8);
    std::memcpy(&r.status, raw + 8, 4);
    uint32_t payload; std::memcpy(&payload, raw + 12, 4);
    r.payload.resize(payload);
    if (payload) readExactly(fd, r.payload.data(), payload);
    return r;
}
std::vector<unsigned char> watch2(uint64_t queue, uint64_t serial, const std::vector<CompletionFeed::Capture>& captures) {
    std::vector<unsigned char> p(32 + 32 * captures.size(), 0);
    const uint32_t op = CompletionFeed::kWatch2Opcode, size = (uint32_t)p.size(), count = (uint32_t)captures.size();
    std::memcpy(p.data(), &op, 4); std::memcpy(p.data() + 4, &size, 4);
    std::memcpy(p.data() + 8, &queue, 8); std::memcpy(p.data() + 16, &serial, 8);
    std::memcpy(p.data() + 24, &count, 4);
    for (size_t i = 0; i < captures.size(); ++i) {
        unsigned char* e = p.data() + 32 + 32 * i;
        std::memcpy(e, &captures[i].kind, 4);
        std::memcpy(e + 8, &captures[i].handle, 8);
        std::memcpy(e + 16, &captures[i].a, 8);
        std::memcpy(e + 24, &captures[i].b, 8);
    }
    return p;
}
}  // namespace

int main() {
    unsigned char watch[24], feed[16];
    const uint32_t wop = CompletionFeed::kWatchOpcode, wsize = 24, fop = CompletionFeed::kFeedOpcode, fsize = 16, one = 1, zero = 0;
    const uint64_t q = 0x77, s = 9;
    std::memcpy(watch, &wop, 4); std::memcpy(watch + 4, &wsize, 4); std::memcpy(watch + 8, &q, 8); std::memcpy(watch + 16, &s, 8);
    std::memcpy(feed, &fop, 4); std::memcpy(feed + 4, &fsize, 4); std::memcpy(feed + 8, &one, 4); std::memcpy(feed + 12, &zero, 4);
    uint64_t queue = 0, serial = 0;
    assert(CompletionFeed::parseWatch(watch, 24, &queue, &serial) && queue == q && serial == s);
    assert(!CompletionFeed::parseWatch(watch, 23, &queue, &serial));
    assert(CompletionFeed::parseFeed(feed, 16));
    feed[8] = 2;
    assert(!CompletionFeed::parseFeed(feed, 16));
    assert(CompletionFeed::isFeedOpcode(wop) && CompletionFeed::isFeedOpcode(fop) && !CompletionFeed::isFeedOpcode(20021));

    Gpu gpu;
    int sockets[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
    std::atomic_bool stop{false};
    {
        CompletionFeed completions(gpu.submit());
        // A watch made before the feed attaches is kept for it; an unwatchable queue is
        // reported at once.
        completions.watch(0x1, 1);
        completions.watch(0xBAD, 2);
        std::thread reader([&] { assert(completions.run(sockets[1], stop) == 0); });
        Record r = readRecord(sockets[0]);
        assert(r.serial == 2 && r.status == CompletionFeed::kUnwatched);
        completions.watch(0x2, 3);
        // What a stall report reads: the oldest marker still waited for and what was sent.
        for (int i = 0; i < 200 && completions.state().lastWrittenSerial != 2; ++i) usleep(5000);
        auto state = completions.state();
        assert(state.watches == 3 && state.unwatched == 1 && state.outstanding == 2);
        assert(state.oldestSerial == 1 && state.oldestQueue == 0x1 && state.oldestWatchedMs > 0);
        assert(state.lastWrittenSerial == 2 && state.lastCompletedSerial == 0 && state.feedAttached);
        gpu.release(0x1);
        r = readRecord(sockets[0]);
        assert(r.serial == 1 && r.status == CompletionFeed::kCompleted);
        state = completions.state();
        assert(state.lastCompletedSerial == 1 && state.lastStatus == CompletionFeed::kCompleted);
        assert(state.outstanding == 1 && state.oldestSerial == 3 && state.oldestQueue == 0x2);
        gpu.release(0x2, -4);
        r = readRecord(sockets[0]);
        assert(r.serial == 3 && r.status == CompletionFeed::kDeviceLost);
        // A later feed stream (the guest connected again) takes over; the earlier returns.
        int other[2];
        assert(socketpair(AF_UNIX, SOCK_STREAM, 0, other) == 0);
        std::thread second([&] { assert(completions.run(other[1], stop) == 0); });
        reader.join();
        completions.watch(0x5, 6);
        gpu.release(0x5);
        r = readRecord(other[0]);
        assert(r.serial == 6 && r.status == CompletionFeed::kCompleted);
        // A marker outstanding when the guest closes is still waited for (it holds its
        // device), and its record is dropped.
        completions.watch(0x3, 4);
        shutdown(other[0], SHUT_WR);
        second.join();
        ::close(other[0]); ::close(other[1]);
        // After the guest is gone, a late watch from the device stream submits nothing,
        // and the outstanding marker is still waited for by the watcher.
        completions.watch(0x4, 5);
        gpu.release(0x3);
        for (int i = 0; i < 200 && gpu.pending(); ++i) usleep(5000);
        assert(gpu.pending() == 0);
    }  // destruction joins the watcher after every marker completed
    assert(gpu.pending() == 0 && gpu.submitted == 4);
    ::close(sockets[0]); ::close(sockets[1]);

    // Bytes after the feed command are a protocol violation.
    {
        CompletionFeed completions(gpu.submit());
        int pair[2];
        assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
        const char junk = 1;
        assert(write(pair[0], &junk, 1) == 1);
        assert(completions.run(pair[1], stop) == EPROTO);
        ::close(pair[0]); ::close(pair[1]);
    }
    // ORDER marks: a wait returns once the mark (or a later one) is decoded, and stop
    // cancels waits that can no longer be satisfied.
    {
        CompletionFeed completions(gpu.submit());
        unsigned char order[16];
        const uint32_t oop = CompletionFeed::kOrderOpcode, osize = 16;
        const uint64_t mark = 5;
        std::memcpy(order, &oop, 4); std::memcpy(order + 4, &osize, 4); std::memcpy(order + 8, &mark, 8);
        uint64_t parsed = 0;
        assert(CompletionFeed::parseOrder(order, 16, &parsed) && parsed == 5);
        assert(!CompletionFeed::parseOrder(order, 15, &parsed));
        assert(CompletionFeed::isFeedOpcode(oop) && CompletionFeed::packetSize(oop) == 16);
        completions.ordered(3);
        assert(completions.waitOrdered(2) == 0 && completions.waitOrdered(3) == 0);
        std::atomic_bool done{false};
        std::thread waiter([&] { assert(completions.waitOrdered(5) == 0); done = true; });
        completions.ordered(4);
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
        assert(!done);
        completions.ordered(6);  // a later mark satisfies an earlier wait
        waiter.join();
        assert(done);
        completions.ordered(1);  // marks never go backwards
        assert(completions.waitOrdered(6) == 0);
        std::thread stopped([&] { assert(completions.waitOrdered(9) == ECANCELED); });
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
        completions.cancelOrders();
        stopped.join();
        assert(completions.waitOrdered(10) == ECANCELED && completions.waitOrdered(6) == 0);
    }
    // Each queue retires on its own: a queue whose work is still running holds back no
    // record of another queue, and the stall report names the marker waited for longest.
    {
        Gpu lanes;
        CompletionFeed completions(lanes.submit());
        int pair[2];
        assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
        std::thread reader([&] { assert(completions.run(pair[1], stop) == 0); });
        completions.watch(0x10, 1);  // long work on queue 0x10
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
        completions.watch(0x20, 2);
        completions.watch(0x20, 3);
        lanes.release(0x20);
        Record a = readRecord(pair[0]), b = readRecord(pair[0]);
        assert(a.serial == 2 && b.serial == 3);  // in order within the queue
        auto state = completions.state();
        assert(state.outstanding == 1 && state.oldestSerial == 1 && state.oldestQueue == 0x10);
        assert(state.lanes == 2);
        // More queues than lanes: they share lanes, every watch is still reported, and the
        // long queue's lane takes no other marker while it has the fewest elsewhere.
        for (uint64_t q = 0x100; q < 0x100 + 3 * CompletionFeed::kMaxLanes; ++q) {
            completions.watch(q, q);
            lanes.release(q);
            Record r = readRecord(pair[0]);
            assert(r.serial == q && r.status == CompletionFeed::kCompleted);
        }
        assert(completions.state().lanes == CompletionFeed::kMaxLanes);
        assert(completions.state().outstanding == 1);
        lanes.release(0x10);
        Record late = readRecord(pair[0]);
        assert(late.serial == 1 && late.status == CompletionFeed::kCompleted);
        shutdown(pair[0], SHUT_WR);
        reader.join();
        ::close(pair[0]); ::close(pair[1]);
    }
    // WAIT_SERIAL: a barrier returns once its watch is resolved, whatever the other queues do.
    {
        Gpu barrier;
        CompletionFeed completions(barrier.submit());
        unsigned char packet[16];
        const uint32_t op = CompletionFeed::kWaitSerialOpcode, size = 16;
        const uint64_t named = 7;
        std::memcpy(packet, &op, 4); std::memcpy(packet + 4, &size, 4); std::memcpy(packet + 8, &named, 8);
        uint64_t parsed = 0;
        assert(CompletionFeed::parseWaitSerial(packet, 16, &parsed) && parsed == 7);
        assert(!CompletionFeed::parseWaitSerial(packet, 15, &parsed));
        assert(CompletionFeed::isFeedOpcode(op) && CompletionFeed::packetSize(op) == 16);
        // A barrier above the last watch is the guest's protocol error.
        assert(completions.waitSerial(1) == EPROTO);
        completions.watch(0x10, 1);   // long work
        completions.watch(0x20, 2);
        completions.watch(0xBAD, 3);  // unwatched: resolved at once
        assert(completions.waitSerial(3) == 0 && completions.serialResolved(3));
        std::atomic_bool done{false};
        std::thread waiter([&] { assert(completions.waitSerial(2) == 0); done = true; });
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        assert(!done && !completions.serialResolved(2));
        barrier.release(0x20);
        waiter.join();
        assert(!completions.serialResolved(1));
        // Process stop cancels a barrier still waiting.
        std::thread stopped([&] { assert(completions.waitSerial(1) == ECANCELED); });
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
        completions.cancelOrders();
        stopped.join();
        barrier.release(0x10);
        // A device-lost marker resolves its barrier too.
        Gpu lost;
        CompletionFeed other(lost.submit());
        other.watch(0x30, 4);
        lost.release(0x30, -4);
        assert(other.waitSerial(4) == 0);
        // Serials skipped by the guest were never watched: nothing to wait for.
        assert(other.waitSerial(2) == 0);
    }
    // WATCH2: the captures arrive with the record, after the marker completed.
    {
        using C = CompletionFeed::Capture;
        const std::vector<C> captures = {{CompletionFeed::kCaptureQueries, 0x500, 3, 2},
                                         {CompletionFeed::kCaptureMemory, 0x600, 16, 5},
                                         {CompletionFeed::kCaptureQueries, 0xF41, 0, 1}};
        auto packet = watch2(0x40, 11, captures);
        assert(CompletionFeed::watch2Size(packet.data()) == packet.size());
        uint64_t queue = 0, serial = 0;
        std::vector<C> parsed;
        assert(CompletionFeed::parseWatch2(packet.data(), packet.size(), &queue, &serial, &parsed));
        assert(queue == 0x40 && serial == 11 && parsed.size() == 3 && parsed[1].a == 16 && parsed[1].b == 5);
        // Malformed: a short size, an unknown kind, a nonzero flags word, an empty range.
        assert(!CompletionFeed::parseWatch2(packet.data(), packet.size() - 32, &queue, &serial, &parsed));
        auto bad = packet; bad[32] = 9;
        assert(!CompletionFeed::parseWatch2(bad.data(), bad.size(), &queue, &serial, &parsed));
        bad = packet; bad[28] = 1;
        assert(!CompletionFeed::parseWatch2(bad.data(), bad.size(), &queue, &serial, &parsed));
        bad = watch2(0x40, 11, {{CompletionFeed::kCaptureMemory, 0x600, 0, 0}});
        assert(!CompletionFeed::parseWatch2(bad.data(), bad.size(), &queue, &serial, &parsed));
        assert(CompletionFeed::isFeedOpcode(CompletionFeed::kWatch2Opcode));

        Gpu gpu2;
        CompletionFeed completions(gpu2.submit());
        int pair[2];
        assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
        std::thread reader([&] { assert(completions.run(pair[1], stop) == 0); });
        completions.watch(0x40, 11, captures);
        gpu2.release(0x40);
        Record r = readRecord(pair[0]);
        assert(r.serial == 11 && r.status == CompletionFeed::kCompleted);
        // Entries: 32-byte header + data padded to 8: 32+32, 32+8, 32+16.
        assert(r.payload.size() == 64 + 40 + 48);
        auto u64at = [&](size_t at) { uint64_t v; std::memcpy(&v, r.payload.data() + at, 8); return v; };
        auto i32at = [&](size_t at) { int32_t v; std::memcpy(&v, r.payload.data() + at, 4); return v; };
        assert(i32at(0) == 1 && i32at(4) == 0 && u64at(8) == 0x500 && u64at(16) == 3 && u64at(24) == 2);
        assert(u64at(32) == 0x503 && u64at(40) == 1 && u64at(48) == 0x504 && u64at(56) == 1);
        assert(i32at(64) == 2 && u64at(72) == 0x600 && r.payload[96] == 16 && r.payload[100] == 20);
        assert(i32at(104) == 1 && i32at(108) == -2);  // a failed capture says so
        // Over the per-record bound, the payload is empty and the guest asks as before.
        completions.watch(0x41, 12, {{CompletionFeed::kCaptureMemory, 0x600, 0, CompletionFeed::kMaxPayload}});
        gpu2.release(0x41);
        r = readRecord(pair[0]);
        assert(r.serial == 12 && r.status == CompletionFeed::kCompleted && r.payload.empty());
        // A lost device's captures are not sent.
        completions.watch(0x42, 13, captures);
        gpu2.release(0x42, -4);
        r = readRecord(pair[0]);
        assert(r.serial == 13 && r.status == CompletionFeed::kDeviceLost && r.payload.empty());
        // A plain WATCH still has an empty payload.
        completions.watch(0x43, 14);
        gpu2.release(0x43);
        r = readRecord(pair[0]);
        assert(r.serial == 14 && r.payload.empty());
        // A silent command's failure: serial 0, the fault status, opcode and result.
        completions.fault(20021u, -2);
        r = readRecord(pair[0]);
        assert(r.serial == 0 && r.status == CompletionFeed::kFault && r.payload.size() == 8);
        uint32_t op; int32_t res;
        std::memcpy(&op, r.payload.data(), 4); std::memcpy(&res, r.payload.data() + 4, 4);
        assert(op == 20021u && res == -2);
        shutdown(pair[0], SHUT_WR);
        reader.join();
        ::close(pair[0]); ::close(pair[1]);
    }
    // Silent-success replies: the listed commands, their result, the REPLY_MODE packet.
    {
        namespace sr = caboose::gpuv2::silent_replies;
        assert(sr::listed(20018u) && sr::listed(20065u) && !sr::listed(20024u));
        std::vector<unsigned char> reply(12, 0);
        assert(sr::resultOf(20021u, reply) == 0);
        const int32_t oom = -2; std::memcpy(reply.data() + 8, &oom, 4);
        assert(sr::resultOf(20021u, reply) == -2);
        assert(sr::resultOf(20089u, {}) == 0);   // void
        assert(sr::resultOf(20018u, {}) != 0);   // a result was due and none came
        unsigned char mode[16] = {};
        const uint32_t mop = sr::kReplyModeOpcode, msize = 16, one = 1;
        std::memcpy(mode, &mop, 4); std::memcpy(mode + 4, &msize, 4); std::memcpy(mode + 8, &one, 4);
        assert(sr::parseReplyMode(mode, 16) == 1);
        mode[12] = 1;
        assert(sr::parseReplyMode(mode, 16) == 0);
        mode[12] = 0; mode[8] = 2;
        assert(sr::parseReplyMode(mode, 16) == 0);
        // One-way start: REPLY_MODE(3) also silences the commands that start a process's Vulkan.
        mode[8] = 3;
        assert(sr::parseReplyMode(mode, 16) == 3);
        for (uint32_t op : {20000u, 20002u, 20011u, 20017u, 20155u}) {
            assert(!sr::listed(op) && !sr::listed(op, 1) && sr::listed(op, 3));
        }
        assert(sr::listed(20021u, 3) && !sr::listed(20024u, 3));
        // A queue's reply is its handle: none is a failure.
        std::vector<unsigned char> queue(8, 0);
        assert(sr::resultOf(20155u, queue) == -3 && sr::resultOf(20017u, {}) == -3);
        queue[7] = 0xCA;
        assert(sr::resultOf(20155u, queue) == 0);
        // A failed create's held reply: its handle, then its VkResult.
        std::vector<unsigned char> instance(12, 0);
        const int32_t missing = -7;  // VK_ERROR_EXTENSION_NOT_PRESENT
        std::memcpy(instance.data() + 8, &missing, 4);
        assert(sr::resultOf(20000u, instance) == -7);
    }
    // Process stop: the socket is shut down and run returns 0.
    {
        CompletionFeed completions(gpu.submit());
        int pair[2];
        assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
        std::thread reader([&] { assert(completions.run(pair[1], stop) == 0); });
        stop = true;
        shutdown(pair[1], SHUT_RDWR);
        reader.join();
        ::close(pair[0]); ::close(pair[1]);
    }
    return 0;
}
