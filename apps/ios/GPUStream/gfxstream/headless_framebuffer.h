// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
namespace gfxstream::host { class FeatureSet; }
namespace caboose::gpuv2 {
// Experimental source integration: caller serializes process-global init and
// teardown, installs the shared loader first, and joins every decoder and
// completes process cleanup before finalize. Never enable this as an app feature
// until mapped memory, schema, and input validation are proven.
bool initializeHeadlessFramebuffer(const gfxstream::host::FeatureSet& features);
void finalizeHeadlessFramebuffer();
}
