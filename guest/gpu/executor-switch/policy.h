// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
//
// The executor switch's decisions (README.md), apart from Vulkan so they can be tested alone.
#pragma once

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace caboose_switch {

// lavapipe's vendor ID. The routing layer may present lavapipe as a virtual GPU while no
// phone is attached, so a CPU implementation is recognised by its vendor too.
constexpr uint32_t kMesaVendor = 0x10005;

inline bool cpuImplementation(uint32_t vendor, int deviceType) {
    return deviceType == 4 /* VK_PHYSICAL_DEVICE_TYPE_CPU */ || vendor == kMesaVendor;
}

// Whether a process moves to the phone when one attaches: its CPU devices report loss and it
// recreates them on the phone. That suits processes that recover from device loss, which is
// what CABOOSE_GPU_ON_LOSS says, as the phone's driver reads it: `pause` stays where it is;
// `auto` moves Chromium-family GPU processes and Qt and leaves everything else; anything else,
// including no value, moves.
inline bool movesToPhone(const char* mode, const std::string& commandLine,
                         const std::vector<std::string>& libraries) {
    if (!mode) return true;
    if (std::strcmp(mode, "pause") == 0) return false;
    if (std::strcmp(mode, "auto") != 0) return true;
    if (commandLine.find("--type=gpu-process") != std::string::npos) return true;
    for (const auto& library : libraries) {
        const auto slash = library.rfind('/');
        const std::string name = slash == std::string::npos ? library : library.substr(slash + 1);
        if (name.rfind("libQt5Gui.so", 0) == 0 || name.rfind("libQt6Gui.so", 0) == 0) return true;
    }
    return false;
}

// The placement record of a process left on the computer's CPU after a phone attached, for
// the running-apps list (guest/scopes): its start time in clock ticks identifies it across
// pid namespaces (Flatpak).
inline std::string placementLine(uint64_t startTicks) {
    return "cpu-until-relaunch " + std::to_string(startTicks) + "\n";
}

// Field 22 of /proc/<pid>/stat, after the command name, which may contain spaces and ')'.
inline uint64_t startTicks(const std::string& stat) {
    const auto close = stat.rfind(')');
    if (close == std::string::npos) return 0;
    size_t at = close + 1;
    for (int field = 3; field <= 22; ++field) {
        while (at < stat.size() && stat[at] == ' ') ++at;
        if (field == 22) return std::strtoull(stat.c_str() + at, nullptr, 10);
        while (at < stat.size() && stat[at] != ' ') ++at;
    }
    return 0;
}

}  // namespace caboose_switch
