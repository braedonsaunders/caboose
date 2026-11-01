// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "policy.h"

#include <cassert>
#include <cstdio>

using namespace caboose_switch;

int main() {
    // lavapipe, by type or (presented as a GPU) by vendor; nothing else.
    assert(cpuImplementation(0x10005, 4));
    assert(cpuImplementation(0x10005, 3));
    assert(cpuImplementation(0x1234, 4));
    assert(!cpuImplementation(0x106b, 1));
    assert(!cpuImplementation(0x10de, 2));

    const std::vector<std::string> none, qt{"/usr/lib/x86_64-linux-gnu/libQt6Gui.so.6"};
    assert(movesToPhone(nullptr, "vkcube", none));
    assert(movesToPhone("restart", "vkcube", none));
    assert(!movesToPhone("pause", "chromium --type=gpu-process", none));
    assert(movesToPhone("auto", "steamwebhelper --type=gpu-process --x", none));
    // Steam's GPU process, forked from its zygote, carries the zygote's command line.
    assert(movesToPhone("auto", "steamwebhelper --type=zygote --no-zygote-sandbox --no-sandbox", none));
    assert(!movesToPhone("pause", "steamwebhelper --type=zygote", none));
    assert(movesToPhone("auto", "qml6 a.qml", qt));
    assert(!movesToPhone("auto", "glxgears", none));
    assert(!movesToPhone("auto", "chromium --type=renderer", none));

    // Steam's web views, its update window and fossilize_replay stay on the computer.
    assert(keptOnComputer("/home/u/.local/share/Steam/steamrt64/steamwebhelper --type=zygote --no-zygote-sandbox"));
    assert(keptOnComputer("./steamwebhelper -nocrashdialog -lang=en_US"));
    assert(keptOnComputer("/s/steamrt64/steam -child-update-ui -child-update-ui-socket 9"));
    assert(keptOnComputer("fossilize_replay a.foz"));
    assert(!keptOnComputer("/s/steamrt64/steam -srt-logger-opened"));
    assert(!keptOnComputer("Z:\\MCC\\Binaries\\Win64\\MCC-Win64-Shipping.exe -no-eac"));

    assert(placementLine(123456) == "cpu-until-relaunch 123456\n");
    // A command name with spaces and ')' does not shift the fields.
    std::string stat = "4242 (my app) x) S";
    for (int field = 4; field <= 21; ++field) stat += " " + std::to_string(field);
    stat += " 987654 23 24";
    assert(startTicks(stat) == 987654);
    assert(startTicks("garbage") == 0);
    std::puts("executor switch policy tests passed");
}
