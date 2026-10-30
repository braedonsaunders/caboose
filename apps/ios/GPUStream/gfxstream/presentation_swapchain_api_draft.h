// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include "presentation_types.h"
#include "presentation_api_draft.h"
#include <stdint.h>

// DESIGN ONLY: this API is not implemented, exported, or wired to the guest.
// It replaces the acquire-at-present behavior only after the implementation,
// lifetime interlocks, and same-provider device regressions have passed.
#ifdef __cplusplus
extern "C" {
#endif

typedef struct caboose_gpu_virtual_swapchain caboose_gpu_virtual_swapchain;
typedef struct caboose_gpu_acquire_request caboose_gpu_acquire_request;

// Per index, track acquisition (UNACQUIRED/ACQUIRED), source-copy fence and
// present-fence records independently: after a real queued present the index
// may be reacquired while earlier retirement records still exist. A new acquire
// must not overwrite those records. SOURCE_RELEASED follows its actual copy
// fence. Reuse requires both actual acquisition and source release; neither
// condition alone implies the other. An acquired unused index becomes unacquired only after real maintenance1
// release succeeds and all relevant use has completed. Ambiguous operations
// are QUARANTINED. Retirement never turns a timeout into completion.
//
// The current decoder has a semaphore destruction lease, but FenceInfo has no
// equivalent gate. A real implementation must add same-device/boxed fence
// validation and interlock destroy/reset with the actual acquire signal before
// admitting this API. The semaphore's signal completion also needs tracking:
// when the guest passes only a semaphore, an internal fence can accompany it;
// when the guest supplies a fence, its reset/destroy must be serialized with
// observing actual completion. Existing FenceInfo latestUse handling must be
// integrated, not bypassed. If completion or safe release cannot be proven,
// keep all objects quarantined; no queue-idle shortcut or success receipt.

typedef struct caboose_gpu_swapchain_create_info {
    caboose_gpu_surface_identity identity;
    uint64_t boxed_device;
    uint32_t create_flags, min_image_count, vk_format, color_space, width, height;
    uint32_t image_array_layers, image_usage, pre_transform, composite_alpha;
    uint32_t present_mode, clipped, sharing_mode;
    uint32_t queue_family_count, has_unsupported_extensions;
    const uint32_t* queue_families;
    // Existing authenticated virtual swapchain identity, or zero. Replacement
    // is unsupported until actual old-swapchain retirement is implemented.
    uint64_t old_swapchain_id;
} caboose_gpu_swapchain_create_info;

typedef struct caboose_gpu_acquire_info {
    // Validity of the binary semaphore and fence follows Vulkan acquire VUIDs.
    // At least one must be supplied; both must belong to the selected device.
    uint64_t boxed_binary_semaphore, boxed_fence;
    uint32_t device_mask; // initially exactly 1, no device group/pNext support
} caboose_gpu_acquire_info;

typedef struct caboose_gpu_acquire_result {
    int32_t native_error;       // nonnegative; cancellation is a local result
    uint32_t has_vulkan_result; // actual provider result only
    int32_t vulkan_result;
    uint32_t has_image_index;   // only actual VK_SUCCESS or VK_SUBOPTIMAL_KHR
    uint32_t image_index;
} caboose_gpu_acquire_result;

typedef struct caboose_gpu_mapped_present_info {
    caboose_gpu_surface_identity identity;
    uint64_t present_serial;
    uint64_t boxed_queue;
    uint32_t queue_family;
    uint32_t image_index;
    uint32_t vk_image_layout; // GENERAL after the private WSI remapping
    uint32_t wait_semaphore_count;
    const uint64_t* boxed_wait_semaphores;
} caboose_gpu_mapped_present_info;

// Worker only after attached surface and actual pre-device capabilities query.
// On success returns the provider's full real image count and owns the actual
// swapchain until retirement. The provider must honor every accepted creation
// field, including the requested minimum image count, and return a count at
// least that minimum and no greater than a nonzero provider maximum. Unsupported
// flags, pNext, replacement or other combinations must be explicitly rejected;
// never silently select another mode, format, alpha or transform. Queue choice
// is deferred until PRESENT. Zero/oversized/incompatible counts fail closed.
// Also returns a nonzero surface-local monotonic swapchain ID which is never
// reused within this surface generation. All objects stay leased; success does
// not mean that sources are mapped.
int caboose_gpu_virtual_swapchain_create(caboose_gpu_surface* surface,
    const caboose_gpu_swapchain_create_info* info, caboose_gpu_virtual_swapchain** out,
    uint64_t* swapchain_id, uint32_t* actual_image_count, caboose_gpu_query_status* status);

// Exactly actual_image_count distinct same-device decoder-owned images, ordered
// by native image index. Each image, memory binding and supported shape/usage is
// validated and leased atomically. Neither partial mapping nor handle guessing.
int caboose_gpu_virtual_swapchain_map(caboose_gpu_virtual_swapchain* swapchain,
    const uint64_t* boxed_images, uint32_t image_count);

// Begin leases the original synchronization objects before admission; does not
// signal them or call the provider. Poll makes one real zero-timeout provider
// acquire, without holding the decoder global lock across it. NOT_READY has no
// index and no signal; success owns the actual returned index and provider's
// original semaphore/fence signal operation. A caller implements a monotonic
// deadline and paced polls; local deadline/cancellation is not a provider result.
// A guest-facing Vulkan timeout is VK_NOT_READY for a zero timeout or VK_TIMEOUT
// after an expired finite timeout, only after cancellation serializes with any
// in-flight poll and proves no successful acquire raced the deadline.
// Poll/cancel serialize with each other and native swapchain host operations.
int caboose_gpu_acquire_begin(caboose_gpu_virtual_swapchain* swapchain,
    const caboose_gpu_acquire_info* info, caboose_gpu_acquire_request** out);
caboose_gpu_acquire_result caboose_gpu_acquire_poll(caboose_gpu_acquire_request* request);
// Cancel succeeds only before provider acquisition; a successful acquisition
// racing cancellation remains owned and must be presented or safely released.
int caboose_gpu_acquire_cancel(caboose_gpu_acquire_request* request);
// Release request only after cancellation or after a successful result has been
// observed; underlying in-flight signal lifetimes are retained independently.
void caboose_gpu_acquire_request_release(caboose_gpu_acquire_request* request);

// Must name the mapped index currently acquired for this generation and the
// actual boxed queue/family selected by the application; validate and lease
// both on the same device. Exactly one
// consumption of the original present wait set; queued, source-release and
// present-retirement are distinct. Callback context is kept until retirement.
caboose_gpu_submit_result caboose_gpu_virtual_swapchain_present(
    caboose_gpu_virtual_swapchain* swapchain, const caboose_gpu_mapped_present_info* info,
    caboose_gpu_present_callback callback, void* context);

// Worker only: revoke admission, drain acquire and submission users, wait actual
// completion, release each unused acquired index only via enabled real
// swapchain-maintenance1 after it is no longer in use, and retire present fences.
// Failure leaves swapchain/surface/leases quarantined; never queue-idle-as-proof.
// Main detach follows successful retirement before runtime_finish.
int caboose_gpu_virtual_swapchain_retire(caboose_gpu_virtual_swapchain* swapchain);
#ifdef __cplusplus
}
#endif
