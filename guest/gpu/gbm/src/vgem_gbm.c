// SPDX-License-Identifier: MIT
//
// vgem_gbm.so: the GBM backend for the Caboose render node (docs/gpu-buffers.md).
//
// The computer's render node is the kernel's vgem device. Mesa's GBM loader opens
// <driver>_gbm.so for a device's DRM driver name, so every GBM user (Chromium, Mesa's
// EGL, compositors, VA-API) that opens the render node gets this backend with no
// configuration. Buffers are vgem GEM objects exported as dma-bufs: a LINEAR buffer is
// ordinary shared memory; a CABOOSE_FORMAT_MOD_REMOTE buffer only names phone GPU
// memory, which the Caboose Vulkan driver attaches on first import. Its pages are never
// touched, so it costs no guest memory.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <drm.h>
#include <drm_mode.h>
#include <linux/dma-buf.h>
#include <xf86drm.h>

#include "caboose_drm_formats.h"
#include "gbm_backend_abi.h"

#define EXPORT __attribute__((visibility("default")))

struct handle_ref {
    uint32_t handle;
    unsigned count;
};

struct caboose_device {
    struct gbm_device base;
    int card;  // The primary node: vgem creates objects only there.
    // A descriptor has one GEM handle per object, so buffer objects that share an
    // object share its handle; it is closed with the last of them.
    pthread_mutex_t handles_lock;
    struct handle_ref *handles;
    unsigned handle_count, handle_capacity;
};

struct caboose_bo {
    struct gbm_bo base;
    const struct caboose_format *format;
    int dmabuf;
    uint64_t modifier;
    uint64_t size;
    uint32_t strides[3];
    uint32_t offsets[3];
    pthread_mutex_t map_lock;
    void *map;
    unsigned map_count;
};

static const struct gbm_core *core;

static struct caboose_device *device_of(struct gbm_device *gbm) { return (struct caboose_device *)gbm; }
static struct caboose_bo *bo_of(struct gbm_bo *bo) { return (struct caboose_bo *)bo; }

static uint32_t canonical(uint32_t format) {
    return core && core->v0.format_canonicalize ? core->v0.format_canonicalize(format) : format;
}

static int xioctl(int fd, unsigned long request, void *arg) {
    int ret;
    do ret = ioctl(fd, request, arg);
    while (ret == -1 && (errno == EINTR || errno == EAGAIN));
    return ret;
}

static void gem_close(int fd, uint32_t handle) {
    struct drm_gem_close close_args = {.handle = handle};
    if (handle) xioctl(fd, DRM_IOCTL_GEM_CLOSE, &close_args);
}

// Takes a reference on the caller's descriptor's handle for a dma-buf.
static int handle_acquire(struct caboose_device *dev, int dmabuf, uint32_t *out) {
    pthread_mutex_lock(&dev->handles_lock);
    struct drm_prime_handle prime = {.fd = dmabuf};
    int ret = xioctl(dev->base.v0.fd, DRM_IOCTL_PRIME_FD_TO_HANDLE, &prime);
    if (!ret) {
        unsigned i = 0;
        while (i < dev->handle_count && dev->handles[i].handle != prime.handle) ++i;
        if (i == dev->handle_count) {
            if (dev->handle_count == dev->handle_capacity) {
                const unsigned capacity = dev->handle_capacity ? dev->handle_capacity * 2 : 16;
                struct handle_ref *grown = realloc(dev->handles, capacity * sizeof(*grown));
                if (!grown) {
                    gem_close(dev->base.v0.fd, prime.handle);
                    pthread_mutex_unlock(&dev->handles_lock);
                    errno = ENOMEM;
                    return -1;
                }
                dev->handles = grown;
                dev->handle_capacity = capacity;
            }
            dev->handles[dev->handle_count++] = (struct handle_ref){prime.handle, 0};
        }
        ++dev->handles[i].count;
        *out = prime.handle;
    }
    pthread_mutex_unlock(&dev->handles_lock);
    return ret;
}

