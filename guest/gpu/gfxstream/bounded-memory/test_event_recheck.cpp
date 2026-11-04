// A locally answered reset poll asks the device after the recheck delay, then every delay.
#include "event_status.h"

#include <cassert>
#include <cstdio>

int main() {
    caboose::memory::EventRecheck recheck;
    const int64_t d = caboose::memory::EventRecheck::kRecheckMs;
    assert(!recheck.due(7, 1000));
    assert(!recheck.due(7, 1000 + d - 1));
    assert(recheck.due(7, 1000 + d));
    assert(!recheck.due(7, 1000 + d + 1));
    assert(recheck.due(7, 1000 + 2 * d));
    // Another event starts its own poll.
    assert(!recheck.due(8, 5000));
    assert(recheck.due(8, 5000 + d));
    recheck.done(8);
    assert(!recheck.due(8, 6000));
    std::puts("event recheck: a stalled reset poll asks the device every recheck delay");
    return 0;
}
