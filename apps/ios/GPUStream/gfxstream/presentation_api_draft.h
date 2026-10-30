// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include "presentation_types.h"
#include <stdint.h>

// Experimental private interface: implementation is not yet validated for
// production activation. Calls on the same surface must be externally ordered;
// callbacks must not call surface methods synchronously or wait for main work.
// A callback can run before surface_present returns. Caller must keep the
// surface alive and externally serialize all calls, including main detach.
#ifdef __cplusplus
extern "C" {
#endif

typedef struct caboose_gpu_surface caboose_gpu_surface;

typedef enum caboose_gpu_submit_disposition {
    CABOOSE_GPU_SUBMIT_REJECTED = 0, // no native queue submission; safe to reject
    CABOOSE_GPU_SUBMIT_QUEUED = 1,   // real queue submission accepted, not completion
    CABOOSE_GPU_SUBMIT_UNCERTAIN = 2 // submission/consumption uncertain; do not retry waits
} caboose_gpu_submit_disposition;

typedef struct caboose_gpu_submit_result {
    caboose_gpu_submit_disposition disposition;
    int32_t native_error; // errno-style; zero only on accepted operation
    uint32_t has_vulkan_result; // 1 only when vulkan_result is a real driver result
    int32_t vulkan_result;
} caboose_gpu_submit_result;

typedef enum caboose_gpu_present_event {
    CABOOSE_GPU_SOURCE_RELEASED = 1, // real GPU completion; source may be reacquired
    CABOOSE_GPU_DEVICE_LOST = 2,     // actual terminal device loss; do not reuse objects
    CABOOSE_GPU_FAILED_UNRETIRED = 3 // explicit error; source still not releasable
} caboose_gpu_present_event;

// Callback runs off main/network queues. SOURCE_RELEASED or DEVICE_LOST ends a
// serial; FAILED_UNRETIRED is nonterminal and may be followed by a terminal event.
// SOURCE_RELEASED says only that the native GPU is done reading the source; it is
// not display/vsync confirmation. Caller keeps context valid until terminal event
// and successful worker retirement. It must not synchronously wait for main work.
typedef void (*caboose_gpu_present_callback)(void* context, uint64_t present_serial,
    caboose_gpu_present_event event, caboose_gpu_submit_result result);

// Worker only; reserves window/generation and validates process/instance ownership.
// Root must first match the identity against the authenticated owner-window map.
// On success caller owns *out until successful main detach; on failure *out=NULL.
int caboose_gpu_surface_prepare(const caboose_gpu_surface_bind_info* bind,
                                caboose_gpu_surface** out);

// Worker only, after main attach and before guest swapchain creation. Validates
// boxed physical device ownership against this surface's decoder instance.
// The complete bounded provider query is made available through the result;
// all lists are immutable until caller releases this snapshot. Actual provider
// properties and the product's supported subset must be kept distinct.
typedef struct caboose_gpu_surface_capabilities caboose_gpu_surface_capabilities;
typedef struct caboose_gpu_surface_format {
    uint32_t format, color_space;
    uint32_t linear_features, optimal_features, buffer_features;
    uint32_t properties_queried; // zero for VK_FORMAT_UNDEFINED
} caboose_gpu_surface_format;
typedef struct caboose_gpu_surface_queue_family {
    uint32_t queue_flags, queue_count, present_supported;
} caboose_gpu_surface_queue_family;
typedef struct caboose_gpu_candidate_format {
    uint32_t format, linear_features, optimal_features, buffer_features;
} caboose_gpu_candidate_format;
typedef struct caboose_gpu_surface_capabilities_view {
    uint32_t min_image_count, max_image_count;
    uint32_t current_width, current_height, min_width, min_height, max_width, max_height;
    uint32_t max_image_array_layers, supported_transforms, current_transform;
    uint32_t supported_composite_alpha, supported_usage_flags;
    uint32_t format_count, candidate_format_count, present_mode_count, queue_family_count;
    const caboose_gpu_surface_format* formats;
    const caboose_gpu_candidate_format* candidate_formats;
    const uint32_t* present_modes;
    const caboose_gpu_surface_queue_family* queue_families;
} caboose_gpu_surface_capabilities_view;
int caboose_gpu_surface_query(caboose_gpu_surface* surface, uint64_t boxed_physical_device,
                              caboose_gpu_surface_capabilities** out);
// Pointers in this view remain valid until capabilities_release; no partial
// view is returned on provider error or an oversized result.
const caboose_gpu_surface_capabilities_view* caboose_gpu_surface_capabilities_get(
    const caboose_gpu_surface_capabilities* capabilities);
void caboose_gpu_surface_capabilities_release(caboose_gpu_surface_capabilities* capabilities);

// Worker only; consumes request and its semaphore array before return. Reject stale
// generation, unsupported format/layout/ownership, duplicate serial and invalid
// waits before queueing; a submitted-but-uncertain outcome is never retried. On
// accepted or uncertain submission the surface owns resources until retirement;
// uncertain failures can remain quarantined indefinitely. If worker creation
// fails, retirement attempts the fence waits and delivers any callback itself.
caboose_gpu_submit_result caboose_gpu_surface_present(caboose_gpu_surface* surface,
    const caboose_gpu_present_info* present, caboose_gpu_present_callback callback, void* context);

// Worker only; revokes admission and blocks until all GPU source reads and
// presentation resources are retired, or actual terminal device loss. It never
// waits under the decoder global mutex. A failure/unknown outcome keeps the
// reservation and layer: do not admit a replacement or report release.
int caboose_gpu_surface_retire(caboose_gpu_surface* surface);

#ifdef __cplusplus
}
#endif

#ifdef __OBJC__
@class CAMetalLayer;
#ifdef __cplusplus
extern "C" {
#endif
// Main thread only; the layer is supplied by the trusted owner-view registry,
// retained and configured on main. No guest-supplied pointer is accepted.
// On success the surface retains the layer until successful main detach.
int caboose_gpu_surface_attach(caboose_gpu_surface* surface, CAMetalLayer* trustedLayer);
// Main thread only after worker retirement succeeds. Destroys the real native
// surface/KVO, releases layer and instance lease, removes reservation, and
// consumes the surface pointer. Failure retains ownership for explicit handling.
int caboose_gpu_surface_detach(caboose_gpu_surface** surface);
#ifdef __cplusplus
}
#endif
#endif
