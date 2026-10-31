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

    const std::vector<std::string> none;
    assert(lossPolicy(nullptr, "vkcube", none).empty());
    assert(lossPolicy("restart", "vkcube", none) == "restart");
    assert(lossPolicy("pause", "/usr/lib/chromium/chromium --type=gpu-process", none) == "pause");
    assert(lossPolicy("auto", "/usr/lib/chromium/chromium --type=gpu-process --foo", none) == "restart");
    assert(lossPolicy("auto", "/usr/share/code/code --type=gpu-process", none) == "restart");
    assert(lossPolicy("auto", "/usr/lib/chromium/chromium --type=renderer", none) == "pause");
    assert(lossPolicy("auto", "qml6 a.qml", {"/usr/lib/x86_64-linux-gnu/libQt6Gui.so.6"}) == "restart");
    assert(lossPolicy("auto", "keepassxc", {"/usr/lib/x86_64-linux-gnu/libQt5Gui.so.5.15.15"}) == "restart");
    assert(lossPolicy("auto", "glxgears", {"/usr/lib/x86_64-linux-gnu/libGLX_mesa.so.0"}) == "pause");
    assert(lossPolicy("bogus", "glxgears", none).empty());
    std::puts("routing tests passed");
}
