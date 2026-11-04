// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// A guard, not #pragma once: packaging copies this header beside the public one.
#ifndef CABOOSE_GPU_EXECUTOR_STATS_ABI_H
#define CABOOSE_GPU_EXECUTOR_STATS_ABI_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

// The executor's always-on counters (docs/gpu-live.md, "Executor stats"): totals since the
// runtime started, except `outstanding` (completion watches waiting now) and
// `outstanding_max` (the most waiting at once since the previous read).
typedef struct caboose_gpu_executor_stats {
    uint64_t size;           // sizeof(caboose_gpu_executor_stats)
    uint64_t commands;       // commands decoded
    uint64_t decode_us;      // time inside the decoder
    uint64_t read_bytes;     // bytes read from the computer's streams
    uint64_t read_wait_us;   // time spent waiting for those bytes
    uint64_t flush_us;       // time writing replies
    uint64_t submitted;      // completion watches submitted to queues
    uint64_t completed;      // of those, completed by the GPU
    uint64_t completion_us;  // submit-to-completion time of the completed watches
    uint64_t gpu_busy_us;    // time the GPU had watched work in flight, counted once
    uint64_t outstanding;
    uint64_t outstanding_max;
} caboose_gpu_executor_stats;

// Fills `out` (with out->size set by the caller to its sizeof); 0, or EINVAL.
int caboose_gpu_runtime_executor_stats(caboose_gpu_executor_stats* out);

#ifdef __cplusplus
}
#endif
#endif  // CABOOSE_GPU_EXECUTOR_STATS_ABI_H
