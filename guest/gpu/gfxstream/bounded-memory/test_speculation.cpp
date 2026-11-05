// SPDX-License-Identifier: MIT
// Speculated waits (hello 0x400000): which submissions a wait may report complete before their
// records, what WAIT_SERIAL each device stream sends, and what the records do afterwards. The
// feed is played by calling complete() as the phone's records would arrive.
#include "completion_feed.h"
#include <atomic>
#include <cassert>
#include <cstring>
#include <thread>
using namespace caboose::completion;
using Answer = Tracker::Answer;
using Batch = Tracker::Batch;

namespace {
constexpr uint64_t kStream = 0xE1, kOther = 0xE2, kQueue = 0x91, kQueue2 = 0x92, kDevice = 0xD1;
Tracker::Clock::time_point later() { return Tracker::Clock::now() + std::chrono::seconds(5); }
Tracker::Clock::time_point soon() { return Tracker::Clock::now() + std::chrono::milliseconds(20); }
Batch batch(uint64_t stream = kStream) {
    Batch b;
    b.stream = stream;
    return b;
}
// A tracker whose queues have each had one record: the phone watches them.
void watched(Tracker& t, uint64_t queue = kQueue) {
    const Batch b = batch();
    t.complete(t.submitted(0, {}, queue, kDevice, {}, nullptr, &b), kCompleted);
}
uint64_t signal(Tracker& t, uint64_t semaphore, uint64_t value, uint64_t queue = kQueue, const Batch& b = batch(),
                const std::vector<uint64_t>& commandBuffers = {}) {
    return t.submitted(0, {{semaphore, value}}, queue, kDevice, commandBuffers, nullptr, &b);
}
bool reached(Tracker& t, uint64_t semaphore, uint64_t value, Tracker::Clock::time_point deadline = later()) {
    return t.waitTimelines(&semaphore, &value, 1, true, deadline) == Answer::Satisfied;
}
}  // namespace

