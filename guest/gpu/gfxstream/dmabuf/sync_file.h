// SPDX-License-Identifier: MIT
//
// Sync files for phone GPU work (docs/gpu-buffers.md). A sync file exported from a Vulkan
// fence or semaphore must signal when the phone finishes the work, not when the guest
// queued it. Each one carries a vgem fence: create() attaches a new fence to a one-page
// vgem object and exports the object's write fences as a sync file; signal() signals the
// fence once the driver has observed the phone's completion. vgem signals a fence that is
// never signalled after ten seconds, so a lost completion cannot hang a consumer forever.
#pragma once

#if defined(__linux__)

#include <cerrno>
#include <cstdint>
#include <linux/dma-buf.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <drm/drm.h>
#include <drm/drm_mode.h>

#include "dmabuf.h"

#ifndef DRM_IOCTL_VGEM_FENCE_ATTACH
struct drm_vgem_fence_attach {
    __u32 handle;
    __u32 flags;
    __u32 out_fence;
    __u32 pad;
};
struct drm_vgem_fence_signal {
    __u32 fence;
    __u32 flags;
};
#define VGEM_FENCE_WRITE 0x1
#define DRM_IOCTL_VGEM_FENCE_ATTACH DRM_IOWR(DRM_COMMAND_BASE + 0x1, struct drm_vgem_fence_attach)
#define DRM_IOCTL_VGEM_FENCE_SIGNAL DRM_IOW(DRM_COMMAND_BASE + 0x2, struct drm_vgem_fence_signal)
#endif

namespace caboose::dmabuf {

// A new unsignaled sync file and the token that signals it, or -1 (errno set).
inline int createSyncFile(uint32_t* token) {
    const int card = detail::vgemCard();
    if (card < 0) {
        errno = ENODEV;
        return -1;
    }
    // vgem refuses a write fence on an object with an unsignaled one: one object each.
    drm_mode_create_dumb create{};
    create.width = 4096;
    create.height = 1;
    create.bpp = 8;
    if (detail::ioctlRetry(card, DRM_IOCTL_MODE_CREATE_DUMB, &create) != 0) return -1;
    int result = -1;
    drm_vgem_fence_attach attach{};
    attach.handle = create.handle;
    attach.flags = VGEM_FENCE_WRITE;
    drm_prime_handle prime{};
    prime.handle = create.handle;
    prime.flags = DRM_CLOEXEC;
    if (detail::ioctlRetry(card, DRM_IOCTL_VGEM_FENCE_ATTACH, &attach) == 0 &&
        detail::ioctlRetry(card, DRM_IOCTL_PRIME_HANDLE_TO_FD, &prime) == 0) {
        dma_buf_export_sync_file exported{};
        exported.flags = DMA_BUF_SYNC_READ;  // What a reader waits for: the write fence.
        if (detail::ioctlRetry(prime.fd, DMA_BUF_IOCTL_EXPORT_SYNC_FILE, &exported) == 0) {
            result = exported.fd;
            *token = attach.out_fence;
        } else {
            // Never leave an unexported fence pending until its timeout.
            drm_vgem_fence_signal signal{};
            signal.fence = attach.out_fence;
            detail::ioctlRetry(card, DRM_IOCTL_VGEM_FENCE_SIGNAL, &signal);
        }
        close(prime.fd);
    }
    const int saved = errno;
    drm_gem_close gemClose{};
    gemClose.handle = create.handle;
    detail::ioctlRetry(card, DRM_IOCTL_GEM_CLOSE, &gemClose);
    errno = saved;
    return result;
}

inline void signalSyncFile(uint32_t token) {
    const int card = detail::vgemCard();
    if (card < 0) return;
    drm_vgem_fence_signal signal{};
    signal.fence = token;
    detail::ioctlRetry(card, DRM_IOCTL_VGEM_FENCE_SIGNAL, &signal);
}

}  // namespace caboose::dmabuf

#endif  // __linux__
