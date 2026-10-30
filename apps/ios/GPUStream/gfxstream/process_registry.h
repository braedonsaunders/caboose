// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct caboose_gfx_registry caboose_gfx_registry;
// Requires an initialized upstream FrameBuffer. Only one registry may exist.
// All functions return zero on success or an errno-style error.
int caboose_gfx_registry_create(caboose_gfx_registry** out);
int caboose_gfx_registry_destroy(caboose_gfx_registry* registry);
// External PUID is an opaque broker identity, never truncated to the upstream ID.
int caboose_gfx_process_open(caboose_gfx_registry* registry, uint64_t puid);
// Blocks on the calling thread. The caller owns fd and keeps it open until return.
// All connections of a process share the real upstream ProcessResources.
int caboose_gfx_process_run(caboose_gfx_registry* registry, uint64_t puid, int fd,
                            size_t max_packet, size_t max_reply_buffer);
// Revokes admission, marks guest dead and shuts down all active sockets.
int caboose_gfx_process_stop(caboose_gfx_registry* registry, uint64_t puid);
// After every run returns, remove the entry; upstream cleanup remains asynchronous.
// Destroy waits for all pending cleanups; callers must serialize destroy against calls.
// Returns EBUSY instead of waiting for active decoder threads.
int caboose_gfx_process_finish(caboose_gfx_registry* registry, uint64_t puid);
#ifdef __cplusplus
}
#endif
