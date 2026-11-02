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
        assert(!t.serialCompleted(s1));
        assert(t.fence(f) == Fence::Pending && t.pendingWatches() == 1);
        assert(t.waitFences(&f, 1, true, soon()) == Answer::NotYet);
        const uint64_t both[] = {f, g};
        assert(t.fencesSignaled(both, 2, false) == Answer::Satisfied);
        assert(t.fencesSignaled(both, 2, true) == Answer::NotYet);
        std::thread feed([&] { std::this_thread::sleep_for(std::chrono::milliseconds(5)); t.complete(s1, kCompleted); });
        assert(t.waitFences(&f, 1, true, Tracker::Clock::now() + std::chrono::seconds(5)) == Answer::Satisfied);
        feed.join();
        assert(t.serialCompleted(s1));
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
    {
        // Losing the executor wakes every waiter with device loss at once; a new
        // executor connection revives tracking, and the lost device's pending fences are
        // asked about on their own (ended) streams instead of hanging.
        Tracker t;
        const uint64_t f = 0xF6, sem = 0x56, ten = 10;
        t.fenceCreated(f, false);
        t.timelineCreated(sem, 0);
        t.submitted(f, {{sem, 10}});
        std::thread lose([&] { std::this_thread::sleep_for(std::chrono::milliseconds(5)); t.loseAll(); });
        const auto start = Tracker::Clock::now();
        assert(t.waitFences(&f, 1, true, start + std::chrono::seconds(5)) == Answer::DeviceLost);
        assert(Tracker::Clock::now() - start < std::chrono::seconds(2));
        lose.join();
        assert(t.waitTimelines(&sem, &ten, 1, true, Tracker::Clock::now()) == Answer::DeviceLost);
        t.revive();
        assert(!t.deviceLost());
        assert(t.fencesSignaled(&f, 1, true) == Answer::AskDevice);
        assert(t.waitTimelines(&sem, &ten, 1, true, Tracker::Clock::now()) == Answer::AskDevice);
        const uint64_t g = 0xF7;
        t.fenceCreated(g, false);
        const uint64_t s = t.submitted(g, {});
        t.complete(s, kCompleted);
        assert(t.fencesSignaled(&g, 1, true) == Answer::Satisfied);
    }
    uint8_t watch[kWatchPacketSize], feed[kFeedPacketSize];
    encodeWatch(watch, 0x1122334455667788ull, 7);
    encodeFeed(feed);
    assert(watch[0] == 0x02 && watch[3] == 0x43 && watch[4] == 24 && watch[8] == 0x88 && watch[16] == 7);
    assert(feed[0] == 0x01 && feed[4] == 16 && feed[8] == 1);
    // The loss policy: explicit values as given, "auto" per process.
    const std::vector<std::string> none, qt{"/usr/lib/x86_64-linux-gnu/libQt6Gui.so.6"};
    assert(!lossPolicyPauses(nullptr, "vkcube", none));
    assert(lossPolicyPauses("pause", "chromium --type=gpu-process", qt));
    assert(!lossPolicyPauses("restart", "vkcube", none));
    assert(lossPolicyPauses("auto", "vkcube --wsi xcb", none));
    assert(!lossPolicyPauses("auto", "/usr/lib/chromium/chromium --type=gpu-process --x", none));
    assert(!lossPolicyPauses("auto", "steamwebhelper --type=zygote --no-zygote-sandbox", none));
    assert(lossPolicyPauses("pause", "steamwebhelper --type=zygote", none));
    assert(!lossPolicyPauses("auto", "qml6 t.qml", qt));
    assert(!lossPolicyPauses("auto", "kp", {"libQt5Gui.so.5"}));
    assert(!lossPolicyPauses("bogus", "vkcube", none));
    // A stalled poll's description names the fence's state and its outstanding watch.
    {
        Tracker described;
        const uint64_t serial = described.submitted(0xf00, {});
        assert(described.describeFence(0xf00) == "fence=pending serial=" + std::to_string(serial) +
               " (watch outstanding) last_serial=" + std::to_string(serial) + " watches=1 oldest_watch=" +
               std::to_string(serial));
        assert(described.describeFence(0xbad).rfind("fence=unknown", 0) == 0);
        assert(described.describeSemaphore(0x5e).rfind("timeline=unknown", 0) == 0);
    }
    // completedThrough: every watch up to a serial, on every queue, has completed.
    {
        Tracker ct;
        assert(ct.completedThrough(0) && ct.outstandingFrom() == 1);
        const uint64_t s1 = ct.submitted(0, {}, 0x10, 0xD1);
        const uint64_t s2 = ct.submitted(0, {}, 0x20, 0xD1);
        assert(!ct.completedThrough(s1) && !ct.completedThrough(s2) && ct.outstandingFrom() == s1);
        // s2 on queue 0x20 completes before s1 on queue 0x10: s2 alone is not enough.
        ct.complete(s2, kCompleted);
        assert(ct.serialCompleted(s2) && !ct.completedThrough(s2) && !ct.completedThrough(s1));
        assert(!ct.waitCompletedThrough(s1, soon()));
        std::thread feed([&] { std::this_thread::sleep_for(std::chrono::milliseconds(5)); ct.complete(s1, kCompleted); });
        assert(ct.waitCompletedThrough(s2, Tracker::Clock::now() + std::chrono::seconds(5)));
        feed.join();
        assert(ct.completedThrough(s1) && ct.completedThrough(s2) && ct.outstandingFrom() == s2 + 1);
        // A queue reported idle completes its watches; an ended feed reports nothing more.
        const uint64_t s3 = ct.submitted(0, {}, 0x10, 0xD1);
        ct.idle(0x10, 0, s3);
        assert(ct.completedThrough(s3));
        const uint64_t s4 = ct.submitted(0, {}, 0x10, 0xD1);
        assert(!ct.completedThrough(s4));
        ct.feedClosed();
        assert(ct.completedThrough(s4) && ct.outstandingFrom() == UINT64_MAX);
    }
    // Events: known from host sets and resets and from completed batches that set them.
    {
        Tracker e;
        bool set = true;
        assert(!e.eventSet(0xe1, &set));  // never created here: asked on the device
        e.eventCreated(0xe1);
        assert(e.eventSet(0xe1, &set) && !set);
        e.eventHost(0xe1, true);
        assert(e.eventSet(0xe1, &set) && set);
        e.eventHost(0xe1, false);
        // A command buffer sets it: not set until the batch completes.
        e.commandBufferBegun(0xc1);
        e.commandBufferEvent(0xc1, 0xe1, true);
        assert(e.setsEvents({0xc1}) && !e.setsEvents({0xc2}));
        assert(e.eventsOf({0xc1, 0xc2}) == std::vector<uint64_t>{0xe1});
        const uint64_t serial = e.submitted(0, {}, 0x9, 0x1, {0xc1});
        assert(e.eventSet(0xe1, &set) && !set);
        assert(e.describeEvent(0xe1).rfind("event=reset pending_batches=1", 0) == 0);
        e.complete(serial, kCompleted);
        assert(e.eventSet(0xe1, &set) && set);
        assert(e.describeEvent(0xe1).rfind("event=set pending_batches=0", 0) == 0);
        assert(e.describeEvent(0xe9).rfind("event=unknown", 0) == 0);
        // A secondary's operations run where it is executed; a reset in the batch resets it.
        e.commandBufferBegun(0xc2);
        e.commandBufferEvent(0xc2, 0xe1, false);
        e.commandBufferBegun(0xc3);
        e.commandBufferExecutes(0xc3, std::vector<uint64_t>{0xc2}.data(), 1);
        e.complete(e.submitted(0, {}, 0x9, 0x1, {0xc3}), kCompleted);
        assert(e.eventSet(0xe1, &set) && !set);
        // Re-recording forgets the old operations.
        e.commandBufferBegun(0xc1);
        assert(!e.setsEvents({0xc1}));
        // A batch reported lost, or one nobody watches, leaves the event to the device.
        e.commandBufferEvent(0xc1, 0xe1, true);
        e.complete(e.submitted(0, {}, 0x9, 0x1, {0xc1}), kDeviceLost);
        assert(!e.eventSet(0xe1, &set));
        e.eventCreated(0xe2);
        e.commandBufferBegun(0xc4);
        e.commandBufferEvent(0xc4, 0xe2, true);
        e.eventsUntracked({0xc4});
        assert(!e.eventSet(0xe2, &set));
        // A new executor forgets what the old one's events were.
        e.eventCreated(0xe3);
        e.revive();
        assert(!e.eventSet(0xe3, &set));
        e.eventDestroyed(0xe3);
    }
    // Queries: available once the batch that ends them completes; reset makes them unavailable.
    {
        using Q = Tracker::Queries;
        Tracker q;
        const uint64_t pool = 0x9001;
        assert(q.queries(pool, 0, 1) == Q::AskDevice);  // never reset here: asked on the device
        q.queriesReset(pool, 0, 4);
        assert(q.queries(pool, 0, 1) == Q::NotReady);
        q.commandBufferBegun(0xc1);
        q.commandBufferQueries(0xc1, pool, 1, 1, true);
        assert(q.touchesQueries({0xc1}) && !q.touchesQueries({0xc2}));
        assert(q.queries(pool, 1, 1) == Q::NotReady);  // recorded, not submitted
        const uint64_t s1 = q.submitted(0, {}, 0x9, 0x1, {0xc1});
        assert(q.queries(pool, 1, 1) == Q::NotReady);
        assert(q.describeQuery(pool, 1).rfind("query=pending serial=", 0) == 0);
        q.complete(s1, kCompleted);
        assert(q.queries(pool, 1, 1) == Q::Available && q.queries(pool, 0, 2) == Q::NotReady);
        assert(q.describeQuery(pool, 1).rfind("query=available", 0) == 0);
        assert(q.queries(pool, 0, 8) == Q::AskDevice);  // queries 4..7 never seen
        // A host reset, or one in a later batch, makes it unavailable again; an end after
        // the reset in the same command buffer wins.
        q.queriesReset(pool, 1, 1);
        assert(q.queries(pool, 1, 1) == Q::NotReady);
        q.complete(q.submitted(0, {}, 0x9, 0x1, {0xc1}), kCompleted);
        assert(q.queries(pool, 1, 1) == Q::Available);
        q.commandBufferBegun(0xc1);
        q.commandBufferQueries(0xc1, pool, 0, 4, false);
        q.commandBufferQueries(0xc1, pool, 2, 1, true);
        const uint64_t s2 = q.submitted(0, {}, 0x9, 0x1, {0xc1});
        assert(q.queries(pool, 1, 1) == Q::NotReady && q.queries(pool, 2, 1) == Q::NotReady);
        q.complete(s2, kCompleted);
        assert(q.queries(pool, 1, 1) == Q::NotReady && q.queries(pool, 2, 1) == Q::Available);
        // A secondary's ends count where it is executed.
        q.commandBufferBegun(0xc2);
        q.commandBufferQueries(0xc2, pool, 3, 1, true);
        q.commandBufferBegun(0xc3);
        q.commandBufferExecutes(0xc3, std::vector<uint64_t>{0xc2}.data(), 1);
        q.complete(q.submitted(0, {}, 0x9, 0x1, {0xc3}), kCompleted);
        assert(q.queries(pool, 3, 1) == Q::Available);
        // A batch reported unwatchable leaves its queries to the device; so does a new executor.
        q.commandBufferBegun(0xc1);
        q.commandBufferQueries(0xc1, pool, 0, 1, true);
        q.complete(q.submitted(0, {}, 0x9, 0x1, {0xc1}), kUnwatched);
        assert(q.queries(pool, 0, 1) == Q::AskDevice);
        q.revive();
        assert(q.queries(pool, 2, 1) == Q::AskDevice);
        q.queriesReset(pool, 0, 1);
        q.queryPoolDestroyed(pool);
        assert(q.queries(pool, 0, 1) == Q::AskDevice);
        // Too many operations in one command buffer leave the pool to the device.
        q.queriesReset(pool, 0, 2);
        q.commandBufferBegun(0xc4);
        for (int i = 0; i < 5000; ++i) q.commandBufferQueries(0xc4, pool, 0, 1, true);
        q.complete(q.submitted(0, {}, 0x9, 0x1, {0xc4}), kCompleted);
        assert(q.queries(pool, 1, 1) == Q::AskDevice);
    }
    return 0;
}
