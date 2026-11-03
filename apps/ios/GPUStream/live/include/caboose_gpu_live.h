// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __OBJC__
#import <QuartzCore/CAMetalLayer.h>
#endif
#include "presentation_api_draft.h"
#include "presentation_swapchain_api_draft.h"
#ifdef __cplusplus
extern "C" {
#endif

// Initializes the single statically linked Vulkan provider. Call off the main
// thread. A failed first initialization is terminal until the app restarts.
// Versioned symbol prevents an older package from negotiating live v4 while
// initializing the incompatible non-WSI provider mode. Requires exact v4/0x70.
int caboose_gpu_live_start_v4(void);
// Selects the connected computer's persistent shader and pipeline caches under the
// absolute directory `root` (docs/gpu-live.md, "Shader cache"), or none for NULL or on
// failure. Call before opening its processes; returns 0 or an errno.
int caboose_gpu_runtime_set_cache_root(const char* root);
int caboose_gpu_runtime_open(uint64_t* token);
// Blocking, ordered raw decoder connection. The caller retains the descriptor.
int caboose_gpu_runtime_run(uint64_t token, int fd, size_t max_packet, size_t max_reply_buffer);
// Blocks until the process's device stream has decoded its ORDER mark `serial`
// (an ordered present); ECANCELED once the process stops. Never waits for the GPU.
int caboose_gpu_runtime_wait_order(uint64_t token, uint64_t serial);
// Suspends all decoding before the app leaves the foreground (docs/gpu-live.md,
// "Suspending an executor"): running commands finish, no further one starts, then every
// queue is waited idle. 0, ETIMEDOUT (still suspending; running commands park when they
// finish) or EIO. Call off the main thread. Resume continues decoding.
int caboose_gpu_runtime_suspend(uint32_t timeout_ms);
int caboose_gpu_runtime_resume(void);
int caboose_gpu_runtime_stop(uint64_t token);
// Call off UI/network threads after all run calls return. Waits up to 4 s for upstream
// process cleanup, which then goes on by itself. First retire all GPU surface work on a
// worker and detach each surface on main, releasing its decoder-instance lease; a lease
// still held defers the instance's teardown until it is released.
int caboose_gpu_runtime_finish(uint64_t token);
// Prints the teardown report to standard error (docs/gpu-live.md, "Teardown report"): every
// process's state, what the decoder's teardown is doing and has deferred, and every queue's
// pending waits.
void caboose_gpu_runtime_report_teardown(void);

#ifdef __cplusplus
}
#endif
