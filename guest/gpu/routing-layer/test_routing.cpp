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

    // With the phone listed, lavapipe is not; without it, it is, last.
    std::vector<int> withPhone = {rank(0x10005, kCpu), rank(kPhoneVendor, kIntegrated), rank(0x10de, kDiscrete)};
    hideCpuBesidePhone(withPhone);
    assert((withPhone == std::vector<int>{kHidden, rank(kPhoneVendor, kIntegrated), rank(0x10de, kDiscrete)}));
    std::vector<int> withoutPhone = {rank(0x10005, kCpu), rank(0x10de, kDiscrete)};
    hideCpuBesidePhone(withoutPhone);
    assert((withoutPhone == std::vector<int>{rank(0x10005, kCpu), rank(0x10de, kDiscrete)}));
    std::vector<int> phoneHidden = {rank(0x10005, kCpu), kHidden};  // fossilize_replay
    hideCpuBesidePhone(phoneHidden);
    assert(phoneHidden[0] == rank(0x10005, kCpu));

    assert(hidesPhone("/home/u/.local/share/Steam/ubuntu12_64/fossilize_replay a.foz --device-index 0"));
    assert(hidesPhone("fossilize_replay"));
    assert(!hidesPhone("/usr/bin/vkcube"));
    assert(!hidesPhone("/opt/fossilize_replay_wrapper --x"));
    assert(!hidesPhone(""));

    // Without the phone, lavapipe is presented as a GPU; not with it, nor where the phone is
    // hidden by policy (fossilize_replay compiles for the device it really runs on).
    assert(presentsCpuAsGpu({rank(0x10005, kCpu)}, false));
    assert(!presentsCpuAsGpu({rank(0x10005, kCpu), rank(kPhoneVendor, kIntegrated)}, false));
    assert(!presentsCpuAsGpu({rank(0x10005, kCpu)}, true));

    std::puts("routing tests passed");
}
