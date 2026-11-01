// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "routing.h"

#include <cassert>
#include <cstdio>

using namespace caboose_routing;

int main() {
    // lavapipe, an NVIDIA GPU, the phone, a virtual GPU: the phone first, the CPU last.
    std::vector<int> ranks = {rank(0x10005, kCpu), rank(0x10de, kDiscrete), rank(kPhoneVendor, kIntegrated),
                              rank(0x1af4, kVirtual)};
    assert((order(ranks) == std::vector<size_t>{2, 1, 3, 0}));
    // Equal ranks keep the driver's order.
    assert((order({2, 1, 2, 1}) == std::vector<size_t>{1, 3, 0, 2}));
    assert(order({}).empty());

    assert(hidesPhone("/home/u/.local/share/Steam/ubuntu12_64/fossilize_replay a.foz --device-index 0"));
    assert(hidesPhone("fossilize_replay"));
    assert(!hidesPhone("/usr/bin/vkcube"));
    assert(!hidesPhone("/opt/fossilize_replay_wrapper --x"));
    assert(!hidesPhone(""));

    std::puts("routing tests passed");
}
