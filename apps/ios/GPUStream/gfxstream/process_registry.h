// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef CABOOSE_GPU_MEMORY_AUDIT
#include "memory_audit.h"
#endif
#ifdef __cplusplus
extern "C" {
#endif

typedef struct caboose_gfx_registry caboose_gfx_registry;
#ifdef CABOOSE_GPU_MEMORY_AUDIT
int caboose_gfx_process_memory_receipts(caboose_gfx_registry* registry, uint64_t token,
    caboose_gpu_memory_receipt* out, size_t capacity, size_t* count);
#endif
// Requires an initialized upstream FrameBuffer. Only one registry may exist.
// All functions return zero on success or an errno-style error.
int caboose_gfx_registry_create(caboose_gfx_registry** out);
// Private v4 profile: deny asynchronous and deferred GPU opcodes before decode.
int caboose_gfx_registry_create_synchronous(caboose_gfx_registry** out);
int caboose_gfx_registry_destroy(caboose_gfx_registry* registry);
// External PUID is an opaque broker identity, never truncated to the upstream ID.
int caboose_gfx_process_open(caboose_gfx_registry* registry, uint64_t puid);
// Blocks on the calling thread. The caller owns fd and keeps it open until return.
// Orderly input EOF at a complete command boundary succeeds after replies are
// flushed. Truncated input or a socket error returns a nonzero errno.
// All connections of a process share the real upstream ProcessResources.
int caboose_gfx_process_run(caboose_gfx_registry* registry, uint64_t puid, int fd,
                            size_t max_packet, size_t max_reply_buffer);
#ifdef CABOOSE_GPU_DECODER_TESTING
// Test instrumentation counts actual generated decoder entries on this thread.
int caboose_gfx_process_run_counted(caboose_gfx_registry* registry, uint64_t puid, int fd,
                                    size_t max_packet, size_t max_reply_buffer, uint64_t* entries);
#endif
// Blocks until the process's device stream has decoded its ORDER mark `serial`
// (completion_feed.h); ECANCELED once the process stops. Never waits for the GPU.
int caboose_gfx_process_wait_order(caboose_gfx_registry* registry, uint64_t puid, uint64_t serial);
// Revokes admission, marks guest dead and shuts down all active sockets.
int caboose_gfx_process_stop(caboose_gfx_registry* registry, uint64_t puid);
// After every run returns, remove the entry; upstream cleanup remains asynchronous.
// Destroy waits for all pending cleanups; callers must serialize destroy against calls.
// Returns EBUSY instead of waiting for active decoder threads.
int caboose_gfx_process_finish(caboose_gfx_registry* registry, uint64_t puid);
#ifdef __cplusplus
}
#endif
