// The lock hierarchy: taking a lock above one held is reported once; the hierarchy's own order is not.
#include "lock_order.h"

#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <mutex>

namespace lo = caboose::lock_order;

static uint64_t bit(lo::Class held, lo::Class taken) {
    return uint64_t(1) << (unsigned(held) * lo::kClasses + unsigned(taken));
}

int main() {
    setenv("CABOOSE_LOCK_ORDER", "1", 1);
    lo::Mutex<std::mutex, lo::kEncoder> encoder;
    lo::Mutex<std::mutex, lo::kFlushShadow> shadow;
    lo::Mutex<std::recursive_mutex, lo::kTracker> tracker;
    {
        // The hierarchy's order, and the tracker taken again.
        std::lock_guard<decltype(encoder)> a(encoder);
        std::lock_guard<decltype(shadow)> b(shadow);
        std::lock_guard<decltype(tracker)> c(tracker);
        std::lock_guard<decltype(tracker)> d(tracker);
    }
    assert(lo::reported.load() == 0);
    {
        // The deadlock patch 0080 removed: the shadow taken while the tracker is held.
        std::lock_guard<decltype(tracker)> a(tracker);
        std::lock_guard<decltype(shadow)> b(shadow);
    }
    assert(lo::reported.load() == bit(lo::kTracker, lo::kFlushShadow));
    {
        // Reported once.
        std::lock_guard<decltype(tracker)> a(tracker);
        std::lock_guard<decltype(shadow)> b(shadow);
    }
    assert(lo::reported.load() == bit(lo::kTracker, lo::kFlushShadow));
    // A try never waits: it is not checked.
    {
        std::lock_guard<decltype(tracker)> a(tracker);
        assert(encoder.try_lock());
        encoder.unlock();
    }
    assert(lo::reported.load() == bit(lo::kTracker, lo::kFlushShadow));
    // Released locks are no longer held.
    assert(!lo::held.counts[lo::kTracker] && !lo::held.counts[lo::kEncoder]);
    std::puts("lock order: the hierarchy holds, an inversion is reported once");
    return 0;
}
