// SPDX-License-Identifier: MIT
#include "deferred_replies.h"
#include <cassert>
#include <cstring>
#include <vector>
using namespace caboose::memory;

namespace {
struct Stream {
    std::vector<int32_t> replies;
    size_t next = 0;
    bool invalidated = false;
    bool tryRead(void* out, size_t size) {
        if (size != sizeof(int32_t) || next == replies.size()) return false;
        std::memcpy(out, &replies[next++], size);
        return true;
    }
    void invalidate() { invalidated = true; }
};

// A reply stream of raw bytes, for replies that are not a single 4-byte result.
struct ByteStream {
    std::vector<uint8_t> bytes;
    size_t next = 0;
    bool invalidated = false;
    template <class T> void put(T value) {
        const auto* raw = reinterpret_cast<const uint8_t*>(&value);
        bytes.insert(bytes.end(), raw, raw + sizeof(value));
    }
    bool tryRead(void* out, size_t size) {
        if (bytes.size() - next < size) return false;
        std::memcpy(out, bytes.data() + next, size);
        next += size;
        return true;
    }
    void invalidate() { invalidated = true; }
};
} // namespace

int main() {
    Stream stream{{0, 0, -4, 0, 7}};
    uint32_t pending = 0;
    assert(drainDeferredReplies(pending, &stream) && stream.next == 0);

    // Drains exactly the pending replies, in order, tolerating reported failures.
    pending = 3;
    assert(drainDeferredReplies(pending, &stream) && pending == 0 && stream.next == 3);
    assert(!stream.invalidated);

    // Later replies are left for their own command.
    pending = 1;
    assert(drainDeferredReplies(pending, &stream) && stream.next == 4);

    // A short stream is a transport failure: nothing stays pending.
    pending = 3;
    assert(!drainDeferredReplies(pending, &stream) && pending == 0 && stream.invalidated);

    // Per-encoder counts drain only their own encoder's replies.
    DeferredReplies table;
    int a = 0, b = 0;
    Stream first{{0, 0, 0, 0}}, second{{0}};
    assert(table.drain(&a, &first) && first.next == 0);
    table.add(&a, 2, 100); table.add(&b, 1, 100); table.add(&a, 1, 100); table.add(&a, 0, 100);
    assert(table.pending() == 4);
    assert(table.drain(&b, &second) && second.next == 1 && table.pending() == 3);

    // Reserving within the byte limit keeps replies pending; past it drains them.
    assert(table.reserve(&a, &first, 800, 1000) && first.next == 0 && table.pending() == 3);
    assert(table.reserve(&a, &first, 801, 1000) && first.next == 3 && table.pending() == 0);

    // The default bound lets commands run megabytes ahead while their replies stay small,
    // and drains the oldest half once past it, leaving newer replies in flight instead of
    // stalling on the newest just-sent command.
    {
        DeferredReplies big;
        Stream results;
        results.replies.assign(4, 0);
        big.addCheckedResults(&a, 1, deferredByteLimit - 2 * 1024 * 1024);  // one large flush, one result
        assert(big.reserve(&a, &results, 1024 * 1024) && results.next == 0);
        assert(big.reserve(&a, &results, 3 * 1024 * 1024) && results.next == 1 && big.pending() == 0);  // past the bound
    }
    // Eight frames of 3 MiB of commands, each with a submit, a flush and a few hundred binds
    // and resets, run ahead of the phone without waiting; the ninth waits for the oldest.
    {
        DeferredReplies frames;
        Stream results;
        constexpr uint32_t perFrame = 400;
        constexpr uint64_t frameBytes = 3 * 1024 * 1024;
        results.replies.assign(10 * perFrame, 0);
        for (int frame = 0; frame < 8; ++frame) {
            assert(frames.reserve(&a, &results, frameBytes, deferredByteLimit, [] { return size_t(0); }));
            frames.addCheckedResults(&a, perFrame, frameBytes);
        }
        assert(results.next == 0 && frames.pending() == 8 * perFrame);
        assert(frames.reserve(&a, &results, frameBytes, deferredByteLimit, [] { return size_t(0); }));
        assert(results.next == 5 * perFrame && frames.pending() == 3 * perFrame);  // within half the bound again
        assert(frames.drain(&a, &results) && frames.pending() == 0);
    }
    // Past 64 KiB of owed reply bytes the oldest are read until half that is owed.
    {
        DeferredReplies wide;
        ByteStream replies;
        auto owe = [&](uint32_t count) {
            for (uint32_t i = 0; i < count; ++i) {
                auto data = std::make_shared<QueryReply>();
                data->data.resize(60);
                for (int b = 0; b < 60; ++b) replies.bytes.push_back(0);
                replies.put<int32_t>(0);
                wide.addDataReply(&a, std::move(data), 64);
            }
        };
        const uint32_t fill = uint32_t(deferredReplyByteLimit / 64);  // exactly the bound
        owe(fill);
        assert(wide.reserve(&a, &replies, 64, deferredByteLimit, [] { return size_t(0); }) && replies.next == 0);
        owe(1);
        assert(wide.reserve(&a, &replies, 64, deferredByteLimit, [] { return size_t(0); }));
        assert(wide.pending() == fill / 2 && replies.next == (fill / 2 + 1) * 64 && !replies.invalidated);
        assert(wide.drain(&a, &replies) && replies.next == replies.bytes.size());
    }
    // At most 16384 results are owed (64 KiB); past that the oldest are read until half is.
    {
        DeferredReplies count;
        Stream results;
        const uint32_t most = uint32_t(deferredReplyByteLimit / sizeof(int32_t));
        assert(most == 16384);
        results.replies.assign(most + 1, 0);
        count.add(&a, most, 64);
        assert(count.reserve(&a, &results, 64, deferredByteLimit, [] { return size_t(0); }) && results.next == 0);
        count.add(&a, 1, 64);
        assert(count.reserve(&a, &results, 64, deferredByteLimit, [] { return size_t(0); }));
        assert(results.next == most / 2 + 1 && count.pending() == most / 2);
        assert(count.drain(&a, &results) && count.pending() == 0);
    }
    // Non-blocking available() inside reserve() consumes already-arrived replies first,
    // avoiding a blocking drain when enough bytes are sitting in the socket buffer.
    {
        DeferredReplies nonblock;
        Stream results{{0, 0, 0, 0}};
        nonblock.addCheckedResult(&a, 400);
        nonblock.addCheckedResult(&a, 400);
        nonblock.addCheckedResult(&a, 400);
        assert(nonblock.reserve(&a, &results, 300, 1200, [] { return size_t(8); }));
        assert(results.next == 2 && nonblock.pending() == 1);
    }
    // Within the bounds, arrived replies are read without blocking once 256 KiB of commands
    // or 4 KiB of replies are owed, and never while less is.
    {
        DeferredReplies reap;
        Stream results;
        results.replies.assign(2048, 0);
        reap.addCheckedResults(&a, 1023, 1024);  // 4092 bytes of replies owed: below the mark
        assert(reap.reserve(&a, &results, 64, deferredByteLimit, [] { return size_t(4096); }));
        assert(results.next == 0 && reap.pending() == 1023);
        reap.addCheckedResult(&a, 64);           // 4096 bytes: the arrived ones are read
        assert(reap.reserve(&a, &results, 64, deferredByteLimit, [] { return size_t(400); }));
        assert(results.next == 100 && reap.pending() == 924);
        reap.addCheckedResult(&a, deferredReapBytes);  // past 256 KiB of commands
        assert(reap.reserve(&a, &results, 64, deferredByteLimit, [] { return size_t(40); }));
        assert(results.next == 110 && reap.pending() == 915);
        assert(reap.drain(&a, &results) && results.next == 1025 && reap.pending() == 0);
    }
    table.add(&a, 1, 10);
    assert(table.drain(&a, &first) && first.next == 4);
    assert(table.drain(&a, &first) && first.next == 4);

    // A successful prefetched wait marks its fence signaled, in stream order.
    DeferredReplies fences;
    Stream waits{{0, 0, 2, 0, 0, 0}};
    const uint64_t f1 = 0x10, f2 = 0x20, f3 = 0x30;
    const uint64_t both[] = {f1, f2};
    fences.add(&a, 1, 4);
    fences.addFenceWait(&a, f1, 4);
    fences.addFenceWait(&a, f2, 4);
    assert(!fences.signaled(&f1, 1, true));
    assert(fences.drain(&a, &waits) && waits.next == 3);
    assert(fences.signaled(&f1, 1, true) && !fences.signaled(&f2, 1, true));
    assert(!fences.signaled(both, 2, true) && fences.signaled(both, 2, false));

    // Reset forgets the result and discards a prefetch still in flight.
    fences.forgetFence(f1);
    assert(!fences.signaled(&f1, 1, true));
    fences.addFenceWait(&a, f3, 4);
    fences.forgetFence(f3);
    fences.addFenceWait(&a, f1, 4);
    assert(fences.drain(&a, &waits) && waits.next == 5);
    assert(!fences.signaled(&f3, 1, true) && fences.signaled(&f1, 1, false));

    // A fence created signaled is known signaled until it is reset.
    fences.markSignaled(f3);
    assert(fences.signaled(&f3, 1, true));
    fences.forgetFence(f3);
    assert(!fences.signaled(&f3, 1, true));

    // A guest-assigned create's reply is the handle and its result, drained in order
    // with ordinary results.
    const uint64_t handle = 0xCA00010000000001ull;
    {
        DeferredReplies creates;
        ByteStream replies;
        replies.put<int32_t>(0); replies.put<uint64_t>(handle); replies.put<int32_t>(0);
        creates.add(&a, 1, 4);
        creates.addHandleCreate(&a, handle, 40);
        assert(creates.drain(&a, &replies) && replies.next == replies.bytes.size());
        assert(!replies.invalidated && creates.pending() == 0);
    }
    // A device that renamed or refused the handle has diverged: the stream is lost.
    for (const auto& reply : {std::pair<uint64_t, int32_t>{handle + 1, 0},
                              std::pair<uint64_t, int32_t>{handle, -2}}) {
        DeferredReplies creates;
        ByteStream replies;
        replies.put<uint64_t>(reply.first); replies.put<int32_t>(reply.second);
        creates.addHandleCreate(&a, handle, 40);
        assert(!creates.drain(&a, &replies) && replies.invalidated);
    }
    // A truncated create reply is a transport failure.
    {
        DeferredReplies creates;
        ByteStream replies;
        replies.put<uint64_t>(handle);
        creates.addHandleCreate(&a, handle, 40);
        assert(!creates.drain(&a, &replies) && replies.invalidated && creates.pending() == 0);
    }
    // A reply of data only (a pool's set ids) is read whole and nothing after it; a result
    // queued behind it is still drained in order.
    {
        DeferredReplies table;
        ByteStream replies;
        replies.put<uint32_t>(2); replies.put<uint64_t>(1); replies.put<uint64_t>(0x51); replies.put<uint64_t>(0x52);
        replies.put<int32_t>(0);
        auto ids = std::make_shared<QueryReply>();
        ids->data.resize(4 + 8 + 2 * 8);
        table.addDataReply(&a, ids, 32, false);
        table.add(&a, 1, 4);
        assert(table.drain(&a, &replies) && !replies.invalidated && replies.next == replies.bytes.size());
        assert(ids->done.load() && table.pending() == 0);
        uint64_t second = 0; std::memcpy(&second, ids->data.data() + 20, 8);
        assert(second == 0x52);
    }
    // A truncated data reply is a transport failure.
    {
        DeferredReplies table;
        ByteStream replies;
        replies.put<uint32_t>(2); replies.put<uint64_t>(1);
        auto ids = std::make_shared<QueryReply>();
        ids->data.resize(4 + 8 + 2 * 8);
        table.addDataReply(&a, ids, 32, false);
        assert(!table.drain(&a, &replies) && replies.invalidated && !ids->done.load());
    }

    // An unchecked deferred failure is reported and tolerated; a checked one
    // (a result the application can no longer observe) loses the stream.
    {
        DeferredReplies results;
        Stream replies{{-4, 0, -4}};
        results.add(&a, 1, 4);
        results.addCheckedResult(&a, 4);
        assert(results.drain(&a, &replies) && !replies.invalidated && replies.next == 2);
        results.addCheckedResult(&a, 4);
        assert(!results.drain(&a, &replies) && replies.invalidated);
    }

    // The first encoder to ask owns deferral; once a second asks, neither may defer.
    {
        DeferredReplies owner;
        int first = 0, second = 0;
        assert(owner.singleEncoder(&first) && owner.singleEncoder(&first));
        assert(!owner.singleEncoder(&second));
        assert(!owner.singleEncoder(&first) && !owner.singleEncoder(&second));
    }

    // QueryResults holds up to 8192 active queries and prefers evicting completed ones
    // before ever evicting an in-flight (!done) query.
    {
        QueryResults qr;
        assert(QueryResults::kMaxEntries == 8192 && QueryResults::kMaxRecorded == 1024);
        auto inFlight = std::make_shared<QueryReply>();
        qr.requested({0x100, 0, 1, 8, 8, 0}, inFlight);
        for (uint32_t i = 1; i < QueryResults::kMaxEntries; ++i) {
            auto doneReply = std::make_shared<QueryReply>();
            doneReply->done.store(true, std::memory_order_relaxed);
            qr.requested({0x100, i, 1, 8, 8, 0}, std::move(doneReply));
        }
        auto extra = std::make_shared<QueryReply>();
        qr.requested({0x100, uint32_t(QueryResults::kMaxEntries), 1, 8, 8, 0}, extra);
        bool pending = false;
        assert(qr.take({0x100, 0, 1, 8, 8, 0}, &pending) == nullptr && pending);
    }

    // Ranges polled before their results could be there are handed out once available, once;
    // a destroyed pool forgets its own, and past the bound one is dropped.
    {
        QueryResults qr;
        const QueryResults::Key a{0x300, 0, 1, 8, 8, 1}, b{0x300, 1, 1, 8, 8, 1}, c{0x301, 0, 1, 8, 8, 1};
        qr.want(a, 0xD1);
        qr.want(b, 0xD1);
        qr.want(c, 0xD2);
        auto ready = qr.takeWanted([&](const QueryResults::Key& key) { return key.first == 0; });
        assert(ready.size() == 2 && ready[0].first.pool == 0x300 && ready[0].second == 0xD1 &&
               ready[1].first.pool == 0x301 && ready[1].second == 0xD2);
        assert(qr.takeWanted([](const QueryResults::Key& key) { return key.first == 0; }).empty());
        qr.poolDestroyed(0x300);
        assert(qr.takeWanted([](const QueryResults::Key&) { return true; }).empty());
        for (uint32_t i = 0; i <= QueryResults::kMaxWanted; ++i) qr.want({0x302, i, 1, 8, 8, 1}, 0xD1);
        auto all = qr.takeWanted([](const QueryResults::Key&) { return true; });
        assert(all.size() == QueryResults::kMaxWanted && all.front().first.first == 1);
    }

    // Reusing a command buffer across >kMaxRecorded frames with commandBufferBegun clears old
    // recorded resets instead of overflowing to a whole-pool wipe, and secondary command buffer
    // resets propagate via commandBufferExecutes.
    {
        QueryResults qr;
        const uint64_t pool = 0x200, primary = 0xCB01, secondary = 0xCB02;
        for (uint32_t frame = 0; frame < 1500; ++frame) {
            qr.commandBufferBegun(primary);
            qr.recordReset(primary, pool, frame % 16, 1);
            qr.submitted(primary);
        }
        auto live = std::make_shared<QueryReply>();
        live->done.store(true, std::memory_order_relaxed);
        qr.requested({pool, 100, 1, 8, 8, 0}, live);
        qr.commandBufferBegun(primary);
        qr.recordReset(primary, pool, 0, 1);
        qr.submitted(primary);
        bool pending = false;
        assert(qr.take({pool, 100, 1, 8, 8, 0}, &pending) == live);

        auto secReply = std::make_shared<QueryReply>();
        secReply->done.store(true, std::memory_order_relaxed);
        qr.requested({pool, 200, 1, 8, 8, 0}, secReply);
        qr.commandBufferBegun(secondary);
        qr.recordReset(secondary, pool, 200, 1);
        qr.commandBufferBegun(primary);
        qr.commandBufferExecutes(primary, &secondary, 1);
        qr.submitted(primary);
        assert(qr.take({pool, 200, 1, 8, 8, 0}, &pending) == nullptr && !pending);
    }
    return 0;
}
