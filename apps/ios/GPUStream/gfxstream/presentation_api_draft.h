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
    CABOOSE_GPU_FAILED_UNRETIRED = 3, // explicit error; resources remain retained
    CABOOSE_GPU_PRESENT_RETIRED = 4 // indexed path: both fences and frame cleanup complete
} caboose_gpu_present_event;

// Callback runs off main/network queues. SOURCE_RELEASED or DEVICE_LOST ends a
// source use; FAILED_UNRETIRED is nonterminal. DEVICE_LOST may also follow
// SOURCE_RELEASED when loss is observed while waiting for presentation retirement.
// SOURCE_RELEASED says only that the native GPU is done reading the source; it is
// not display/vsync confirmation. For indexed presents, PRESENT_RETIRED is the
// final callback for that serial, after both real fences and frame cleanup; it is
// neither display/vsync completion nor acquisition. DEVICE_LOST does not imply
// PRESENT_RETIRED. Caller keeps context valid through surface retirement/detach.
// It must not synchronously wait for main work.
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
typedef struct caboose_gpu_query_status {
    int32_t native_error; // nonnegative errno; mirrors function return
    uint32_t has_vulkan_result; // 1 only for an actual provider result
    int32_t vulkan_result;
} caboose_gpu_query_status;
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
// Successful full queries have native_error=0 and the actual provider result
// VK_SUCCESS. A failed or incomplete provider query reports its actual result;
// local failures have has_vulkan_result=0 and vulkan_result=0.
int caboose_gpu_surface_query(caboose_gpu_surface* surface, uint64_t boxed_physical_device,
                              caboose_gpu_surface_capabilities** out, caboose_gpu_query_status* status);
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

// Presented-picture capture for the phone's own compositing (phone-owned scrolling).
// With a callback set, each present also copies its source into one of two device-local
// capture images when one is free, in the same submission. Once that copy's fence has
// actually signaled, the callback receives the present serial, a token and the image's
// MTLTexture (id<MTLTexture>, unretained; valid while retained by the receiver). The slot
// is not written again until release_capture(token). The callback runs on the frame
// worker: it must not call surface methods or wait for main work. A device that cannot
// export Metal objects presents without captures, and set_capture then returns ENOTSUP.
// A null callback (with a null context) stops captures; retire stops them as well.
typedef void (*caboose_gpu_capture_callback)(void* context, uint64_t present_serial, uint32_t token,
                                             void* metal_texture);
// Any thread. EBUSY after revocation.
int caboose_gpu_surface_set_capture(caboose_gpu_surface* surface, caboose_gpu_capture_callback callback,
                                    void* context);
// Any thread. ESTALE for a token already released or from a replaced ring.
int caboose_gpu_surface_release_capture(caboose_gpu_surface* surface, uint32_t token);
// Any thread, for diagnosis: 0 once the capture ring exists, EAGAIN before any present
// tried to make it, ENOTSUP when it could not be made (*vulkan_result is the provider's
// result, VK_ERROR_EXTENSION_NOT_PRESENT when Metal objects cannot be exported).
int caboose_gpu_surface_capture_state(caboose_gpu_surface* surface, int32_t* vulkan_result);

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
