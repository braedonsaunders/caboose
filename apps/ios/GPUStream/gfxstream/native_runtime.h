// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <vulkan/vulkan.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef void* (*caboose_gpu_resolve_export)(const char* name);
#ifdef CABOOSE_GPU_INDEXED_WSI
// Experimental v4 only; the caller must validate CBGLREF1 version 4/mask 0x70
// before opening a process. Cannot share an initialized runtime with v2/v3.
int caboose_gpu_runtime_start_v4(PFN_vkGetInstanceProcAddr get,
                                         caboose_gpu_resolve_export resolve);
#endif
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
#ifdef CABOOSE_GPU_DECODER_TESTING
int caboose_gpu_runtime_run_counted(uint64_t token, int fd, size_t max_packet,
                                    size_t max_reply_buffer, uint64_t* entries);
#endif
// Blocks until the process's device stream has decoded ORDER mark `serial`, or
// ECANCELED once it stops. Ordering only: never waits for GPU work.
int caboose_gpu_runtime_wait_order(uint64_t token, uint64_t serial);
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