int main() {
    {
        // WAIT_SERIAL's bytes: the ordinary header and the serial.
        uint8_t packet[kWaitSerialPacketSize];
        encodeWaitSerial(packet, 0x0102030405060708ull);
        uint32_t opcode, size;
        uint64_t serial;
        std::memcpy(&opcode, packet, 4);
        std::memcpy(&size, packet + 4, 4);
        std::memcpy(&serial, packet + 8, 8);
        assert(opcode == 0x4342FE04 && size == 16 && serial == 0x0102030405060708ull);
    }
    {
        // A blocking wait for a qualifying submission returns at once; the stream its watch went
        // out on holds behind it once, and its record changes nothing it reported.
        Tracker t;
        t.speculation(3);
        const uint64_t sem = 0x51;
        t.timelineCreated(sem, 0, kDevice);
        watched(t);
        const uint64_t s = signal(t, sem, 1);
        assert(!t.speculating());
        assert(reached(t, sem, 1));
        assert(t.speculatedWaits() == 1 && t.speculating());
        uint64_t value = 0;
        assert(t.timelineValue(sem, &value) && value == 1);
        assert(!t.serialCompleted(s));  // held frees still wait for the record
        assert(t.beforeCommand(kStream) == std::vector<uint64_t>{s});
        assert(t.beforeCommand(kStream).empty());
        // Its writes are read back now (lazy readback waits for the record): it is speculated.
        assert(t.speculated(s));
        std::atomic<bool> filled{false};
        std::thread fill([&] { t.waitCompleted(s); filled = true; });
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        assert(!filled);
        t.complete(s, kCompleted);
        fill.join();
        assert(filled && !t.speculated(s));
        t.waitCompleted(s);  // completed: returns at once
        assert(!t.speculating() && t.timelineValue(sem, &value) && value == 1);
        // A wait that does not block is never speculated.
        const uint64_t s2 = signal(t, sem, 2);
        assert(!reached(t, sem, 2, Tracker::Clock::now()));
        assert(t.speculatedWaits() == 1);
        t.complete(s2, kCompleted);
        assert(reached(t, sem, 2));
    }
    {
        // Speculation is off by default, and on a queue the phone has not yet answered for.
        Tracker t;
        const uint64_t sem = 0x52;
        t.timelineCreated(sem, 0, kDevice);
        watched(t);
        const uint64_t s = signal(t, sem, 1);
        assert(!reached(t, sem, 1, soon()));
        t.speculation(3);
        const uint64_t s2 = signal(t, sem, 2, kQueue2);
        assert(!reached(t, sem, 2, soon()));  // kQueue2 never had a record
        assert(t.speculatedWaits() == 0);
        // A record of `unwatched` keeps a queue from speculation.
        t.complete(s, kCompleted);
        t.complete(s2, kUnwatched);
        const uint64_t s3 = signal(t, sem, 3, kQueue2);
        (void)s3;
        assert(t.speculatedWaits() == 0);
    }
    {
        // Batches whose completion the process could observe otherwise are waited for.
        Tracker t;
        t.speculation(3);
        const uint64_t sem = 0x53, external = 0x54, event = 0xE7, pool = 0x70;
        t.timelineCreated(sem, 0, kDevice);
        t.semaphoreExternal(external);
        t.eventCreated(event);
        watched(t);
        uint64_t value = 0;
        auto refused = [&](uint64_t serial) {
            assert(t.timelineValue(sem, &value));
            assert(!reached(t, sem, value + 1, soon()));
            t.complete(serial, kCompleted);
        };
        Batch writes = batch();
        writes.hostWrites = true;  // host-visible memory the guest refreshes
        refused(signal(t, sem, 1, kQueue, writes));
        t.commandBufferEvent(0xC1, event, true);  // an event set
        refused(signal(t, sem, 2, kQueue, batch(), {0xC1}));
        t.commandBufferQueries(0xC2, pool, 0, 1, true);  // a query ended
        refused(signal(t, sem, 3, kQueue, batch(), {0xC2}));
        t.commandBufferQueries(0xC3, pool, 0, 1, false);  // a query reset
        refused(signal(t, sem, 4, kQueue, batch(), {0xC3}));
        t.commandBufferWaitsEvents(0xC4);  // may wait for a host vkSetEvent
        refused(signal(t, sem, 5, kQueue, batch(), {0xC4}));
        Batch exporting = batch();
        exporting.signaled = {sem, external};  // signals an exportable semaphore
        refused(signal(t, sem, 6, kQueue, exporting));
        Batch importing = batch();
        importing.waits = {{external, 0}};  // waits for an imported payload
        refused(signal(t, sem, 7, kQueue, importing));
        refused(signal(t, sem, 8, kQueue, batch(0)));  // not the process's only device stream
        refused(t.submitted(0, {{sem, 9}}, kQueue, kDevice));  // nothing known of it
        // A secondary that waits for events makes its primary wait too; a new recording forgets it.
        t.commandBufferWaitsEvents(0xC5);
        const uint64_t secondary = 0xC5;
        t.commandBufferExecutes(0xC6, &secondary, 1);
        refused(signal(t, sem, 10, kQueue, batch(), {0xC6}));
        t.commandBufferBegun(0xC6);
        assert(t.speculatedWaits() == 0);
        signal(t, sem, 11, kQueue, batch(), {0xC6});
        assert(reached(t, sem, 11) && t.speculatedWaits() == 1);
    }
    {
        // A fence whose payload can be exported is followed on the device, never speculated; a
        // followed one is reported signaled, and stays so after its record.
        Tracker t;
        t.speculation(3);
        const uint64_t exportable = 0xF1, fence = 0xF2;
        t.fenceUntracked(exportable);
        t.fenceCreated(fence, false);
        watched(t);
        const Batch b = batch();
        const uint64_t s1 = t.submitted(exportable, {}, kQueue, kDevice, {}, nullptr, &b);
        assert(t.waitFences(&exportable, 1, true, soon()) == Answer::NotYet);
        t.complete(s1, kCompleted);
        const uint64_t s2 = t.submitted(fence, {}, kQueue, kDevice, {}, nullptr, &b);
        assert(t.waitFences(&fence, 1, true, later()) == Answer::Satisfied);
        assert(t.fencesSignaled(&fence, 1, true) == Answer::Satisfied);
        t.complete(s2, kCompleted);
        assert(t.fencesSignaled(&fence, 1, true) == Answer::Satisfied);
        // Nor is one whose payload was imported, even once it is reset and followed again.
        const uint64_t imported = 0xF8;
        t.fenceCreated(imported, false);
        t.fenceExternal(imported);
        const uint64_t s6 = t.submitted(imported, {}, kQueue, kDevice, {}, nullptr, &b);
        assert(t.waitFences(&imported, 1, true, soon()) == Answer::NotYet);
        t.complete(s6, kCompleted);
        // A reset after a speculated wait is not undone by the record.
        const uint64_t s3 = t.submitted(fence, {}, kQueue, kDevice, {}, nullptr, &b);
        assert(t.waitFences(&fence, 1, true, later()) == Answer::Satisfied);
        t.fenceReset(fence);
        t.complete(s3, kCompleted);
        assert(t.fencesSignaled(&fence, 1, true) == Answer::NotYet);
    }
    {
        // A speculated watch takes the earlier watches of its queue with it: each must qualify.
        Tracker t;
        t.speculation(3);
        const uint64_t sem = 0x55, fence = 0xF3;
        t.timelineCreated(sem, 0, kDevice);
        t.fenceCreated(fence, false);
        watched(t);
        Batch writes = batch();
        writes.hostWrites = true;
        const uint64_t s1 = t.submitted(fence, {}, kQueue, kDevice, {}, nullptr, &writes);
        const uint64_t s2 = signal(t, sem, 1);
        assert(!reached(t, sem, 1, soon()));
        t.complete(s1, kCompleted);
        assert(reached(t, sem, 1));
        t.complete(s2, kCompleted);
        // Qualifying earlier watches are reported complete together with it, behind one WAIT_SERIAL.
        const uint64_t s3 = t.submitted(fence, {}, kQueue, kDevice, {}, nullptr, &writes);
        t.complete(s3, kCompleted);
        t.fenceReset(fence);
        const Batch b = batch();
        const uint64_t s4 = t.submitted(fence, {}, kQueue, kDevice, {}, nullptr, &b);
        const uint64_t s5 = signal(t, sem, 2);
        assert(reached(t, sem, 2));
        assert(t.fencesSignaled(&fence, 1, true) == Answer::Satisfied);
        assert(t.beforeCommand(kStream) == std::vector<uint64_t>{s5});
        t.complete(s5, kCompleted);
        t.complete(s4, kCompleted);
        assert(!t.speculating());
    }
    {
        // At most `limit` speculated watches per queue are outstanding; past that, waits are real.
        Tracker t;
        t.speculation(2);
        const uint64_t sem = 0x56;
        t.timelineCreated(sem, 0, kDevice);
        watched(t);
        const uint64_t s1 = signal(t, sem, 1), s2 = signal(t, sem, 2), s3 = signal(t, sem, 3);
        assert(reached(t, sem, 1) && reached(t, sem, 2));
        assert(!reached(t, sem, 3, soon()));
        std::thread feed([&] {
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
            t.complete(s1, kCompleted);
        });
        feed.join();
        // A record makes room.
        assert(reached(t, sem, 3) && t.speculatedWaits() == 3);
        assert(t.beforeCommand(kStream) == std::vector<uint64_t>{s3});
        t.complete(s2, kCompleted);
        t.complete(s3, kCompleted);
        // Three watches of one queue taken at once count three.
        const uint64_t a = signal(t, sem, 4), b = signal(t, sem, 5), c = signal(t, sem, 6);
        assert(!reached(t, sem, 6, soon()));
        t.complete(a, kCompleted);
        assert(reached(t, sem, 6));
        t.complete(b, kCompleted);
        t.complete(c, kCompleted);
    }
    {
        // Timeline values a batch waits for: already there, signaled by a qualifying watch (taken
        // with it, on its own queue), or not yet sent (never speculated: the stream it would hold
        // is how the signal would come).
        Tracker t;
        t.speculation(3);
        const uint64_t a = 0x57, b = 0x58;
        t.timelineCreated(a, 0, kDevice);
        t.timelineCreated(b, 0, kDevice);
        watched(t);
        watched(t, kQueue2);
        Batch waits = batch();
        waits.waits = {{a, 5}};
        const uint64_t w = signal(t, b, 1, kQueue, waits);  // a = 5 not sent yet
        assert(!reached(t, b, 1, soon()));
        t.timelineSignaledByHost(a, 5);
        assert(reached(t, b, 1));
        t.complete(w, kCompleted);
        waits.waits = {{a, 6}};
        const uint64_t w2 = signal(t, b, 2, kQueue, waits);
        const uint64_t p = signal(t, a, 6, kQueue2);  // signaled after, before the wait
        assert(reached(t, b, 2));
        uint64_t value = 0;
        assert(t.timelineValue(a, &value) && value == 6);
        assert(t.beforeCommand(kStream) == (std::vector<uint64_t>{w2, p}));
        t.complete(w2, kCompleted);
        t.complete(p, kCompleted);
        // An untracked timeline wait is not followed.
        t.semaphoreUntracked(a);
        waits.waits = {{a, 7}};
        const uint64_t w3 = signal(t, b, 3, kQueue, waits);
        assert(!reached(t, b, 3, soon()));
        t.complete(w3, kCompleted);
    }
    {
        // A submission no watch follows: the next watch of its queue completes behind it.
        Tracker t;
        t.speculation(3);
        const uint64_t a = 0x59, sem = 0x5A;
        t.timelineCreated(a, 0, kDevice);
        t.timelineCreated(sem, 0, kDevice);
        watched(t);
        Batch waits = batch();
        waits.waits = {{a, 1}};
        t.unwatchedSubmission(kQueue, &waits);  // waits for a value not sent
        const uint64_t s1 = signal(t, sem, 1);
        assert(!reached(t, sem, 1, soon()));
        t.complete(s1, kCompleted);
        const Batch plain = batch();
        t.unwatchedSubmission(kQueue, &plain);
        const uint64_t s2 = signal(t, sem, 2);
        assert(reached(t, sem, 2));
        t.complete(s2, kCompleted);
        t.unwatchedSubmission(kQueue, nullptr);  // a sparse bind: nothing known
        const uint64_t s3 = signal(t, sem, 3);
        assert(!reached(t, sem, 3, soon()));
        t.complete(s3, kCompleted);
        // It is carried by that one watch only.
        const uint64_t s4 = signal(t, sem, 4);
        assert(reached(t, sem, 4));
        t.complete(s4, kCompleted);
    }
    {
        // A record reporting device loss is device loss, whatever was reported before: the fence
        // reports it, and the timeline is asked on the device, which reports it, as for any watch.
        Tracker t;
        t.speculation(3);
        const uint64_t sem = 0x5B, fence = 0xF4;
        t.timelineCreated(sem, 0, kDevice);
        t.fenceCreated(fence, false);
        watched(t);
        const Batch b = batch();
        const uint64_t s = t.submitted(fence, {{sem, 1}}, kQueue, kDevice, {}, nullptr, &b);
        assert(reached(t, sem, 1));
        t.complete(s, kDeviceLost);
        assert(t.fencesSignaled(&fence, 1, true) == Answer::DeviceLost);
        const uint64_t one = 1;
        assert(t.waitTimelines(&sem, &one, 1, true, later()) == Answer::AskDevice);
        assert(!t.speculating());  // nothing to hold behind once the record is in
        assert(t.beforeCommand(kStream).empty());
        // Nothing is speculated on a lost device.
        const uint64_t f2 = 0xF7;
        t.fenceCreated(f2, false);
        t.submitted(f2, {}, kQueue, kDevice, {}, nullptr, &b);
        assert(t.waitFences(&f2, 1, true, later()) == Answer::DeviceLost);
        assert(t.speculatedWaits() == 1);
    }
    {
        // Another device stream waits for the records before its next command; the feed's end
        // releases it.
        Tracker t;
        t.speculation(3);
        const uint64_t sem = 0x5C;
        t.timelineCreated(sem, 0, kDevice);
        watched(t);
        const uint64_t s = signal(t, sem, 1);
        assert(reached(t, sem, 1));
        std::atomic<bool> released{false};
        std::thread other([&] {
            assert(t.beforeCommand(kOther).empty());
            released = true;
        });
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        assert(!released);
        t.complete(s, kCompleted);
        other.join();
        assert(released);
        // Watches sent on another stream are not speculated while these are held on this one.
        const uint64_t s2 = signal(t, sem, 2);
        assert(reached(t, sem, 2));
        const uint64_t s3 = signal(t, sem, 3, kQueue2, batch(kOther));
        watched(t, kQueue2);
        assert(!reached(t, sem, 3, soon()));
        t.complete(s2, kCompleted);
        t.beforeCommand(kStream);
        assert(reached(t, sem, 3));
        t.complete(s3, kCompleted);
        const uint64_t s4 = signal(t, sem, 4);
        assert(reached(t, sem, 4));
        t.feedClosed();
        assert(t.beforeCommand(kOther).empty());
        (void)s4;
    }
    {
        // Any-of waits speculate the first fence that qualifies.
        Tracker t;
        t.speculation(3);
        const uint64_t f1 = 0xF5, f2 = 0xF6;
        t.fenceCreated(f1, false);
        t.fenceCreated(f2, false);
        watched(t);
        watched(t, kQueue2);
        Batch writes = batch();
        writes.hostWrites = true;
        const Batch b = batch();
        t.submitted(f1, {}, kQueue, kDevice, {}, nullptr, &writes);
        t.submitted(f2, {}, kQueue2, kDevice, {}, nullptr, &b);
        const uint64_t both[] = {f1, f2};
        assert(t.waitFences(both, 2, false, later()) == Answer::Satisfied);
        assert(t.fencesSignaled(&f2, 1, true) == Answer::Satisfied);
        assert(t.fencesSignaled(&f1, 1, true) == Answer::NotYet);
        assert(t.waitFences(both, 2, true, soon()) == Answer::NotYet);
    }
    {
        // A new executor connection forgets what was held: its streams are new.
        Tracker t;
        t.speculation(3);
        const uint64_t sem = 0x5D;
        t.timelineCreated(sem, 0, kDevice);
        watched(t);
        signal(t, sem, 1);
        assert(reached(t, sem, 1) && t.speculating());
        t.loseAll();
        assert(t.beforeCommand(kStream).empty());
        t.revive();
        assert(!t.speculating());
        t.timelineCreated(sem, 0, kDevice);
        signal(t, sem, 1);
        assert(!reached(t, sem, 1, soon()));  // the new executor has not answered for the queue yet
    }
    return 0;
}
