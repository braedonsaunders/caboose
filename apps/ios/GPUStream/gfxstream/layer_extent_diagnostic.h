// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
namespace caboose::gpuv2 {
struct LayerExtentSnapshot {
    // bounds width/height, contents scale, drawable width/height. A zero with
    // its finite bit clear is unavailable, not an observed zero dimension.
    std::array<double, 5> values{};
    uint32_t finite = 0;
    explicit LayerExtentSnapshot(const std::array<double, 5>& raw) {
        for (size_t i = 0; i < raw.size(); ++i) {
            if (std::isfinite(raw[i])) { values[i] = raw[i]; finite |= 1u << i; }
        }
    }
};
class LayerExtentDiagnosticBudget {
public:
    // 0..63 are records, 64 is the one overflow marker, 65 is suppressed.
    unsigned take() {
        unsigned value = count_.load(std::memory_order_relaxed);
        while (value < 65 && !count_.compare_exchange_weak(value, value + 1,
                                                        std::memory_order_relaxed)) {}
        return value;
    }
private:
    std::atomic_uint count_{0};
};
}
