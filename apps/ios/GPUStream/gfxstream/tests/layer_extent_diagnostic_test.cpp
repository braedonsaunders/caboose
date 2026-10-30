// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "layer_extent_diagnostic.h"
#include <cassert>
#include <limits>
#include <cstdio>
using namespace caboose::gpuv2;
int main() {
    LayerExtentSnapshot finite({763, 1116, 1, 640, 480});
    assert(finite.finite == 31 && finite.values[0] == 763 && finite.values[3] == 640);
    LayerExtentSnapshot mixed({NAN, INFINITY, 1, -INFINITY, 0});
    assert(mixed.finite == 20);
    assert(mixed.values[0] == 0 && mixed.values[1] == 0 && mixed.values[3] == 0);
    assert(mixed.values[4] == 0); // observed zero retains its finite bit
    LayerExtentDiagnosticBudget budget;
    for (unsigned i = 0; i < 65; ++i) assert(budget.take() == i);
    for (unsigned i = 0; i < 1000; ++i) assert(budget.take() == 65);
    std::puts("layer extent diagnostic finite-mask/budget PASS");
}
