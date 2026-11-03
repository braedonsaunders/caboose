// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "memory_budget.h"
#include "caboose_memory_budget.h"
#include <atomic>
#include <cinttypes>
#include <cstdio>

namespace caboose::gpuv2 {
namespace {
constexpr uint64_t kHeadroomReserve = 384ull << 20;
std::atomic<uint64_t> explicitLimit{0};
std::atomic<uint64_t> refusals{0};

struct Usage {
    uint64_t guest = 0, cap = 0, allocated = 0, deviceLimit = 0, headroom = 0;
    bool platform = false;
};
Usage usage() {
    Usage u;
    u.guest = guestDeviceMemoryBytes().load(std::memory_order_relaxed);
    u.cap = explicitLimit.load(std::memory_order_relaxed);
    u.platform = platformGpuMemory(&u.allocated, &u.deviceLimit, &u.headroom);
    return u;
}

bool admit(uint32_t context, uint64_t request, uint64_t) {
    const Usage u = usage();
    const char* reason = nullptr;
    if (u.cap && u.guest + request > u.cap) reason = "limit";
    else if (u.platform && u.deviceLimit && u.allocated + request > u.deviceLimit) reason = "device";
    else if (u.platform && u.headroom && u.headroom < request + kHeadroomReserve) reason = "headroom";
    if (!reason) return true;
    // Each of the first 64, then every 64th.
    const uint64_t n = refusals.fetch_add(1, std::memory_order_relaxed);
    if (n < 64 || n % 64 == 0) {
        std::fprintf(stderr,
            "CABOOSE_GPU_MEMORY_REFUSED context=%u request=%" PRIu64 " guest=%" PRIu64 " limit=%" PRIu64
            " allocated=%" PRIu64 " device_limit=%" PRIu64 " headroom=%" PRIu64 " reason=%s refusals=%" PRIu64 "\n",
            context, request, u.guest, u.cap, u.allocated, u.deviceLimit, u.headroom, reason, n + 1);
    }
    return false;
}
}  // namespace

void installMemoryBudget() { deviceMemoryAdmission().store(&admit); }

void setMemoryLimit(uint64_t bytes) { explicitLimit.store(bytes, std::memory_order_relaxed); }

bool memoryPressure() {
    const Usage u = usage();
    if (u.cap && u.guest > u.cap / 100 * 85) return true;
    if (u.platform && u.deviceLimit && u.allocated > u.deviceLimit / 100 * 85) return true;
    if (u.platform && u.headroom && u.headroom < 2 * kHeadroomReserve) return true;
    return false;
}

#if !defined(__APPLE__)
// Elsewhere (the Linux executor) the platform tells nothing; the explicit limit applies.
bool platformGpuMemory(uint64_t* allocated, uint64_t* deviceLimit, uint64_t* headroom) {
    *allocated = *deviceLimit = *headroom = 0;
    return false;
}
#endif
}  // namespace caboose::gpuv2
