// SPDX-License-Identifier: MIT
#include "feature_mask.h"
#include <cassert>
#include <cstdlib>
using namespace caboose::features;

int main() {
    constexpr uint32_t all = 0x3ff80 | 0x80000 | 0x100000 | 0x200000 | 0x400000 | 0x800000 | 0x1000000;
    static_assert(offered(all, 0) == all);
    // Dropping a leaf drops only it.
    static_assert(offered(all, 0x80000) == (all & ~0x80000u));
    static_assert(offered(all, 0x1000000) == (all & ~0x1000000u));
    // Silent success takes one-way start with it; the completion feed takes everything that needs it.
    static_assert(offered(all, 0x800000) == (all & ~(0x800000u | 0x1000000u)));
    static_assert(offered(all, 0x200) == (all & ~(0x200u | 0x200000u | 0x400000u | 0x800000u | 0x1000000u)));
    // Guest handles take arrays, query pools, buffer views, set ids, silent success and one-way start.
    static_assert(offered(all, 0x80) ==
                  (all & ~(0x80u | 0x100u | 0x1000u | 0x10000u | 0x100000u | 0x800000u | 0x1000000u)));
    setenv("CABOOSE_GFXSTREAM_FEATURES_MASK", "0x800000", 1);
    assert(droppedFromEnvironment() == (0x800000u | 0x1000000u));
    return 0;
}
