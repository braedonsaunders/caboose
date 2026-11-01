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
    // and drains the oldest half once the replies owed pass 64 KiB, leaving newer replies
    // in flight instead of stalling on the newest just-sent command.
    {
        DeferredReplies big;
        Stream results;
        const uint32_t many = uint32_t(deferredReplyByteLimit / sizeof(int32_t));
        results.replies.assign(many + 2, 0);
        big.addCheckedResults(&a, 1, 4 * 1024 * 1024);  // one 4 MiB flush, one result
        assert(big.reserve(&a, &results, 1024 * 1024) && results.next == 0);
        assert(big.reserve(&a, &results, 3 * 1024 * 1024) && results.next == 1 && big.pending() == 0);  // past 6 MiB
        big.addCheckedResults(&a, many, 1024);                 // exactly 64 KiB of results owed
        assert(big.reserve(&a, &results, 64) && results.next == 1);
        big.addCheckedResult(&a, 64);                          // one more: past the reply bound
        assert(big.reserve(&a, &results, 64) && results.next == 1 + many / 2 + 1 && big.pending() == many / 2);
        assert(big.drain(&a, &results) && results.next == many + 2 && big.pending() == 0);
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
    return 0;
}
