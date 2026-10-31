// SPDX-License-Identifier: MIT
// Drives vgem_gbm.so through the system libgbm loader against a real vgem render node.
// Run with GBM_BACKENDS_PATH set to the build directory. Exit 0 pass, 1 failure, 77
// when there is no vgem render node.
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <gbm.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <xf86drm.h>

#include "caboose_drm_formats.h"

static int failures;
#define CHECK(c)                                                                   \
    do {                                                                           \
        if (!(c)) {                                                                \
            fprintf(stderr, "%s:%d: CHECK(%s) failed (errno %d)\n", __FILE__, __LINE__, #c, errno); \
            ++failures;                                                            \
        }                                                                          \
    } while (0)

static int open_vgem_render(void) {
    char path[64];
    for (int minor = 128; minor < 192; ++minor) {
        snprintf(path, sizeof(path), "/dev/dri/renderD%d", minor);
        const int fd = open(path, O_RDWR | O_CLOEXEC);
        if (fd < 0) continue;
        drmVersionPtr v = drmGetVersion(fd);
        const int vgem = v && strcmp(v->name, "vgem") == 0;
        drmFreeVersion(v);
        if (vgem) return fd;
        close(fd);
    }
    return -1;
}

static ino_t inode_of(int fd) {
    struct stat st;
    return fstat(fd, &st) ? 0 : st.st_ino;
}

static int open_fds(void) {
    int n = 0;
    DIR *d = opendir("/proc/self/fd");
    if (!d) return -1;
    while (readdir(d)) ++n;
    closedir(d);
    return n;
}

static void linear_buffers(struct gbm_device *gbm) {
    struct gbm_bo *bo = gbm_bo_create(gbm, 1000, 700, GBM_FORMAT_XRGB8888, GBM_BO_USE_RENDERING);
    CHECK(bo);
    if (!bo) return;
    CHECK(gbm_bo_get_modifier(bo) == DRM_FORMAT_MOD_LINEAR);
    CHECK(gbm_bo_get_stride(bo) == 4096);  // 4000 bytes rounded to 256.
    CHECK(gbm_bo_get_plane_count(bo) == 1);
    uint32_t stride;
    void *data = NULL;
    uint8_t *map = gbm_bo_map(bo, 10, 20, 100, 100, GBM_BO_TRANSFER_WRITE, &stride, &data);
    CHECK(map);
    if (map) {
        memset(map, 0xab, 400);
        gbm_bo_unmap(bo, data);
    }
    // Another view of the same buffer, through its exported descriptor, sees the store.
    const int fd = gbm_bo_get_fd(bo);
    CHECK(fd >= 0);
    CHECK(lseek(fd, 0, SEEK_END) >= (off_t)(4096 * 700));
    const uint8_t *view = mmap(NULL, 4096 * 700, PROT_READ, MAP_SHARED, fd, 0);
    CHECK(view != MAP_FAILED);
    if (view != MAP_FAILED) {
        CHECK(view[20 * 4096 + 40] == 0xab && view[20 * 4096 + 40 + 399] == 0xab && view[20 * 4096 + 39] == 0);
        munmap((void *)view, 4096 * 700);
    }
    close(fd);
    gbm_bo_destroy(bo);

    // Asking for a CPU-visible layout never yields a remote buffer.
    const uint64_t remote = CABOOSE_FORMAT_MOD_REMOTE;
    bo = gbm_bo_create_with_modifiers2(gbm, 64, 64, GBM_FORMAT_ARGB8888, &remote, 1, GBM_BO_USE_LINEAR);
    CHECK(!bo);
}

static void remote_buffers(struct gbm_device *gbm) {
    const uint64_t modifiers[] = {DRM_FORMAT_MOD_LINEAR, CABOOSE_FORMAT_MOD_REMOTE};
    struct gbm_bo *bo = gbm_bo_create_with_modifiers2(gbm, 1920, 1080, GBM_FORMAT_ABGR8888, modifiers, 2,
                                                      GBM_BO_USE_RENDERING | GBM_BO_USE_SCANOUT);
    CHECK(bo);
    if (!bo) return;
    CHECK(gbm_bo_get_modifier(bo) == CABOOSE_FORMAT_MOD_REMOTE);
    CHECK(gbm_bo_get_stride(bo) == 7680);
    uint32_t stride;
    void *data = NULL;
    errno = 0;
    CHECK(!gbm_bo_map(bo, 0, 0, 16, 16, GBM_BO_TRANSFER_READ, &stride, &data));
    CHECK(errno == EINVAL);

    // An import of the exported buffer is the same object: same inode and handle.
    const int fd = gbm_bo_get_fd(bo);
    struct gbm_import_fd_modifier_data in = {
        .width = 1920, .height = 1080, .format = GBM_FORMAT_ABGR8888, .num_fds = 1,
        .fds = {fd}, .strides = {7680}, .offsets = {0}, .modifier = CABOOSE_FORMAT_MOD_REMOTE,
    };
    struct gbm_bo *imported = gbm_bo_import(gbm, GBM_BO_IMPORT_FD_MODIFIER, &in, GBM_BO_USE_RENDERING);
    CHECK(imported);
    if (imported) {
        CHECK(gbm_bo_get_modifier(imported) == CABOOSE_FORMAT_MOD_REMOTE);
        CHECK(gbm_bo_get_handle(imported).u32 == gbm_bo_get_handle(bo).u32);
        const int imported_fd = gbm_bo_get_fd(imported);
        CHECK(inode_of(imported_fd) == inode_of(fd));
        close(imported_fd);
        gbm_bo_destroy(imported);
    }
    // The shared handle survives the import's destruction.
    struct drm_prime_handle prime = {.handle = gbm_bo_get_handle(bo).u32, .flags = DRM_CLOEXEC};
    CHECK(ioctl(gbm_device_get_fd(gbm), DRM_IOCTL_PRIME_HANDLE_TO_FD, &prime) == 0);
    if (prime.fd > 0) {
        CHECK(inode_of(prime.fd) == inode_of(fd));
        close(prime.fd);
    }
    // Strides that do not fit the buffer are refused.
    in.strides[0] = 7680 * 2;
    CHECK(!gbm_bo_import(gbm, GBM_BO_IMPORT_FD_MODIFIER, &in, GBM_BO_USE_RENDERING));
    in.strides[0] = 100;
    CHECK(!gbm_bo_import(gbm, GBM_BO_IMPORT_FD_MODIFIER, &in, GBM_BO_USE_RENDERING));
    close(fd);
    gbm_bo_destroy(bo);
}

static void planar_buffers(struct gbm_device *gbm) {
    const uint64_t remote = CABOOSE_FORMAT_MOD_REMOTE;
    struct gbm_bo *bo = gbm_bo_create_with_modifiers2(gbm, 1280, 721, GBM_FORMAT_NV12, &remote, 1, GBM_BO_USE_RENDERING);
    CHECK(bo);
    if (!bo) return;
    CHECK(gbm_bo_get_plane_count(bo) == 2);
    CHECK(gbm_bo_get_stride_for_plane(bo, 0) == 1280 && gbm_bo_get_offset(bo, 0) == 0);
    CHECK(gbm_bo_get_stride_for_plane(bo, 1) == 1280 && gbm_bo_get_offset(bo, 1) == 1280 * 721);
    const int y = gbm_bo_get_fd_for_plane(bo, 0), uv = gbm_bo_get_fd_for_plane(bo, 1);
    CHECK(y >= 0 && uv >= 0 && inode_of(y) == inode_of(uv));
    CHECK(lseek(y, 0, SEEK_END) >= 1280 * 721 + 1280 * 361);
    struct gbm_import_fd_modifier_data in = {
        .width = 1280, .height = 721, .format = GBM_FORMAT_NV12, .num_fds = 2, .fds = {y, uv},
        .strides = {1280, 1280}, .offsets = {0, 1280 * 721}, .modifier = CABOOSE_FORMAT_MOD_REMOTE,
    };
    struct gbm_bo *imported = gbm_bo_import(gbm, GBM_BO_IMPORT_FD_MODIFIER, &in, 0);
    CHECK(imported);
    if (imported) gbm_bo_destroy(imported);
    in.num_fds = 1;  // A plane is missing.
    CHECK(!gbm_bo_import(gbm, GBM_BO_IMPORT_FD_MODIFIER, &in, 0));
    close(y);
    close(uv);
    gbm_bo_destroy(bo);
}

static void formats(struct gbm_device *gbm) {
    CHECK(strcmp(gbm_device_get_backend_name(gbm), "caboose") == 0);
    CHECK(gbm_device_is_format_supported(gbm, GBM_FORMAT_XRGB8888, GBM_BO_USE_RENDERING));
    CHECK(gbm_device_is_format_supported(gbm, GBM_BO_FORMAT_ARGB8888, GBM_BO_USE_RENDERING));
    CHECK(gbm_device_is_format_supported(gbm, DRM_FORMAT_P010, GBM_BO_USE_RENDERING));
    CHECK(!gbm_device_is_format_supported(gbm, GBM_FORMAT_YUYV, GBM_BO_USE_RENDERING));
    CHECK(gbm_device_get_format_modifier_plane_count(gbm, GBM_FORMAT_NV12, CABOOSE_FORMAT_MOD_REMOTE) == 2);
    CHECK(gbm_device_get_format_modifier_plane_count(gbm, GBM_FORMAT_XRGB8888, I915_FORMAT_MOD_X_TILED) == -1);
    CHECK(!gbm_surface_create(gbm, 64, 64, GBM_FORMAT_XRGB8888, GBM_BO_USE_RENDERING));
}

static void no_leaks(struct gbm_device *gbm) {
    const int before = open_fds();
    const uint64_t remote = CABOOSE_FORMAT_MOD_REMOTE;
    for (int i = 0; i < 500; ++i) {
        struct gbm_bo *bo = gbm_bo_create_with_modifiers2(gbm, 3840, 2160, GBM_FORMAT_XRGB8888, &remote, 1,
                                                          GBM_BO_USE_RENDERING);
        if (!bo) {
            CHECK(bo);
            break;
        }
        gbm_bo_destroy(bo);
    }
    CHECK(open_fds() == before);
}

int main(void) {
    const int fd = open_vgem_render();
    if (fd < 0) {
        puts("no vgem render node");
        return 77;
    }
    struct gbm_device *gbm = gbm_create_device(fd);
    CHECK(gbm);
    if (!gbm) return 1;
    formats(gbm);
    linear_buffers(gbm);
    remote_buffers(gbm);
    planar_buffers(gbm);
    no_leaks(gbm);
    gbm_device_destroy(gbm);
    close(fd);
    if (failures) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    puts("gbm_test: pass");
    return 0;
}
