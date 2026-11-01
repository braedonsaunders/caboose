// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
//
// The decisions of VK_LAYER_CABOOSE_gpu_routing (README.md), without Vulkan calls, so they
// are tested alone.
#pragma once

#include <algorithm>
#include <cstdint>
#include <string>
#include <vector>

namespace caboose_routing {

// The phone's GPU reports its own vendor: Apple's, which no other Linux driver does.
constexpr uint32_t kPhoneVendor = 0x106b;

// Physical device types, as VkPhysicalDeviceType numbers them.
enum DeviceType : int { kOther = 0, kIntegrated = 1, kDiscrete = 2, kVirtual = 3, kCpu = 4 };

// Lower ranks come first: the phone, then GPUs by type, CPU implementations last.
inline int rank(uint32_t vendor, int type) {
    if (vendor == kPhoneVendor) return 0;
    switch (type) {
        case kDiscrete: return 1;
        case kIntegrated: return 2;
        case kVirtual: return 3;
        case kCpu: return 5;
        default: return 4;
    }
}

// The order to list `ranks.size()` devices in: indexes into the driver's order, stable
// among equal ranks.
inline std::vector<size_t> order(const std::vector<int>& ranks) {
    std::vector<size_t> indexes(ranks.size());
    for (size_t i = 0; i < indexes.size(); ++i) indexes[i] = i;
    std::stable_sort(indexes.begin(), indexes.end(), [&](size_t a, size_t b) { return ranks[a] < ranks[b]; });
    return indexes;
}

// Whether the process is kept off the phone's GPU entirely. Steam's fossilize_replay
// compiles a game's recorded pipelines ahead of its launch, hundreds of thousands of them on
// as many threads as the computer has, for the driver's on-disk cache. The phone's driver
// keeps no cache on the computer, so on the phone that work would only be sent across the
// network and thrown away.
inline bool hidesPhone(const std::string& commandLine) {
    std::string program = commandLine.substr(0, commandLine.find(' '));
    auto slash = program.rfind('/');
    if (slash != std::string::npos) program = program.substr(slash + 1);
    return program == "fossilize_replay";
}

// What the driver does when the phone's GPU goes away (CABOOSE_GPU_ON_LOSS): "restart"
// reports device loss, which Chromium and Electron (their GPU process restarts) and Qt
// (its scene graph recreates its renderer) recover from; "pause" holds the application
// until the phone returns. "auto", the launch environment's value, is resolved here for
// the process: restart when it is a Chromium-family GPU process or uses Qt.
inline std::string lossPolicy(const char* configured, const std::string& commandLine,
                              const std::vector<std::string>& libraries) {
    std::string value = configured ? configured : "";
    if (value == "restart" || value == "pause") return value;
    if (value != "auto") return "";
    if (commandLine.find("--type=gpu-process") != std::string::npos) return "restart";
    for (const auto& library : libraries) {
        auto slash = library.rfind('/');
        std::string name = slash == std::string::npos ? library : library.substr(slash + 1);
        if (name.rfind("libQt5Gui.so", 0) == 0 || name.rfind("libQt6Gui.so", 0) == 0) return "restart";
    }
    return "pause";
}

}  // namespace caboose_routing
