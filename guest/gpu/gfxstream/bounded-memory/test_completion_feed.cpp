// SPDX-License-Identifier: MIT
#include "completion_feed.h"
#include <cassert>
#include <thread>
using namespace caboose::completion;
using Answer = Tracker::Answer;
using Fence = Tracker::Fence;

int main() {
    const auto soon = [] { return Tracker::Clock::now() + std::chrono::milliseconds(20); };
    {
        Tracker t;
        const uint64_t f = 0xF1, g = 0xF2;
        // Unknown fences are asked about; created ones are known.
        assert(t.fencesSignaled(&f, 1, true) == Answer::AskDevice);
        t.fenceCreated(f, false);
        t.fenceCreated(g, true);
        assert(t.fencesSignaled(&f, 1, true) == Answer::NotYet);
        assert(t.fencesSignaled(&g, 1, true) == Answer::Satisfied);
        // A watched submission is pending until its serial completes.
        const uint64_t s1 = t.submitted(f, {});
        assert(t.fence(f) == Fence::Pending && t.pendingWatches() == 1);
        assert(t.waitFences(&f, 1, true, soon()) == Answer::NotYet);
        const uint64_t both[] = {f, g};
        assert(t.fencesSignaled(both, 2, false) == Answer::Satisfied);
        assert(t.fencesSignaled(both, 2, true) == Answer::NotYet);
        std::thread feed([&] { std::this_thread::sleep_for(std::chrono::milliseconds(5)); t.complete(s1, kCompleted); });
        assert(t.waitFences(&f, 1, true, Tracker::Clock::now() + std::chrono::seconds(5)) == Answer::Satisfied);
        feed.join();
        assert(t.fencesSignaled(both, 2, true) == Answer::Satisfied && !t.pendingWatches());
        // A reset forgets the signal; a late record for an older submission is ignored.
        t.fenceReset(f);
        const uint64_t s2 = t.submitted(f, {});
        t.fenceReset(f);  // (application reset after observing it signaled elsewhere)
        t.complete(s2, kCompleted);
        assert(t.fence(f) == Fence::Unsignaled);
        t.complete(s1, kCompleted);  // already consumed
        assert(t.fence(f) == Fence::Unsignaled);
        // An unwatched submission or untracked signal operation makes the fence asked about.
        const uint64_t s3 = t.submitted(f, {});
        t.unwatched(s3);
        assert(t.fencesSignaled(&f, 1, true) == Answer::AskDevice);
        t.fenceReset(f);
        assert(t.fencesSignaled(&f, 1, true) == Answer::NotYet);
        t.fenceUntracked(f);
        assert(t.fencesSignaled(&f, 1, true) == Answer::AskDevice);
        t.fenceDestroyed(f);
        assert(t.fencesSignaled(&f, 1, true) == Answer::AskDevice);
    }
    {
        Tracker t;
        const uint64_t f = 0xF3, sem = 0x51;
        t.fenceCreated(f, false);
        t.timelineCreated(sem, 5);
        uint64_t value = 0;
        assert(t.timelineValue(sem, &value) && value == 5);
        const uint64_t s = t.submitted(f, {{sem, 9}, {0x52 /* untracked */, 3}});
        const uint64_t nine = 9;
        assert(t.waitTimelines(&sem, &nine, 1, true, soon()) == Answer::NotYet);
        t.complete(s, kCompleted);
        assert(t.timelineValue(sem, &value) && value == 9);
        assert(t.waitTimelines(&sem, &nine, 1, true, soon()) == Answer::Satisfied);
        t.timelineSignaledByHost(sem, 12);
        t.timelineSignaledByHost(sem, 10);  // values never go backwards
        assert(t.timelineValue(sem, &value) && value == 12);
        const uint64_t other = 0x52;
        assert(t.waitTimelines(&other, &nine, 1, true, soon()) == Answer::AskDevice);
        // Device loss reaches every waiter.
        const uint64_t s2 = t.submitted(f, {});
        t.complete(s2, kDeviceLost);
        assert(t.deviceLost() && t.fencesSignaled(&f, 1, true) == Answer::DeviceLost);
    }
    {
        // A closed feed hands outstanding waits back to the device.
        Tracker t;
        const uint64_t f = 0xF4;
        t.fenceCreated(f, false);
        t.submitted(f, {});
        std::thread closer([&] { std::this_thread::sleep_for(std::chrono::milliseconds(5)); t.feedClosed(); });
        assert(t.waitFences(&f, 1, true, Tracker::Clock::now() + std::chrono::seconds(5)) == Answer::AskDevice);
        closer.join();
    }
    {
        // An idle wait completes earlier watched submissions on its queue (or all queues),
        // but not ones made after the wait was sent.
        Tracker t;
        const uint64_t f1 = 1, f2 = 2, f3 = 3;
        for (uint64_t f : {f1, f2, f3}) t.fenceCreated(f, false);
        const uint64_t f4 = 4;
        t.fenceCreated(f4, false);
        t.submitted(f1, {}, 0x51, 0xD1);
        t.submitted(f2, {}, 0x52, 0xD1);
        const uint64_t through = t.lastSerial();
        t.submitted(f3, {}, 0x51, 0xD1);
        t.submitted(f4, {}, 0x61, 0xD2);
        t.idle(0x51, 0, through);
        assert(t.fence(f1) == Fence::Signaled && t.fence(f2) == Fence::Pending && t.fence(f3) == Fence::Pending);
        // A device idle covers only that device's queues.
        t.idle(0, 0xD1, t.lastSerial());
        assert(t.fence(f2) == Fence::Signaled && t.fence(f3) == Fence::Signaled && t.fence(f4) == Fence::Pending);
        t.idle(0, 0xD2, t.lastSerial());
        assert(t.fence(f4) == Fence::Signaled && !t.pendingWatches());
    }
    {
        // Device loss is scoped to the device whose submission reported it.
        Tracker t;
        const uint64_t f1 = 1, f2 = 2, sem = 0x53;
        t.fenceCreated(f1, false);
        t.fenceCreated(f2, false);
        t.timelineCreated(sem, 0, 0xD2);
        const uint64_t lost = t.submitted(f1, {}, 0x51, 0xD1);
        t.submitted(f2, {{sem, 1}}, 0x61, 0xD2);
        t.complete(lost, kDeviceLost);
        assert(t.deviceLost(0xD1) && !t.deviceLost(0xD2) && !t.deviceLost());
        assert(t.fencesSignaled(&f1, 1, true) == Answer::DeviceLost);
        assert(t.fencesSignaled(&f2, 1, true) == Answer::NotYet);
        const uint64_t one = 1;
        assert(t.waitTimelines(&sem, &one, 1, true, Tracker::Clock::now()) == Answer::NotYet);
    }
    {
        // Untracking wakes a waiter so it asks the device instead of sleeping to its deadline.
        Tracker t;
        const uint64_t f = 0xF5;
        t.fenceCreated(f, false);
        t.submitted(f, {});
        std::thread untrack([&] { std::this_thread::sleep_for(std::chrono::milliseconds(5)); t.fenceUntracked(f); });
        const auto start = Tracker::Clock::now();
        assert(t.waitFences(&f, 1, true, start + std::chrono::seconds(5)) == Answer::AskDevice);
        assert(Tracker::Clock::now() - start < std::chrono::seconds(2));
        untrack.join();
    }
    uint8_t watch[kWatchPacketSize], feed[kFeedPacketSize];
    encodeWatch(watch, 0x1122334455667788ull, 7);
    encodeFeed(feed);
    assert(watch[0] == 0x02 && watch[3] == 0x43 && watch[4] == 24 && watch[8] == 0x88 && watch[16] == 7);
    assert(feed[0] == 0x01 && feed[4] == 16 && feed[8] == 1);
    return 0;
}
