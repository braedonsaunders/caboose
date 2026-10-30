// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include "presentation_types.h"
#include "presentation_api_draft.h"
#include <stdint.h>

// Experimental indexed WSI API, disabled by default. The private iOS target
// compiles and links this interface; real provider execution is unverified.
// Acquired-unused retirement and old-swapchain replacement are unsupported.
#ifdef __cplusplus
extern "C" {
#endif

typedef struct caboose_gpu_virtual_swapchain caboose_gpu_virtual_swapchain;
typedef struct caboose_gpu_acquire_request caboose_gpu_acquire_request;

// Actual provider query projected to the subset that CREATE accepts. The
// separate surface_query API remains the complete raw provider snapshot.
int caboose_gpu_surface_query_indexed(caboose_gpu_surface* surface, uint64_t boxed_physical_device,
    caboose_gpu_surface_capabilities** out, caboose_gpu_query_status* status);

// Per index, track acquisition (UNACQUIRED/ACQUIRED), source-copy fence and
// present-fence records independently: after a real queued present the index
// may be reacquired while earlier retirement records still exist. A new acquire
// must not overwrite those records. SOURCE_RELEASED follows its actual copy
// fence. Reuse requires both actual acquisition and source release; neither
// condition alone implies the other. Acquired-unused indices prevent retirement
// because completion of all guest GPU use is not established. Ambiguous operations
// are QUARANTINED. Retirement never turns a timeout into completion.
//
// Decoder semaphore and fence leases interlock destroy/reset with observation
// of the actual acquire signal. Semaphore-only acquire uses an internal fence;
// supplied-fence acquire observes that fence. Existing FenceInfo latestUse
// handling remains in effect. If completion or safe release cannot be proven,
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
    // is unsupported; a nonzero value is rejected.
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
    uint32_t local_reason;      // 0 none, 1 deadline, 2 cancelled, 3 other local failure
} caboose_gpu_acquire_result;
// A nonzero native_error together with has_image_index is an internal
// contradiction (such as an out-of-range or duplicate provider index). The
// caller must quarantine and terminate the session; it cannot encode that as
// a valid ACQUIRED reply or discard the actual acquired index.

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

// Begin leases the original synchronization objects and may create an internal
// fence; it does not acquire an image or signal the guest objects. Poll makes one real zero-timeout provider
// acquire, without holding the decoder global lock across it. NOT_READY has no
// index and no signal; success owns the actual returned index and provider's
// original semaphore/fence signal operation. A caller implements a monotonic
// deadline and paced polls; local deadline/cancellation is not a provider result.
// A guest-facing Vulkan timeout is VK_NOT_READY for a zero timeout or VK_TIMEOUT
// after an expired finite timeout, only after cancellation serializes with any
// in-flight poll and proves no successful acquire raced the deadline.
// Begin may return a nonzero integer when a real internal fence-creation call
// fails; status then has errno zero and the actual provider VkResult. Local
// failures have positive status errno and no provider result. Poll/cancel
// serialize with each other and native swapchain host operations.
// The owner serializes request release against all calls using that pointer.
int caboose_gpu_acquire_begin(caboose_gpu_virtual_swapchain* swapchain,
    const caboose_gpu_acquire_info* info, caboose_gpu_acquire_request** out,
    caboose_gpu_query_status* status);
caboose_gpu_acquire_result caboose_gpu_acquire_poll(caboose_gpu_acquire_request* request);
// Cancel succeeds only before provider acquisition; a successful acquisition
// racing cancellation remains owned and must be presented or safely released.
int caboose_gpu_acquire_cancel(caboose_gpu_acquire_request* request);
// An independent worker must pace this real zero-timeout fence observation
// after successful acquire, even after returning the index to the guest. It
// releases acquire-sync leases only after actual completion or device loss.
caboose_gpu_query_status caboose_gpu_acquire_observe(caboose_gpu_acquire_request* request);
// Returns EBUSY and retains the request while acquisition signal is pending.
int caboose_gpu_acquire_request_release(caboose_gpu_acquire_request** request);

// Must name the mapped index currently acquired for this generation and the
// actual boxed queue/family selected by the application; validate and lease
// both on the same device. Exactly one
// consumption of the original present wait set; queued, source-release and
// present-retirement are distinct. Callback context is kept until retirement.
caboose_gpu_submit_result caboose_gpu_virtual_swapchain_present(
    caboose_gpu_virtual_swapchain* swapchain, const caboose_gpu_mapped_present_info* info,
    caboose_gpu_present_callback callback, void* context);

// Worker only: revoke admission, drain acquire and submission users and retire
// real present fences. An acquired-unused index currently returns EBUSY and
// keeps resources retained because its guest GPU use is not proven complete.
// Failure leaves swapchain/surface/leases quarantined; never queue-idle-as-proof.
// Main detach follows successful retirement before runtime_finish.
// Success consumes *swapchain; failure leaves it retained and revoked.
int caboose_gpu_virtual_swapchain_retire(caboose_gpu_virtual_swapchain** swapchain,
                                         caboose_gpu_query_status* status);
#ifdef __cplusplus
}
#endif