static void handle_release(struct caboose_device *dev, uint32_t handle) {
    if (!handle) return;
    pthread_mutex_lock(&dev->handles_lock);
    for (unsigned i = 0; i < dev->handle_count; ++i) {
        if (dev->handles[i].handle != handle) continue;
        if (--dev->handles[i].count == 0) {
            gem_close(dev->base.v0.fd, handle);
            dev->handles[i] = dev->handles[--dev->handle_count];
        }
        break;
    }
    pthread_mutex_unlock(&dev->handles_lock);
}

static bool modifier_known(uint64_t modifier) {
    return modifier == DRM_FORMAT_MOD_LINEAR || modifier == CABOOSE_FORMAT_MOD_REMOTE;
}

static int is_format_supported(struct gbm_device *gbm, uint32_t format, uint32_t usage) {
    (void)gbm;
    (void)usage;
    return caboose_format_find(canonical(format)) != NULL;
}

static int get_format_modifier_plane_count(struct gbm_device *gbm, uint32_t format, uint64_t modifier) {
    (void)gbm;
    const struct caboose_format *f = caboose_format_find(canonical(format));
    if (!f || !modifier_known(modifier)) return -1;
    return f->planes;
}

// Implicit layouts (no modifier list) are LINEAR: such a caller may map the buffer or
// pass it on without a modifier. REMOTE is chosen only when the caller offers it and
// does not ask for CPU-visible layout.
static int choose_modifier(uint32_t usage, const uint64_t *modifiers, unsigned count, uint64_t *out) {
    bool linear = count == 0, remote = false;
    for (unsigned i = 0; i < count; ++i) {
        if (modifiers[i] == DRM_FORMAT_MOD_LINEAR) linear = true;
        if (modifiers[i] == CABOOSE_FORMAT_MOD_REMOTE) remote = true;
    }
    if (remote && !(usage & (GBM_BO_USE_LINEAR | GBM_BO_USE_WRITE | GBM_BO_USE_CURSOR))) {
        *out = CABOOSE_FORMAT_MOD_REMOTE;
        return 0;
    }
    if (linear) {
        *out = DRM_FORMAT_MOD_LINEAR;
        return 0;
    }
    return -1;
}

static struct caboose_bo *bo_new(struct gbm_device *gbm, uint32_t width, uint32_t height, uint32_t format,
                                 const struct caboose_format *f) {
    struct caboose_bo *bo = calloc(1, sizeof(*bo));
    if (!bo) return NULL;
    bo->base.gbm = gbm;
    bo->base.v0.width = width;
    bo->base.v0.height = height;
    bo->base.v0.format = format;
    bo->format = f;
    bo->dmabuf = -1;
    pthread_mutex_init(&bo->map_lock, NULL);
    return bo;
}

static void bo_free(struct caboose_bo *bo) {
    if (bo->map) munmap(bo->map, bo->size);
    handle_release(device_of(bo->base.gbm), bo->base.v0.handle.u32);
    if (bo->dmabuf >= 0) close(bo->dmabuf);
    pthread_mutex_destroy(&bo->map_lock);
    free(bo);
}

// The object's handle on the caller's device descriptor, for gbm_bo_get_handle.
static int attach_handle(struct caboose_bo *bo) {
    return handle_acquire(device_of(bo->base.gbm), bo->dmabuf, &bo->base.v0.handle.u32);
}

