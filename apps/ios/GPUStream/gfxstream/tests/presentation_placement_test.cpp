// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "presentation_placement.h"
#include <cassert>
#include <cstdio>
using caboose::gpuv2::PresentationPlacement;
using caboose::gpuv2::placePresentation;
using Kind = PresentationPlacement::Kind;
int main() {
    // The same size is a plain copy.
    auto same = placePresentation(1338, 911, 1338, 911);
    assert(same.kind == Kind::copy && same.copyWidth == 1338 && same.copyHeight == 911 && !same.clear);

    // Overscan: lengthened along one axis, shown top-left and unscaled.
    auto tall = placePresentation(1338, 1400, 1338, 911);
    assert(tall.kind == Kind::copy && tall.copyWidth == 1338 && tall.copyHeight == 911 && !tall.clear);
    auto wide = placePresentation(2000, 911, 1338, 911);
    assert(wide.kind == Kind::copy && wide.copyWidth == 1338 && wide.copyHeight == 911);

    // A game kept at 1338x911 after its window became 1902x1338 (a fold opened): scaled up
    // to the window's full width, centred, never pinned top-left at its old size.
    auto unfolded = placePresentation(1338, 911, 1902, 1338);
    assert(unfolded.kind == Kind::scale);
    assert(unfolded.width == 1902 && unfolded.height == 1295);
    assert(unfolded.x == 0 && unfolded.y == 21 && unfolded.clear);

    // Smaller in both directions: scaled down, letterboxed at the sides.
    auto folded = placePresentation(1920, 1080, 1338, 911);
    assert(folded.kind == Kind::scale);
    assert(folded.height == 753 && folded.width == 1338 && folded.y == 79 && folded.x == 0);

    // Taller than the window's shape: pillarboxed.
    auto portrait = placePresentation(800, 1200, 1600, 900);
    assert(portrait.kind == Kind::scale && portrait.height == 900 && portrait.width == 600);
    assert(portrait.x == 500 && portrait.y == 0 && portrait.clear);

    // The same shape at another size fills exactly, as does a fit within two pixels.
    auto doubled = placePresentation(640, 480, 1280, 960);
    assert(doubled.kind == Kind::scale && doubled.x == 0 && doubled.y == 0);
    assert(doubled.width == 1280 && doubled.height == 960 && !doubled.clear);
    auto nearly = placePresentation(999, 700, 2000, 1400);
    assert(nearly.width == 2000 && nearly.height == 1400 && !nearly.clear);

    // Larger in both directions (not an overscan): scaled down whole.
    auto larger = placePresentation(2000, 1500, 1000, 700);
    assert(larger.kind == Kind::scale && larger.height == 700 && larger.width == 933);
    assert(larger.x == 33 && larger.clear);

    std::puts("presentation placement PASS");
}
