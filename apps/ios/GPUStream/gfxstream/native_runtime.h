// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <vulkan/vulkan.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef void* (*caboose_gpu_resolve_export)(const char* name);
// Process-wide initialization. A failed first attempt is terminal until app restart.
// The loader, resolver and their backing library must remain valid for process life.
int caboose_gpu_runtime_start(PFN_vkGetInstanceProcAddr get, caboose_gpu_resolve_export resolve);
#ifdef CABOOSE_GPU_PRESENTATION_LEASE
// Only use when every guest swapchain in this process is the private virtual
// WSI. Guest PRESENT_SRC transitions are mapped to GENERAL on the host.
int caboose_gpu_runtime_start_virtual_wsi(PFN_vkGetInstanceProcAddr get,
                                           caboose_gpu_resolve_export resolve);
#endif
// Creates an independent upstream process; token is nonzero and never reused.
int caboose_gpu_runtime_open(uint64_t* token);
// Caller authenticates, binds the session and verifies the negotiated stream
// features before entry. Runs one ordered raw connection; caller retains fd.
int caboose_gpu_runtime_run(uint64_t token, int fd, size_t max_packet, size_t max_reply_buffer);
// Stop revokes admission, signals upstream cleanup and shuts down its streams.
int caboose_gpu_runtime_stop(uint64_t token);
// Finish only after every run has returned. Blocks for upstream queued process
// cleanup and must run off UI/network threads; it does not finalize the backend.
// Callers must serialize finish for a token and admit a replacement only after
// this call succeeds. Presentation resources need their own retirement proof.
int caboose_gpu_runtime_finish(uint64_t token);
#ifdef __cplusplus
}
#endif
