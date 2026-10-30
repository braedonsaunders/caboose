// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

// Initializes the single statically linked Vulkan provider. Call off the main
// thread. A failed first initialization is terminal until the app restarts.
// Versioned symbol prevents an older package from negotiating live v3 while
// initializing the incompatible non-WSI provider mode. Requires exact v3/0x30.
int caboose_gpu_live_start_v3(void);
int caboose_gpu_runtime_open(uint64_t* token);
// Blocking, ordered raw decoder connection. The caller retains the descriptor.
int caboose_gpu_runtime_run(uint64_t token, int fd, size_t max_packet, size_t max_reply_buffer);
int caboose_gpu_runtime_stop(uint64_t token);
// Call off UI/network threads after all run calls return. Waits for upstream
// process cleanup; presentation resources require their own retirement barrier.
int caboose_gpu_runtime_finish(uint64_t token);

#ifdef __cplusplus
}
#endif