static struct gbm_bo *bo_create(struct gbm_device *gbm, uint32_t width, uint32_t height, uint32_t format,
                                uint32_t usage, const uint64_t *modifiers, const unsigned int count) {
    struct caboose_device *dev = device_of(gbm);
    format = canonical(format);
    const struct caboose_format *f = caboose_format_find(format);
    uint64_t modifier;
    if (!f || choose_modifier(usage, modifiers, count, &modifier)) {
        errno = EINVAL;
        return NULL;
    }
    struct caboose_bo *bo = bo_new(gbm, width, height, format, f);
    if (!bo) return NULL;
    bo->modifier = modifier;
    bo->size = caboose_format_layout(f, width, height, bo->strides, bo->offsets);
    // vgem sizes a dumb object as pitch × height: ask for 4096-byte rows.
    const uint64_t rows = (bo->size + 4095) / 4096;
    if (!bo->size || rows > UINT32_MAX) {
        bo_free(bo);
        errno = EINVAL;
        return NULL;
    }
    struct drm_mode_create_dumb create = {.width = 4096, .height = (uint32_t)rows, .bpp = 8};
    if (xioctl(dev->card, DRM_IOCTL_MODE_CREATE_DUMB, &create)) {
        bo_free(bo);
        return NULL;
    }
    struct drm_prime_handle prime = {.handle = create.handle, .flags = DRM_CLOEXEC | DRM_RDWR};
    const int exported = xioctl(dev->card, DRM_IOCTL_PRIME_HANDLE_TO_FD, &prime);
    const int saved = errno;
    gem_close(dev->card, create.handle);  // The dma-buf keeps the object alive.
    if (exported) {
        bo_free(bo);
        errno = saved;
        return NULL;
    }
    bo->dmabuf = prime.fd;
    if (attach_handle(bo)) {
        bo_free(bo);
        return NULL;
    }
    bo->base.v0.stride = bo->strides[0];
    return &bo->base;
}

static struct gbm_bo *bo_import(struct gbm_device *gbm, uint32_t type, void *buffer, uint32_t usage) {
    (void)usage;
    struct gbm_import_fd_modifier_data data;
    if (type == GBM_BO_IMPORT_FD) {
        const struct gbm_import_fd_data *in = buffer;
        memset(&data, 0, sizeof(data));
        data.width = in->width;
        data.height = in->height;
        data.format = in->format;
        data.num_fds = 1;
        data.fds[0] = in->fd;
        data.strides[0] = (int)in->stride;
        data.modifier = DRM_FORMAT_MOD_LINEAR;
    } else if (type == GBM_BO_IMPORT_FD_MODIFIER) {
        data = *(const struct gbm_import_fd_modifier_data *)buffer;
        if (data.modifier == DRM_FORMAT_MOD_INVALID) data.modifier = DRM_FORMAT_MOD_LINEAR;
    } else {
        errno = ENOSYS;  // wl_buffer and EGLImage imports need a GL driver.
        return NULL;
    }
    const uint32_t format = canonical(data.format);
    const struct caboose_format *f = caboose_format_find(format);
    // One descriptor (possibly repeated) per plane, all naming the same buffer.
    if (!f || !modifier_known(data.modifier) || data.num_fds != f->planes || !data.width || !data.height) {
        errno = EINVAL;
        return NULL;
    }
    struct stat first, other;
    if (fstat(data.fds[0], &first)) return NULL;
    for (unsigned p = 1; p < data.num_fds; ++p) {
        if (fstat(data.fds[p], &other)) return NULL;
        if (other.st_ino != first.st_ino || other.st_dev != first.st_dev) {
            errno = ENOTSUP;
            return NULL;
        }
    }
    const off_t end = lseek(data.fds[0], 0, SEEK_END);
    if (end <= 0) {
        errno = EINVAL;
        return NULL;
    }
    struct caboose_bo *bo = bo_new(gbm, data.width, data.height, format, f);
    if (!bo) return NULL;
    bo->modifier = data.modifier;
    bo->size = (uint64_t)end;
    for (unsigned p = 0; p < f->planes; ++p) {
        const uint64_t w = ((uint64_t)data.width + (1u << f->xshift[p]) - 1) >> f->xshift[p];
        const uint64_t h = ((uint64_t)data.height + (1u << f->yshift[p]) - 1) >> f->yshift[p];
        if (data.strides[p] <= 0 || data.offsets[p] < 0 || (uint64_t)data.strides[p] < w * f->bytes[p] ||
            (uint64_t)data.offsets[p] + (uint64_t)data.strides[p] * h > bo->size) {
            bo_free(bo);
            errno = EINVAL;
            return NULL;
        }
        bo->strides[p] = (uint32_t)data.strides[p];
        bo->offsets[p] = (uint32_t)data.offsets[p];
    }
    bo->dmabuf = fcntl(data.fds[0], F_DUPFD_CLOEXEC, 0);
    if (bo->dmabuf < 0 || attach_handle(bo)) {
        bo_free(bo);
        return NULL;
    }
    bo->base.v0.stride = bo->strides[0];
    return &bo->base;
}

