// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "presentation_index_state.h"
#include <cassert>
using caboose::gpuv2::PresentationIndexState;
int main() {
    PresentationIndexState s(2);
    assert(s.mayRetire());
    assert(!s.markAcquired(2));
    assert(s.markAcquired(0));
    assert(!s.markAcquired(0));
    assert(s.markAcquireReady(0));
    assert(s.beginPresent(0, 1));
    assert(s.markCopySubmitted(1));
    assert(s.markPresented(1));
    assert(s.markAcquired(0)); // earlier fence records must survive reacquire
    assert(s.markAcquireReady(0));
    assert(!s.sourceReusable(0));
    assert(!s.beginPresent(0, 2));
    assert(s.markSourceReleased(1));
    assert(s.sourceReusable(0));
    assert(s.beginPresent(0, 2));
    assert(s.markCopySubmitted(2));
    assert(s.markPresented(2));
    assert(!s.forgetRetired(1));
    assert(!s.forgetRetired(1));
    assert(s.markPresentRetired(1));
    assert(s.forgetRetired(1));
    assert(!s.mayRetire());
    assert(s.markPresentRetired(2));
    assert(s.markSourceReleased(2));
    assert(s.forgetRetired(2));
    assert(s.markAcquired(1));
    assert(s.markAcquireReady(1));
    assert(s.beginPresent(1, 3));
    assert(s.abortBeforeSubmit(3));
    assert(s.sourceReusable(1));
    assert(s.markUnusedReleased(1));
    assert(s.mayRetire());
    assert(s.markAcquired(1));
    s.quarantine(1);
    assert(!s.markUnusedReleased(1));
    assert(!s.mayRetire());
    PresentationIndexState partial(1);
    assert(partial.markAcquired(0));
    assert(partial.markAcquireReady(0));
    assert(partial.beginPresent(0, 1));
    assert(partial.markCopySubmitted(1));
    partial.quarantine(0); // present outcome unknown after submitted copy
    assert(partial.markSourceReleased(1)); // real copy completion remains reportable
    assert(!partial.forgetRetired(1));
    assert(!partial.mayRetire());
}
