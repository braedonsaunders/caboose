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
// Selects the connected computer's persistent caches: SPIR-V modules in `root/shaders`
// and pipelines in `root/pipeline` (docs/gpu-live.md, "Shader cache"). `root` is an
// absolute directory, created if needed; NULL selects none, as does a failure. Call
// before opening the computer's processes.
int caboose_gpu_runtime_set_cache_root(const char* root);
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
// Suspends every process's decoding (docs/gpu-live.md, "Suspending an executor"): each
// command already running finishes, no further command starts, and then every queue is
// waited idle. 0 once nothing runs on the GPU; ETIMEDOUT when a command is still running
// after `timeout_ms` (the gate stays closed and it parks when it finishes); EIO when a
// queue wait failed. Objects, memory and streams stay as they are.
int caboose_gpu_runtime_suspend(uint32_t timeout_ms);
// Lets decoding continue after suspend, also after one that timed out.
int caboose_gpu_runtime_resume(void);
// Stop revokes admission, signals upstream cleanup and shuts down its streams.
int caboose_gpu_runtime_stop(uint64_t token);
// Finish only after every run has returned. Waits up to 4 s for the process's queued
// cleanup (then prints CABOOSE_GPU_CLEANUP_CONTINUES and the teardown report, and the cleanup
// goes on by itself; what it cannot free yet is deferred, never holding other processes) and
// must run off UI/network threads; it does not finalize the backend. Callers must serialize
// finish for a token and admit a replacement only after this call succeeds. Presentation
// resources need their own retirement proof.
int caboose_gpu_runtime_finish(uint64_t token);
// Limits the device memory guests hold to `bytes` (0: no explicit limit); allocations past it
// fail (docs/gpu-live.md, "Memory budget"). The limits derived from the device always apply.
int caboose_gpu_runtime_set_memory_limit(uint64_t bytes);
// Prints, to standard error, every process's state and what the decoder's teardown is doing
// and has deferred, with every queue's pending waits (docs/gpu-live.md, "Teardown report").
void caboose_gpu_runtime_report_teardown(void);
#ifdef __cplusplus
}
#endif
