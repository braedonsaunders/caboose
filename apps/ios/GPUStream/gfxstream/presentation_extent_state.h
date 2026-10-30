// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <cstdint>

namespace caboose::gpuv2 {
// Serialized by the surface operations lock. Display geometry is deliberately
// absent: these are buffer pixels bounded by an actual provider query.
class PresentationExtentState {
public:
    bool enable(uint32_t minWidth, uint32_t minHeight, uint32_t maxWidth, uint32_t maxHeight) {
        if (quarantined_ || !minWidth || !minHeight || minWidth > maxWidth || minHeight > maxHeight ||
            maxWidth == UINT32_MAX || maxHeight == UINT32_MAX) return false;
        minWidth_ = minWidth; minHeight_ = minHeight;
        maxWidth_ = maxWidth; maxHeight_ = maxHeight;
        enabled_ = true;
        if (!accepts(width_, height_)) configured_ = false;
        return true;
    }
    bool accepts(uint32_t width, uint32_t height) const {
        return enabled_ && !quarantined_ && width >= minWidth_ && width <= maxWidth_ &&
            height >= minHeight_ && height <= maxHeight_;
    }
    bool begin(uint32_t width, uint32_t height) {
        if (!accepts(width, height)) return false;
        configured_ = false;
        width_ = width; height_ = height;
        return true;
    }
    void complete(bool verified) {
        configured_ = verified && !quarantined_;
        if (!verified) quarantined_ = true;
    }
    bool matches(uint32_t width, uint32_t height) const {
        return configured_ && accepts(width, height) && width == width_ && height == height_;
    }
    bool enabled() const { return enabled_; }
    bool quarantined() const { return quarantined_; }
private:
    uint32_t minWidth_ = 0, minHeight_ = 0, maxWidth_ = 0, maxHeight_ = 0;
    uint32_t width_ = 0, height_ = 0;
    bool enabled_ = false, configured_ = false, quarantined_ = false;
};
}
