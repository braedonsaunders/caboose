// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "presentation_extent_state.h"
#include <cassert>
#include <cstdio>
using caboose::gpuv2::PresentationExtentState;
int main() {
    PresentationExtentState extent;
    assert(!extent.begin(640, 480)); // no provider limits observed
    assert(!extent.enable(0, 1, 4096, 4096));
    assert(!extent.enable(1, 1, UINT32_MAX, 4096));
    assert(extent.enable(1, 1, 4096, 4096));
    assert(!extent.matches(640, 480)); // query is not configuration
    assert(extent.begin(640, 480));
    assert(!extent.matches(640, 480)); // mutation not yet verified
    extent.complete(true);
    assert(extent.matches(640, 480));
    assert(!extent.matches(763, 1116)); // display size is not buffer size
    assert(!extent.begin(4097, 480));
    assert(extent.matches(640, 480)); // pre-mutation rejection preserves state
    assert(extent.enable(1, 1, 8192, 8192));
    assert(extent.matches(640, 480)); // repeated successful query preserves it
    assert(extent.enable(1, 1, 320, 240));
    assert(!extent.matches(640, 480)); // changed real limits invalidate admission
    assert(extent.begin(320, 240));
    extent.complete(false); // unknown mutation is sticky quarantine
    assert(extent.quarantined());
    assert(!extent.matches(320, 240));
    assert(!extent.begin(320, 240));
    assert(!extent.enable(1, 1, 8192, 8192));
    std::puts("presentation extent state PASS");
}
