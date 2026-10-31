// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "presentation_capture_state.h"
#include <cassert>
using caboose::gpuv2::PresentationCaptureState;
int main() {
    PresentationCaptureState s;
    assert(s.reserve(1) == -1); // no ring yet
    s.reset(2);
    assert(s.idle());
    assert(s.reserve(0) == -1); // serials are nonzero
    assert(s.reserve(1) == 0);
    assert(s.reserve(1) == -1); // one capture per present
    assert(!s.idle());
    assert(s.reserve(2) == 1);
    assert(s.reserve(3) == -1); // every slot written: present without a capture
    uint32_t first = 0, second = 0;
    assert(s.complete(1, &first));
    assert(!s.complete(1, &first)); // completion is reported once
    assert(s.abort(2)); // never submitted
    assert(!s.complete(2, &second));
    assert(s.idle());
    assert(s.reserve(4) == 1); // the aborted slot is free; the lent one is not
    assert(s.reserve(5) == -1);
    assert(s.release(first));
    assert(!s.release(first)); // released once
    assert(s.reserve(5) == 0);
    s.quarantine(5); // outcome unknown: the slot is never reused
    assert(!s.idle());
    assert(!s.complete(5, &second));
    assert(s.complete(4, &second));
    assert(s.reserve(6) == -1);
    // A replaced ring ignores releases of its predecessor's slots.
    s.reset(1);
    assert(s.idle());
    assert(!s.release(second));
    assert(s.reserve(7) == 0);
    uint32_t third = 0;
    assert(s.complete(7, &third));
    assert((third >> 8) != (second >> 8));
    assert(s.release(third));
    assert(!s.release(0xffffffffu));
}
