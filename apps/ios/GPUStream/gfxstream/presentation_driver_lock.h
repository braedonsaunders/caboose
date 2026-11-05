// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
// The Vulkan loader's tables of instances and their drivers are not safe for its WSI entry
// points (surface creation and destruction, surface queries, swapchain creation) while another
// thread makes or destroys an instance or device or enumerates physical devices: the loader's
// swapchain terminator walks every instance's drivers. The decoder makes those calls under the
// graphics driver lock, and presentation makes its loader WSI calls under the same lock. The
// decoder never waits for a presentation while it holds the lock.
#include "gfxstream/host/graphics_driver_lock.h"

namespace caboose::gpuv2 {
class DriverLock {
public:
    DriverLock() : lock_(*gfxstream::host::graphicsDriverLock()) {}

private:
    gfxstream::base::AutoLock lock_;
};
}