static void dmabuf_sync(int fd, uint64_t flags) {
    struct dma_buf_sync sync = {.flags = flags};
    xioctl(fd, DMA_BUF_IOCTL_SYNC, &sync);
}

static void *bo_map(struct gbm_bo *gbo, uint32_t x, uint32_t y, uint32_t width, uint32_t height, uint32_t flags,
                    uint32_t *stride, void **map_data) {
    struct caboose_bo *bo = bo_of(gbo);
    if (bo->modifier != DRM_FORMAT_MOD_LINEAR || (uint64_t)x + width > gbo->v0.width ||
        (uint64_t)y + height > gbo->v0.height) {
        errno = EINVAL;  // A REMOTE buffer's bytes are on the phone.
        return NULL;
    }
    pthread_mutex_lock(&bo->map_lock);
    if (!bo->map) {
        void *map = mmap(NULL, bo->size, PROT_READ | PROT_WRITE, MAP_SHARED, bo->dmabuf, 0);
        if (map == MAP_FAILED) {
            pthread_mutex_unlock(&bo->map_lock);
            return NULL;
        }
        bo->map = map;
    }
    ++bo->map_count;
    pthread_mutex_unlock(&bo->map_lock);
    uint64_t access = 0;
    if (flags & GBM_BO_TRANSFER_READ) access |= DMA_BUF_SYNC_READ;
    if (flags & GBM_BO_TRANSFER_WRITE) access |= DMA_BUF_SYNC_WRITE;
    if (!access) access = DMA_BUF_SYNC_RW;
    dmabuf_sync(bo->dmabuf, DMA_BUF_SYNC_START | access);
    *map_data = (void *)(uintptr_t)access;
    *stride = bo->strides[0];
    return (uint8_t *)bo->map + bo->offsets[0] + (uint64_t)y * bo->strides[0] + (uint64_t)x * bo->format->bytes[0];
}

static void bo_unmap(struct gbm_bo *gbo, void *map_data) {
    struct caboose_bo *bo = bo_of(gbo);
    dmabuf_sync(bo->dmabuf, DMA_BUF_SYNC_END | (uint64_t)(uintptr_t)map_data);
    pthread_mutex_lock(&bo->map_lock);
    if (bo->map_count) --bo->map_count;
    pthread_mutex_unlock(&bo->map_lock);
}

static int bo_write(struct gbm_bo *gbo, const void *buf, size_t count) {
    uint32_t stride;
    void *data;
    void *dst = bo_map(gbo, 0, 0, gbo->v0.width, gbo->v0.height, GBM_BO_TRANSFER_WRITE, &stride, &data);
    if (!dst) return -1;
    if (count > bo_of(gbo)->size - bo_of(gbo)->offsets[0]) count = bo_of(gbo)->size - bo_of(gbo)->offsets[0];
    memcpy(dst, buf, count);
    bo_unmap(gbo, data);
    return 0;
}

static int bo_get_fd(struct gbm_bo *gbo) { return fcntl(bo_of(gbo)->dmabuf, F_DUPFD_CLOEXEC, 0); }

static int bo_get_planes(struct gbm_bo *gbo) { return bo_of(gbo)->format->planes; }

static union gbm_bo_handle bo_get_handle(struct gbm_bo *gbo, int plane) {
    union gbm_bo_handle handle = {.s64 = -1};
    if (plane >= 0 && plane < bo_of(gbo)->format->planes) handle = gbo->v0.handle;
    return handle;
}

static int bo_get_plane_fd(struct gbm_bo *gbo, int plane) {
    if (plane < 0 || plane >= bo_of(gbo)->format->planes) {
        errno = EINVAL;
        return -1;
    }
    return bo_get_fd(gbo);
}

static uint32_t bo_get_stride(struct gbm_bo *gbo, int plane) {
    return plane >= 0 && plane < bo_of(gbo)->format->planes ? bo_of(gbo)->strides[plane] : 0;
}

