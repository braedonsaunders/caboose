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

// The rank of a device this process does not see.
constexpr int kHidden = -1;

// While the phone's GPU is listed, CPU implementations such as lavapipe are not: an
// application or toolkit that picks a device by its own rules, or that judges the computer
// by the slowest one it is offered (Steam disables its GPU web views), sees only the phone.
// Without the phone they are listed again, last.
inline void hideCpuBesidePhone(std::vector<int>& ranks) {
    if (std::find(ranks.begin(), ranks.end(), rank(kPhoneVendor, 0)) == ranks.end()) return;
    for (int& r : ranks) if (r == rank(0, kCpu)) r = kHidden;
}

// While no phone is listed (it has not attached since the process started, or the process
// is kept off it), a CPU implementation is presented as a virtual GPU under this name: apps
// that decide their rendering path once at launch (Chromium's and Steam's GPU acceleration,
// Firefox's WebRender, Zink, which refuses CPU devices) take their GPU paths, and those that
// recover from device loss move to the phone when it attaches (the executor switch).
inline constexpr const char* kNoPhoneName = "Caboose GPU (no phone attached)";
inline constexpr const char* kNoPhoneDriverName = "Caboose";
inline bool presentsCpuAsGpu(const std::vector<int>& ranks, bool phoneHidden, bool presentedWhenHidden = false) {
    if (phoneHidden) return presentedWhenHidden;
    return std::find(ranks.begin(), ranks.end(), rank(kPhoneVendor, 0)) == ranks.end();
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
//
// Steam's client (steamrt64/steam: its GPU probes and overlay need no phone, and a slow phone
// must never hold up its start) and its web views (steamwebhelper, all of its processes),
// whose Chromium on OpenGL sends
// the phone a command stream of several MB/s for one window: they render on the computer.
//
// Steam's update window, which its bootstrap shows from a child process (`-child-update-ui`)
// that keeps the bootstrap's single-instance pipe open until it exits. On the phone its OpenGL
// context (Zink) takes seconds to tear down across the network, long enough for the Steam
// client the bootstrap starts next to find the pipe still held, take it for a running Steam
// and exit. It draws a progress window on the computer's CPU instead, presented as a GPU as
// for a process with no phone (Zink refuses CPU devices).
inline bool keptOnComputer(const std::string& commandLine) {
    std::string program = commandLine.substr(0, commandLine.find(' '));
    const auto slash = program.rfind('/');
    if (slash != std::string::npos) program = program.substr(slash + 1);
    const std::string path = commandLine.substr(0, commandLine.find(' '));
    const bool steamClient = program == "steam" &&
        (path.find("/steamrt64/steam") != std::string::npos || path.find("/steamrt32/steam") != std::string::npos);
    return program == "steamwebhelper" || steamClient || commandLine.find(" -child-update-ui") != std::string::npos;
}
inline bool hidesPhone(const std::string& commandLine) {
    std::string program = commandLine.substr(0, commandLine.find(' '));
    auto slash = program.rfind('/');
    if (slash != std::string::npos) program = program.substr(slash + 1);
    return program == "fossilize_replay" || keptOnComputer(commandLine);
}

}  // namespace caboose_routing
