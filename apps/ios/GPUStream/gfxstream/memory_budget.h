// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <cstdint>

namespace caboose::gpuv2 {
// The phone's device memory budget (docs/gpu-live.md, "Memory budget"). Installed at runtime
// start as the decoder's allocation admission (caboose_memory_budget.h in the fork): a guest
// allocation is refused with VK_ERROR_OUT_OF_DEVICE_MEMORY when it would take the GPU device
// past three quarters of its recommended working set, leave the app less than 384 MiB of
// memory before the system ends it, or take what guests hold past the explicit limit.
void installMemoryBudget();
// An explicit limit on the device memory guests hold, in bytes; 0 for none.
void setMemoryLimit(uint64_t bytes);
// True while memory is short (past 85% of a limit, or less than twice the reserve left):
// what the phone can do without, such as presented-picture capture rings, is given up.
bool memoryPressure();
// The platform's view: the GPU device's allocated bytes, the limit derived from the device,
// and the memory the app has left. False where the platform tells none (then all are 0).
bool platformGpuMemory(uint64_t* allocated, uint64_t* deviceLimit, uint64_t* headroom);
}  // namespace caboose::gpuv2