static uint32_t bo_get_offset(struct gbm_bo *gbo, int plane) {
    return plane >= 0 && plane < bo_of(gbo)->format->planes ? bo_of(gbo)->offsets[plane] : 0;
}

static uint64_t bo_get_modifier(struct gbm_bo *gbo) { return bo_of(gbo)->modifier; }

static void bo_destroy(struct gbm_bo *gbo) { bo_free(bo_of(gbo)); }

// GBM surfaces back EGL's GBM platform, which needs a GL driver for the device.
static struct gbm_surface *surface_create(struct gbm_device *gbm, uint32_t width, uint32_t height, uint32_t format,
                                          uint32_t flags, const uint64_t *modifiers, const unsigned count) {
    (void)gbm, (void)width, (void)height, (void)format, (void)flags, (void)modifiers, (void)count;
    errno = ENOSYS;
    return NULL;
}

static struct gbm_bo *surface_lock_front_buffer(struct gbm_surface *surface) {
    (void)surface;
    return NULL;
}

static void surface_release_buffer(struct gbm_surface *surface, struct gbm_bo *bo) { (void)surface, (void)bo; }

static int surface_has_free_buffers(struct gbm_surface *surface) {
    (void)surface;
    return 0;
}

static void surface_destroy(struct gbm_surface *surface) { (void)surface; }

static void device_destroy(struct gbm_device *gbm) {
    struct caboose_device *dev = device_of(gbm);
    close(dev->card);
    free(dev->handles);
    pthread_mutex_destroy(&dev->handles_lock);
    free(dev);
}

static int open_primary(int fd) {
    drmDevicePtr device = NULL;
    if (drmGetDevice2(fd, 0, &device)) return -1;
    int card = -1;
    if (device->available_nodes & (1 << DRM_NODE_PRIMARY))
        card = open(device->nodes[DRM_NODE_PRIMARY], O_RDWR | O_CLOEXEC);
    drmFreeDevice(&device);
    return card;
}

static struct gbm_device *create_device(int fd, uint32_t gbm_backend_version) {
    drmVersionPtr version = drmGetVersion(fd);
    const bool vgem = version && version->name && strcmp(version->name, "vgem") == 0;
    drmFreeVersion(version);
    if (!vgem) return NULL;
    struct caboose_device *dev = calloc(1, sizeof(*dev));
    if (!dev) return NULL;
    dev->card = open_primary(fd);
    if (dev->card < 0) {
        free(dev);
        return NULL;
    }
    pthread_mutex_init(&dev->handles_lock, NULL);
    struct gbm_device_v0 *v0 = &dev->base.v0;
    v0->backend_version = gbm_backend_version;
    v0->fd = fd;
    v0->name = "caboose";
    v0->destroy = device_destroy;
    v0->is_format_supported = is_format_supported;
    v0->get_format_modifier_plane_count = get_format_modifier_plane_count;
    v0->bo_create = bo_create;
    v0->bo_import = bo_import;
    v0->bo_map = bo_map;
    v0->bo_unmap = bo_unmap;
    v0->bo_write = bo_write;
    v0->bo_get_fd = bo_get_fd;
    v0->bo_get_planes = bo_get_planes;
    v0->bo_get_handle = bo_get_handle;
    v0->bo_get_plane_fd = bo_get_plane_fd;
    v0->bo_get_stride = bo_get_stride;
    v0->bo_get_offset = bo_get_offset;
    v0->bo_get_modifier = bo_get_modifier;
    v0->bo_destroy = bo_destroy;
    v0->surface_create = surface_create;
    v0->surface_lock_front_buffer = surface_lock_front_buffer;
    v0->surface_release_buffer = surface_release_buffer;
    v0->surface_has_free_buffers = surface_has_free_buffers;
    v0->surface_destroy = surface_destroy;
    return &dev->base;
}

static const struct gbm_backend backend = {
    .v0 = {
        .backend_version = GBM_BACKEND_ABI_VERSION,
        .backend_name = "caboose",
        .create_device = create_device,
    },
};

EXPORT const struct gbm_backend *gbmint_get_backend(const struct gbm_core *gbm_core) {
    core = gbm_core;
    return &backend;
}
