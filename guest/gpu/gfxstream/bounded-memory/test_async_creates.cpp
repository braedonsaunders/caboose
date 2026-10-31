// SPDX-License-Identifier: MIT
// Deferred replies of guest-assigned creates, deferred submits and the async allocation budget.
#include "async_allocation.h"
#include "deferred_replies.h"
#include <array>
#include <cassert>
#include <cstring>
#include <vector>
using namespace caboose::memory;

namespace {
// A byte stream of device replies.
struct Stream {
    std::vector<uint8_t> bytes;
    size_t next = 0;
    bool invalidated = false;
    template <class T> void push(T value) {
        const auto* raw = reinterpret_cast<const uint8_t*>(&value);
        bytes.insert(bytes.end(), raw, raw + sizeof(T));
    }
    bool tryRead(void* out, size_t size) {
        if (bytes.size() - next < size) return false;
        std::memcpy(out, bytes.data() + next, size);
        next += size;
        return true;
    }
    void invalidate() { invalidated = true; }
};
uint64_t observed = 0, observations = 0;
}  // namespace

int main() {
    drainObserver = [](uint64_t us) { observed += us; ++observations; };
    int encoder = 0;

    // A single create: its handle, then its result.
    {
        DeferredReplies table;
        Stream s; s.push<uint64_t>(0xCA00000100000001ull); s.push<int32_t>(0);
        table.addHandleCreate(&encoder, 0xCA00000100000001ull, 40);
        assert(table.pending() == 1);
        assert(table.drain(&encoder, &s) && !s.invalidated && s.next == s.bytes.size());
        assert(observations == 1);
        // Nothing pending: no read and no observation.
        assert(table.drain(&encoder, &s) && observations == 1);
    }
    // An array create: every consecutive handle in order, then one result.
    {
        DeferredReplies table;
        Stream s;
        for (uint64_t i = 0; i < 3; ++i) s.push<uint64_t>(0xCA00000100000010ull + i);
        s.push<int32_t>(0);
        table.addHandleCreates(&encoder, 0xCA00000100000010ull, 3, 64);
        assert(table.drain(&encoder, &s) && !s.invalidated && s.next == s.bytes.size());
    }
    // A renamed handle is device loss.
    {
        DeferredReplies table;
        Stream s;
        s.push<uint64_t>(0xCA00000100000010ull); s.push<uint64_t>(0x1234); s.push<int32_t>(0);
        table.addHandleCreates(&encoder, 0xCA00000100000010ull, 2, 64);
        assert(!table.drain(&encoder, &s) && s.invalidated);
    }
    // A refused array create is device loss.
    {
        DeferredReplies table;
        Stream s;
        s.push<uint64_t>(0xCA00000100000020ull); s.push<int32_t>(-1000069000);
        table.addHandleCreates(&encoder, 0xCA00000100000020ull, 1, 64);
        assert(!table.drain(&encoder, &s) && s.invalidated);
    }
    // A deferred submit's results: any failure among them is device loss, in stream order
    // with the other replies.
    {
        DeferredReplies table;
        Stream s;
        s.push<uint64_t>(0xCA00000100000030ull); s.push<int32_t>(0);
        for (int i = 0; i < 5; ++i) s.push<int32_t>(0);
        table.addHandleCreate(&encoder, 0xCA00000100000030ull, 40);
        table.addCheckedResults(&encoder, 5, 4096);
        assert(table.pending() == 6);
        assert(table.drain(&encoder, &s) && !s.invalidated && s.next == s.bytes.size());

        Stream failed;
        failed.push<int32_t>(0); failed.push<int32_t>(-4); failed.push<int32_t>(0);
        table.addCheckedResults(&encoder, 3, 4096);
        assert(!table.drain(&encoder, &failed) && failed.invalidated);
    }
    // Pending creates count toward the in-flight byte limit.
    {
        DeferredReplies table;
        Stream s; s.push<uint64_t>(0xCA00000100000040ull); s.push<int32_t>(0);
        table.addHandleCreate(&encoder, 0xCA00000100000040ull, 900);
        assert(table.reserve(&encoder, &s, 100, 1000) && s.next == 0);
        assert(table.reserve(&encoder, &s, 101, 1000) && s.next == s.bytes.size() && !table.pending());
    }

    // Before another channel names objects or work, replies are read through the last
    // create or submit; a later prefetched fence wait and plain result stay pending.
    {
        DeferredReplies table;
        Stream s;
        s.push<int32_t>(0);                                         // plain deferred result
        s.push<uint64_t>(0xCA00000100000050ull); s.push<int32_t>(0); // create
        s.push<int32_t>(0); s.push<int32_t>(0);                     // submit results
        const size_t objectsEnd = s.bytes.size();
        s.push<int32_t>(0);                                         // prefetched fence wait
        s.push<int32_t>(0);                                         // plain deferred result
        table.add(&encoder, 1, 8);
        table.addHandleCreate(&encoder, 0xCA00000100000050ull, 40);
        table.addCheckedResults(&encoder, 2, 300);
        table.addFenceWait(&encoder, 0x77, 50);
        table.add(&encoder, 1, 60);
        assert(table.drainObjects(&encoder, &s) && s.next == objectsEnd && table.pending() == 2);
        // Only the remaining commands' bytes stay in flight.
        assert(table.reserve(&encoder, &s, 1000 - 110, 1000) && s.next == objectsEnd);
        // Nothing left to create or submit: no read.
        assert(table.drainObjects(&encoder, &s) && s.next == objectsEnd);
        assert(table.drain(&encoder, &s) && s.next == s.bytes.size() && !table.pending());
        assert(table.signaled(std::array<uint64_t, 1>{0x77}.data(), 1, true));
    }

    // Allocations skip the round trip only while their heap stays at most half used.
    {
        AsyncAllocationBudget budget;
        const uint64_t dev = 7, heapSize = 1000;
        assert(budget.reserve(dev, 0, heapSize, 300));
        budget.track(0xA, dev, 0, 300);
        assert(budget.reserve(dev, 0, heapSize, 200));
        budget.track(0xB, dev, 0, 200);
        assert(!budget.reserve(dev, 0, heapSize, 1));      // 501 > 500
        assert(budget.reserve(dev, 1, heapSize, 500));      // other heaps are separate
        assert(!budget.reserve(dev + 1, 0, heapSize, 501)); // per device, never past the limit
        assert(!budget.reserve(dev, 2, heapSize, 0) && !budget.reserve(dev, 2, 0, 1));
        budget.freed(0xA);
        assert(budget.committed(dev, 0) == 200);
        assert(budget.reserve(dev, 0, heapSize, 300));
        budget.cancel(dev, 0, 300);
        assert(budget.committed(dev, 0) == 200);
        // A synchronous allocation still counts, and freeing it releases it.
        budget.commit(dev, 0, 250);
        budget.track(0xC, dev, 0, 250);
        assert(!budget.reserve(dev, 0, heapSize, 51) && budget.reserve(dev, 0, heapSize, 50));
        budget.freed(0xC);
        budget.freed(0xC);  // a double free releases once
        assert(budget.committed(dev, 0) == 250);
        budget.deviceDestroyed(dev);
        assert(budget.committed(dev, 0) == 0 && budget.committed(dev, 1) == 0);
        assert(budget.reserve(dev, 0, UINT64_MAX, UINT64_MAX / 2));
        assert(!budget.reserve(dev, 0, UINT64_MAX, UINT64_MAX / 2));
    }
    return 0;
}
