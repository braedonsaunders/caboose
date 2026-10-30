// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "headless_framebuffer.h"
#include "frame_buffer.h"
#include "gfxstream/host/features.h"

namespace caboose::gpuv2 {
bool initializeHeadlessFramebuffer(const gfxstream::host::FeatureSet& features) {
    using gfxstream::host::FrameBuffer;
    // GuestVulkanOnly selects upstream's real offscreen Vulkan compositor.
    // Direct mapping assumes shared physical memory absent from socket transport.
    if (FrameBuffer::getFB() || !features.Vulkan.enabled() ||
        !features.GuestVulkanOnly.enabled() || features.VulkanNativeSwapchain.enabled() ||
        features.GlDirectMem.enabled() || features.VirtioGpuNext.enabled()) return false;
    if (!FrameBuffer::initialize(1, 1, features, false)) return false;
    if (!FrameBuffer::getFB() || !FrameBuffer::getFB()->hasEmulationVk()) {
        FrameBuffer::finalize();
        return false;
    }
    return true;
}
void finalizeHeadlessFramebuffer() { gfxstream::host::FrameBuffer::finalize(); }
}
