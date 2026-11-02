// SPDX-License-Identifier: MIT
#include "completion_feed.h"
#include "deferred_destroys.h"
#include <cassert>
using caboose::completion::kCompleted;
using caboose::completion::Tracker;
using caboose::memory::DeferredDestroys;

static DeferredDestroys::Destroy destroy(uint32_t opcode, uint64_t handle, uint64_t device = 0xD1) {
    DeferredDestroys::Destroy d;
    d.opcode = opcode;
    d.device = device;
    d.handle = handle;
    return d;
}

int main() {
    // A free asked for while two queues have work in flight is sent once both completed,
    // whichever completes first; later frees wait behind it in order.
    {
        Tracker t;
        DeferredDestroys held;
        const uint64_t a = t.submitted(0, {}, 0x10, 0xD1);
        const uint64_t b = t.submitted(0, {}, 0x20, 0xD1);
        held.hold(t.lastSerial(), 0, destroy(1, 0xB1));
        held.hold(t.lastSerial(), 0, destroy(2, 0xB2));
        assert(held.size() == 2 && held.oldestSerial() == b);
        assert(held.take(t.outstandingFrom(), 0).send.empty());
        t.complete(b, kCompleted);
        assert(held.take(t.outstandingFrom(), 0).send.empty());  // queue 0x10 still runs
        t.complete(a, kCompleted);
        auto taken = held.take(t.outstandingFrom(), 0);
        assert(taken.send.size() == 2 && taken.send[0].handle == 0xB1 && taken.send[1].handle == 0xB2);
        assert(held.empty() && held.oldestSerial() == 0);
    }
    // Order is kept: a free held for later work stays behind, and so does everything after it.
    {
        Tracker t;
        DeferredDestroys held;
        const uint64_t a = t.submitted(0, {}, 0x10, 0xD1);
        held.hold(t.lastSerial(), 0, destroy(1, 0xA));
        const uint64_t b = t.submitted(0, {}, 0x10, 0xD1);
        held.hold(t.lastSerial(), 0, destroy(1, 0xB));
        held.hold(a, 0, destroy(1, 0xC));  // an older serial behind a newer one still waits
        t.complete(a, kCompleted);
        auto taken = held.take(t.outstandingFrom(), 0);
        assert(taken.send.size() == 1 && taken.send[0].handle == 0xA && held.size() == 2);
        t.complete(b, kCompleted);
        taken = held.take(t.outstandingFrom(), 0);
        assert(taken.send.size() == 2 && taken.send[0].handle == 0xB && taken.send[1].handle == 0xC);
    }
    // A destroyed device takes its own held destroys at once; another device's stay.
    {
        Tracker t;
        DeferredDestroys held;
        t.submitted(0, {}, 0x10, 0xD1);
        held.hold(t.lastSerial(), 0, destroy(1, 0xA, 0xD1));
        held.hold(t.lastSerial(), 0, destroy(1, 0xB, 0xD2));
        held.hold(t.lastSerial(), 0, destroy(1, 0xC, 0xD1));
        auto taken = held.take(t.outstandingFrom(), 0, 0xD1);
        assert(taken.send.size() == 2 && taken.send[0].handle == 0xA && taken.send[1].handle == 0xC);
        assert(held.size() == 1 && held.oldestSerial() == t.lastSerial());
    }
    // Destroys held under an executor that left are dropped, never sent on the next one.
    {
        Tracker t;
        DeferredDestroys held;
        t.submitted(0, {}, 0x10, 0xD1);
        DeferredDestroys::Destroy freed = destroy(3, 0xF);
        freed.memory = 0x77;
        held.hold(t.lastSerial(), 4, freed);
        t.revive();
        auto taken = held.take(t.outstandingFrom(), 5);
        assert(taken.send.empty() && taken.dropped.size() == 1 && taken.dropped[0].memory == 0x77 && held.empty());
    }
    // Queues whose latest submissions no watch follows are handed out once.
    {
        DeferredDestroys held;
        held.submittedUnwatched(0x10, 0x1010, 0xD1);
        held.submittedUnwatched(0x20, 0x2020, 0xD1);
        held.submittedUnwatched(0x10, 0x1010, 0xD1);
        held.watched(0x20);
        auto queues = held.takeUnwatched();
        assert(queues.size() == 1 && queues[0].queue == 0x10 && queues[0].hostQueue == 0x1010 && queues[0].device == 0xD1);
        assert(held.takeUnwatched().empty());
        held.submittedUnwatched(0x30, 0x3030, 0xD1);
        held.submittedUnwatched(0x40, 0x4040, 0xD2);
        held.deviceDestroyed(0xD1);
        queues = held.takeUnwatched();
        assert(queues.size() == 1 && queues[0].queue == 0x40);
    }
    return 0;
}
