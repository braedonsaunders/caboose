// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "memory_budget.h"
#import <Metal/Metal.h>
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#include <os/proc.h>
#endif

namespace caboose::gpuv2 {
// The system default device is the one MoltenVK runs the guests on.
bool platformGpuMemory(uint64_t* allocated, uint64_t* deviceLimit, uint64_t* headroom) {
    static id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    *allocated = *deviceLimit = *headroom = 0;
    if (!device) return false;
    *allocated = device.currentAllocatedSize;
    *deviceLimit = device.recommendedMaxWorkingSetSize / 4 * 3;
#if TARGET_OS_IPHONE
    *headroom = os_proc_available_memory();
#endif
    return true;
}
}  // namespace caboose::gpuv2
