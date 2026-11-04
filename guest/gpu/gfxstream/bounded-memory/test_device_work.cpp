// SPDX-License-Identifier: MIT
#include "device_work.h"
#include <cassert>
#include <cstdio>
using caboose::memory::DeviceWork;
int main() {
    // Memory allocated before nothing else was sent is unwritten until something is.
    {
        DeviceWork work;
        const uint64_t allocated = work.epoch();
        assert(work.unchangedSince(allocated));
        assert(!work.unchangedSince(DeviceWork::kNever));
        work.sent();
        assert(!work.unchangedSince(allocated));
        const uint64_t later = work.epoch();
        work.sentOn(7);
        assert(!work.unchangedSince(later));
    }
    // A queue nothing was sent to is idle; one with work is not until the device reports it
    // idle for a wait that covers all of it.
    {
        DeviceWork work;
        assert(work.idleNow(1) && work.sentTo(1) == 0);
        work.sentOn(1);
        assert(!work.idleNow(1) && work.idleNow(2));
        const uint64_t covered = work.sentTo(1);
        work.sentOn(1);  // sent after the wait went out: not covered by it
        work.idle(1, covered);
        assert(!work.idleNow(1));
        work.idle(1, work.sentTo(1));
        assert(work.idleNow(1));
        // An older report never undoes a newer one.
        work.idle(1, covered);
        assert(work.idleNow(1));
        // Work on the host (no queue) leaves queues idle.
        work.sent();
        assert(work.idleNow(1));
    }
    // More queues than are kept: none is known idle.
    {
        DeviceWork work;
        for (uint64_t q = 1; q <= DeviceWork::kMaxQueues; ++q) work.sentOn(q), work.idle(q, work.sentTo(q));
        assert(work.idleNow(1));
        work.sentOn(DeviceWork::kMaxQueues + 1);
        assert(!work.idleNow(1) && !work.idleNow(DeviceWork::kMaxQueues + 1) && !work.idleNow(DeviceWork::kMaxQueues + 2));
    }
    std::puts("device work: unwritten memory, idle queues, late idle reports and the queue bound passed");
}
