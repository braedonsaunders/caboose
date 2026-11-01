// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <cmath>
#include <cstdint>

namespace caboose::gpuv2 {
// Where an image presented to a surface of another size lands in the surface's image.
// A window's overscan (the source is the destination lengthened along one axis, the
// extra lying right of or below what the window shows) shows its top-left part unscaled.
// Any other size, such as a game that keeps its own resolution in a window that has since
// changed size, is scaled by the GPU's sampler to fit the destination with its aspect
// ratio, centred; a fit within two pixels of the destination fills it. Destination pixels
// the source does not cover are cleared.
struct PresentationPlacement {
    enum class Kind { copy, scale };
    Kind kind = Kind::copy;
    // Copy: the source's top-left part of this size, to the destination's top-left.
    uint32_t copyWidth = 0, copyHeight = 0;
    // Scale: the destination rectangle the whole source is scaled into.
    int32_t x = 0, y = 0;
    uint32_t width = 0, height = 0;
    bool clear = false;
};

inline PresentationPlacement placePresentation(uint32_t sourceWidth, uint32_t sourceHeight,
                                               uint32_t width, uint32_t height) {
    PresentationPlacement placement;
    const bool overscan = (sourceWidth == width && sourceHeight > height) ||
                          (sourceHeight == height && sourceWidth > width);
    if (!sourceWidth || !sourceHeight || !width || !height ||
        (sourceWidth == width && sourceHeight == height) || overscan) {
        placement.copyWidth = sourceWidth < width ? sourceWidth : width;
        placement.copyHeight = sourceHeight < height ? sourceHeight : height;
        return placement;
    }
    placement.kind = PresentationPlacement::Kind::scale;
    const double scale = std::fmin(double(width) / sourceWidth, double(height) / sourceHeight);
    double fitWidth = std::round(sourceWidth * scale), fitHeight = std::round(sourceHeight * scale);
    if (width - fitWidth <= 2) fitWidth = width;
    if (height - fitHeight <= 2) fitHeight = height;
    placement.width = uint32_t(fitWidth < 1 ? 1 : fitWidth);
    placement.height = uint32_t(fitHeight < 1 ? 1 : fitHeight);
    placement.x = int32_t((width - placement.width) / 2);
    placement.y = int32_t((height - placement.height) / 2);
    placement.clear = placement.width < width || placement.height < height;
    return placement;
}
}
