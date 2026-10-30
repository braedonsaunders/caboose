// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <stdint.h>
#include <vulkan/vulkan.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct caboose_gpu_diagnostic caboose_gpu_diagnostic;
typedef void* (*caboose_gpu_resolve_export)(const char* name);
// Diagnostic only. The caller must explicitly authorize invocation and bind
// every connection to this process/session/generation before passing its fd.
// Loader callbacks must use the same process-owned MoltenVK provider as query,
// provide real exported trampolines, and remain valid for the process lifetime.
// All errors are errno-style. Only one backend lifetime is supported per process.
int caboose_gpu_diagnostic_start(const uint8_t session_id[16], uint64_t generation,
                                  uint64_t process_id, PFN_vkGetInstanceProcAddr get,
                                  caboose_gpu_resolve_export resolve,
                                  caboose_gpu_diagnostic** out);
// Return the actual locally bound identity. The caller serializes this against finish.
int caboose_gpu_diagnostic_identity(const caboose_gpu_diagnostic* diagnostic,
                                    uint8_t session_id[16], uint64_t* generation,
                                    uint64_t* process_id);
// Blocking; caller retains fd until return. One call per guest encoder thread.
// hello_timeout_ms bounds the diagnostic handshake, not Vulkan execution.
int caboose_gpu_diagnostic_run(caboose_gpu_diagnostic* diagnostic, int fd,
                                uint32_t hello_timeout_ms);
// Revokes admission, signals process death and shuts down all active streams.
int caboose_gpu_diagnostic_stop(caboose_gpu_diagnostic* diagnostic);
// Caller must serialize finish against all other calls and call it only after all
// run calls have returned. May block waiting for real upstream
// asynchronous cleanup; use an external watchdog. Returns EBUSY if calls remain.
int caboose_gpu_diagnostic_finish(caboose_gpu_diagnostic* diagnostic);
#ifdef __cplusplus
}
#endif
