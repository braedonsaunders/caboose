// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "guest_gpu_completion.h"
#include <cassert>
#include <chrono>
#include <future>
using caboose::gpuv2::GuestGpuCompletion;
int main() {
    GuestGpuCompletion tracker;
    assert(!tracker.tryRelease().valid());
    tracker.enableAuditedCoverage();
    auto work = tracker.begin(1);
    auto overlapping = tracker.beforeDeviceIdle();
    tracker.end(work);
    tracker.afterIdle(overlapping, true);
    assert(!tracker.tryRelease().valid());
    auto snapshot = tracker.beforeDeviceIdle();
    auto later = tracker.begin(2); tracker.end(later);
    tracker.afterIdle(snapshot, true);
    assert(!tracker.tryRelease().valid());
    auto first = tracker.beforeQueueIdle(1); tracker.afterIdle(first, true);
    assert(!tracker.tryRelease().valid());
    auto second = tracker.beforeQueueIdle(2); tracker.afterIdle(second, false);
    assert(!tracker.tryRelease().valid());
    tracker.afterIdle(second, true);
    auto guard = tracker.tryRelease(); assert(guard.valid());
    auto pending = std::async(std::launch::async, [&] { return tracker.begin(1); });
    assert(pending.wait_for(std::chrono::milliseconds(30)) == std::future_status::timeout);
    guard = {};
    auto admitted = pending.get(); assert(admitted.active); tracker.end(admitted);
    assert(!tracker.tryRelease().valid());
    auto idle = tracker.beforeDeviceIdle(); tracker.afterIdle(idle, true);
    assert(tracker.tryRelease().valid());
    tracker.prepareAdmission(); // lookup has begun but has not reached the gate
    assert(!tracker.tryRelease().valid());
    auto prepared = tracker.begin(2, true);
    tracker.end(prepared);
    assert(!tracker.tryRelease().valid());
    tracker.invalidate();
    assert(!tracker.tryRelease().valid());
}
