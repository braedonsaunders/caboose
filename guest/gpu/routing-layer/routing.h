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
// by the slowest one it is offered, sees only the phone. Without the phone they are listed
// again, last.
inline void hideCpuBesidePhone(std::vector<int>& ranks) {
    if (std::find(ranks.begin(), ranks.end(), rank(kPhoneVendor, 0)) == ranks.end()) return;
    for (int& r : ranks) if (r == rank(0, kCpu)) r = kHidden;
}

// While no phone is listed (it has not attached since the process started), a CPU
// implementation is presented as a virtual GPU under this name: applications that decide
// their rendering path once at launch take their GPU paths (an OpenGL on Vulkan refuses CPU
// devices), and they move to the phone when it attaches (the executor switch).
inline constexpr const char* kNoPhoneName = "Caboose GPU (no phone attached)";
inline constexpr const char* kNoPhoneDriverName = "Caboose";
inline bool presentsCpuAsGpu(const std::vector<int>& ranks) {
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

}  // namespace caboose_routing
