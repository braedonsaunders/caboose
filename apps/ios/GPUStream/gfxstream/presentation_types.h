// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <stdint.h>

// In-process types, not a wire format. Vulkan values are existing gfxstream
// boxed host-facing handles; they are never native pointers supplied by a guest.
#define CABOOSE_GPU_PRESENT_MAX_WAIT_SEMAPHORES 64u

typedef struct caboose_gpu_surface_identity {
    uint64_t process_token;
    uint8_t compositor_epoch[16];
    uint64_t window_id;
    uint64_t generation;
    uint8_t grant[16];
} caboose_gpu_surface_identity;

typedef struct caboose_gpu_surface_bind_info {
    caboose_gpu_surface_identity identity;
    uint64_t boxed_instance;
    uint32_t width;
    uint32_t height;
} caboose_gpu_surface_bind_info;

typedef struct caboose_gpu_present_info {
    caboose_gpu_surface_identity identity;
    uint64_t present_serial;
    uint64_t boxed_device;
    uint64_t boxed_queue;
    uint64_t boxed_image;
    uint32_t vk_format;
    uint32_t width;
    uint32_t height;
    uint32_t vk_image_layout;
    uint32_t queue_family;
    uint32_t wait_semaphore_count;
    // Caller owns this array. An asynchronous consumer must copy it before
    // returning; semaphore handles must refer to distinct binary semaphores.
    const uint64_t* boxed_wait_semaphores;
} caboose_gpu_present_info;
