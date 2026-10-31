// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// Build: c++ -std=c++17 -Wall -Wextra -Werror -pthread -UNDEBUG -I apps/ios/GPUStream/gfxstream \
//   apps/ios/GPUStream/gfxstream/tests/completion_feed_test.cpp \
//   apps/ios/GPUStream/gfxstream/completion_feed.cpp -o /tmp/caboose-completion-feed-test
#include "completion_feed.h"
#include <cassert>
#include <condition_variable>
#include <cstring>
#include <map>
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
            return [this, queue] {
                std::unique_lock<std::mutex> lock(mutex);
                changed.wait(lock, [&] { return released.count(queue) != 0; });
                --outstanding;
                return released[queue];
            };
        };
    }
    void release(uint64_t queue, int result = 0) {
        std::lock_guard<std::mutex> lock(mutex);
        released[queue] = result;
        changed.notify_all();
    }
};
struct Record { uint64_t serial; int32_t status; };
Record readRecord(int fd) {
    unsigned char raw[CompletionFeed::kRecordSize];
    size_t got = 0;
    while (got < sizeof(raw)) {
        ssize_t n = read(fd, raw + got, sizeof(raw) - got);
        assert(n > 0);
        got += size_t(n);
    }
    Record r;
    std::memcpy(&r.serial, raw, 8);
    std::memcpy(&r.status, raw + 8, 4);
    uint32_t reserved; std::memcpy(&reserved, raw + 12, 4);
    assert(reserved == 0);
    return r;
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
        gpu.release(0x1);
        r = readRecord(sockets[0]);
        assert(r.serial == 1 && r.status == CompletionFeed::kCompleted);
        gpu.release(0x2, -4);
        r = readRecord(sockets[0]);
        assert(r.serial == 3 && r.status == CompletionFeed::kDeviceLost);
        // A second feed stream is refused.
        int other[2];
        assert(socketpair(AF_UNIX, SOCK_STREAM, 0, other) == 0);
        assert(completions.run(other[1], stop) == EBUSY);
        ::close(other[0]); ::close(other[1]);
        // A marker outstanding when the guest closes is still waited for (it holds its
        // device), and its record is dropped.
        completions.watch(0x3, 4);
        shutdown(sockets[0], SHUT_WR);
        reader.join();
        gpu.release(0x3);
    }  // destruction joins the watcher after every marker completed
    assert(gpu.outstanding == 0 && gpu.submitted == 3);
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
