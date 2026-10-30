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
int caboose_gpu_runtime_open(uint64_t* token);
// Blocking, ordered raw decoder connection. The caller retains the descriptor.
int caboose_gpu_runtime_run(uint64_t token, int fd, size_t max_packet, size_t max_reply_buffer);
int caboose_gpu_runtime_stop(uint64_t token);
// Call off UI/network threads after all run calls return. Waits for upstream
// process cleanup. First retire all GPU surface work on a worker and detach
// each surface on main, releasing its decoder-instance lease; otherwise cleanup
// waits for that lease and cannot finish.
int caboose_gpu_runtime_finish(uint64_t token);

#ifdef __cplusplus
}
#endif
