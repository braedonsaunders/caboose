/* Surface memory. A surface is linear NV12 or P010 in a sealed memfd, exported to
 * the app as a dmabuf through /dev/udmabuf, so GL, Vulkan and Wayland can import
 * it like any decoder's output. A kernel without udmabuf (WSL) exports a vgem
 * buffer instead: shared memory pages behind a dmabuf, which is all udmabuf adds.
 * Apps that bring their own dmabufs (Chromium allocates through GBM) are
 * imported when the buffer is linear.
 *
 * The last page of every surface we allocate is its identity (gpu_media.h):
 * what the planes mean, for a Vulkan driver in any process that imports it. */
#define _GNU_SOURCE
#include "cbva.h"

#include <drm_fourcc.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/dma-buf.h>
#include <linux/udmabuf.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <stdio.h>
#include <unistd.h>
#include <va/va_drmcommon.h>
#include <xf86drm.h>

#define ALIGN(x, a) (((x) + (a) - 1) / (a) * (a))

static void paint_initial(cb_surface *s)
{
    cb_surface_begin_cpu(s);
    size_t uv_rows = (s->height + 1) / 2;
    if (s->bps == 1) {
        memset(s->map + s->uv_offset, 128, s->pitch * uv_rows);
    } else {
        for (size_t y = 0; y < uv_rows; y++) {
            uint16_t *row = (uint16_t *)(s->map + s->uv_offset + y * s->pitch);
            for (unsigned x = 0; x < s->pitch / 2; x++)
                row[x] = 512 << 6;
        }
    }
    if (s->bps == 1) {
        memset(s->map, 16, (size_t)s->pitch * s->height);
    } else {
        for (size_t y = 0; y < s->height; y++) {
            uint16_t *row = (uint16_t *)(s->map + y * s->pitch);
            for (unsigned x = 0; x < s->pitch / 2; x++)
                row[x] = 64 << 6;
        }
    }
    s->pending = 1;
    cb_surface_end_cpu(s);
}

int cb_vgem_open(void)
{
    for (int minor = 0; minor < 16; minor++) {
        char path[32];
        snprintf(path, sizeof(path), "/dev/dri/card%d", minor);
        int fd = open(path, O_RDWR | O_CLOEXEC);
        if (fd < 0)
            continue;
        drmVersionPtr v = drmGetVersion(fd);
        int vgem = v && v->name && strcmp(v->name, "vgem") == 0;
        drmFreeVersion(v);
        if (vgem)
            return fd;
        close(fd);
    }
    return -1;
}

/* A dumb buffer of at least `size` bytes on vgem, as a dmabuf; its size in *size. */
static int vgem_dmabuf(int vgem, size_t *size, unsigned pitch)
{
    struct drm_mode_create_dumb create = {
        .width = pitch,
        .height = (uint32_t)((*size + pitch - 1) / pitch),
        .bpp = 8,
    };
    if (drmIoctl(vgem, DRM_IOCTL_MODE_CREATE_DUMB, &create) < 0)
        return -1;
    int fd = -1;
    if (drmPrimeHandleToFD(vgem, create.handle, DRM_CLOEXEC | DRM_RDWR, &fd) < 0)
        fd = -1;
    struct drm_gem_close close_handle = { .handle = create.handle };
    drmIoctl(vgem, DRM_IOCTL_GEM_CLOSE, &close_handle); /* the dmabuf keeps the buffer */
    if (fd >= 0)
        *size = (size_t)create.size;
    return fd;
}

VAStatus cb_surface_alloc(cb_driver *d, cb_surface *s, unsigned w, unsigned h, uint32_t fourcc)
{
    s->width = w;
    s->height = h;
    s->fourcc = fourcc;
    s->bps = fourcc == VA_FOURCC_P010 ? 2 : 1;
    s->pitch = ALIGN(w * s->bps, 256);
    s->rows = ALIGN(h, 32);
    s->uv_offset = (size_t)s->pitch * s->rows;
    s->size = ALIGN(s->uv_offset + (size_t)s->pitch * s->rows / 2, 4096) + CB_GM_IDENTITY_PAGE;
    s->memfd = s->dmabuf = -1;
    s->owner = VA_INVALID_ID;
    if (d->udmabuf < 0 && d->vgem >= 0) {
        s->dmabuf = vgem_dmabuf(d->vgem, &s->size, s->pitch);
        if (s->dmabuf < 0) {
            cb_log("vgem: %s; surfaces cannot be exported", strerror(errno));
        } else {
            s->map = mmap(NULL, s->size, PROT_READ | PROT_WRITE, MAP_SHARED, s->dmabuf, 0);
            if (s->map == MAP_FAILED) {
                s->map = NULL;
                goto fail;
            }
            goto identify;
        }
    }
    s->memfd = memfd_create("caboose-va-surface", MFD_CLOEXEC | MFD_ALLOW_SEALING);
    if (s->memfd < 0 || ftruncate(s->memfd, (off_t)s->size) < 0)
        goto fail;
    s->map = mmap(NULL, s->size, PROT_READ | PROT_WRITE, MAP_SHARED, s->memfd, 0);
    if (s->map == MAP_FAILED) {
        s->map = NULL;
        goto fail;
    }
    if (d->udmabuf >= 0 && fcntl(s->memfd, F_ADD_SEALS, F_SEAL_SHRINK) == 0) {
        struct udmabuf_create c = { .memfd = (uint32_t)s->memfd, .flags = UDMABUF_FLAGS_CLOEXEC,
                                    .offset = 0, .size = s->size };
        s->dmabuf = ioctl(d->udmabuf, UDMABUF_CREATE, &c);
        if (s->dmabuf < 0)
            cb_log("udmabuf: %s; surfaces cannot be exported", strerror(errno));
    }
identify:
    s->identity = cb_gm_identity_at(s->map, s->size);
    cb_surface_empty(d, s);
    paint_initial(s);
    return VA_STATUS_SUCCESS;
fail:
    cb_surface_free(s);
    return VA_STATUS_ERROR_ALLOCATION_FAILED;
}

VAStatus cb_surface_import(cb_driver *d, cb_surface *s, const VADRMPRIMESurfaceDescriptor *desc)
{
    s->memfd = s->dmabuf = -1;
    s->owner = VA_INVALID_ID;
    s->imported = 1;
    if (desc->num_objects != 1 || (desc->fourcc != VA_FOURCC_NV12 && desc->fourcc != VA_FOURCC_P010))
        return VA_STATUS_ERROR_UNSUPPORTED_RT_FORMAT;
    uint64_t mod = desc->objects[0].drm_format_modifier;
    if (mod != DRM_FORMAT_MOD_LINEAR && mod != DRM_FORMAT_MOD_INVALID)
        return VA_STATUS_ERROR_UNSUPPORTED_MEMORY_TYPE;
    s->width = desc->width;
    s->height = desc->height;
    s->fourcc = desc->fourcc;
    s->bps = desc->fourcc == VA_FOURCC_P010 ? 2 : 1;
    /* Planes: either one composed layer with two planes or two single-plane layers. */
    uint32_t y_off, y_pitch, uv_off, uv_pitch;
    if (desc->num_layers == 1 && desc->layers[0].num_planes == 2) {
        y_off = desc->layers[0].offset[0];
        y_pitch = desc->layers[0].pitch[0];
        uv_off = desc->layers[0].offset[1];
        uv_pitch = desc->layers[0].pitch[1];
    } else if (desc->num_layers == 2) {
        y_off = desc->layers[0].offset[0];
        y_pitch = desc->layers[0].pitch[0];
        uv_off = desc->layers[1].offset[0];
        uv_pitch = desc->layers[1].pitch[0];
    } else {
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    }
    if (y_off != 0 || y_pitch != uv_pitch || y_pitch < s->width * s->bps)
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    s->pitch = y_pitch;
    s->uv_offset = uv_off;
    s->rows = uv_off / y_pitch;
    size_t planes = uv_off + (size_t)uv_pitch * ((s->rows > s->height ? s->rows : s->height) + 1) / 2;
    if (desc->objects[0].size < uv_off + (size_t)uv_pitch * ((s->height + 1) / 2) || s->rows < s->height)
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    s->dmabuf = fcntl(desc->objects[0].fd, F_DUPFD_CLOEXEC, 0);
    if (s->dmabuf < 0)
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    /* The whole buffer, which may be larger than the application says. */
    off_t end = lseek(s->dmabuf, 0, SEEK_END);
    s->size = end > 0 && (size_t)end > desc->objects[0].size ? (size_t)end : desc->objects[0].size;
    s->map = mmap(NULL, s->size, PROT_READ | PROT_WRITE, MAP_SHARED, s->dmabuf, 0);
    if (s->map == MAP_FAILED) {
        s->map = NULL;
        cb_surface_free(s);
        return VA_STATUS_ERROR_UNSUPPORTED_MEMORY_TYPE;
    }
    /* A buffer with a whole spare page after its planes, as the computer's GBM backend
     * allocates video buffers (guest/gpu/gbm), carries an identity there like our own
     * surfaces; any other imported buffer carries none. */
    if (s->size % CB_GM_IDENTITY_PAGE == 0 && s->size >= ALIGN(planes, 4096) + CB_GM_IDENTITY_PAGE)
        s->identity = cb_gm_identity_at(s->map, s->size);
    if (s->identity)
        cb_surface_empty(d, s);
    paint_initial(s);
    return VA_STATUS_SUCCESS;
}

void cb_surface_free(cb_surface *s)
{
    if (s->map)
        munmap(s->map, s->size);
    if (s->dmabuf >= 0)
        close(s->dmabuf);
    if (s->memfd >= 0)
        close(s->memfd);
    s->map = NULL;
    s->dmabuf = s->memfd = -1;
}

static void dmabuf_sync(cb_surface *s, uint64_t flags)
{
    if (!s->imported)
        return;
    struct dma_buf_sync sync = { .flags = flags | DMA_BUF_SYNC_RW };
    while (ioctl(s->dmabuf, DMA_BUF_IOCTL_SYNC, &sync) < 0 && (errno == EINTR || errno == EAGAIN))
        ;
}

void cb_surface_begin_cpu(cb_surface *s) { dmabuf_sync(s, DMA_BUF_SYNC_START); }
void cb_surface_end_cpu(cb_surface *s) { dmabuf_sync(s, DMA_BUF_SYNC_END); }

static void identity_write(cb_surface *s, uint32_t state, const uint8_t token[16], uint64_t serial)
{
    if (!s->identity)
        return;
    cb_gm_identity v = { .state = state, .serial = serial, .surface = s->id,
                         .fourcc = s->fourcc == VA_FOURCC_P010 ? CB_GM_FOURCC_P010 : CB_GM_FOURCC_NV12,
                         .width = (uint16_t)s->width, .height = (uint16_t)s->height,
                         .pitch = s->pitch, .uv_offset = (uint32_t)s->uv_offset };
    memcpy(v.token, token, 16);
    cb_gm_identity_write(s->identity, &v);
}

void cb_surface_phone(cb_driver *d, cb_surface *s, uint64_t serial)
{
    identity_write(s, CB_GM_PHONE, d->token, serial);
}

void cb_surface_pixels(cb_driver *d, cb_surface *s)
{
    identity_write(s, CB_GM_PIXELS, d->token, ++d->next_serial);
}

void cb_surface_empty(cb_driver *d, cb_surface *s)
{
    identity_write(s, CB_GM_EMPTY, d->token, 0);
}

VAStatus cb_surface_export(cb_surface *s, uint32_t mem_type, uint32_t flags, void *descriptor)
{
    if (mem_type != VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2)
        return VA_STATUS_ERROR_UNSUPPORTED_MEMORY_TYPE;
    if (s->dmabuf < 0)
        return VA_STATUS_ERROR_UNSUPPORTED_MEMORY_TYPE;
    VADRMPRIMESurfaceDescriptor *d = descriptor;
    memset(d, 0, sizeof(*d));
    int fd = fcntl(s->dmabuf, F_DUPFD_CLOEXEC, 0);
    if (fd < 0)
        return VA_STATUS_ERROR_ALLOCATION_FAILED;
    int p010 = s->fourcc == VA_FOURCC_P010;
    d->fourcc = s->fourcc;
    d->width = s->width;
    d->height = s->height;
    d->num_objects = 1;
    d->objects[0].fd = fd;
    d->objects[0].size = (uint32_t)s->size;
    d->objects[0].drm_format_modifier = DRM_FORMAT_MOD_LINEAR;
    if (flags & VA_EXPORT_SURFACE_COMPOSED_LAYERS) {
        d->num_layers = 1;
        d->layers[0].drm_format = p010 ? DRM_FORMAT_P010 : DRM_FORMAT_NV12;
        d->layers[0].num_planes = 2;
        d->layers[0].offset[1] = (uint32_t)s->uv_offset;
        d->layers[0].pitch[0] = d->layers[0].pitch[1] = s->pitch;
    } else {
        d->num_layers = 2;
        d->layers[0].drm_format = p010 ? DRM_FORMAT_R16 : DRM_FORMAT_R8;
        d->layers[0].num_planes = 1;
        d->layers[0].pitch[0] = s->pitch;
        d->layers[1].drm_format = p010 ? DRM_FORMAT_GR1616 : DRM_FORMAT_GR88;
        d->layers[1].num_planes = 1;
        d->layers[1].offset[0] = (uint32_t)s->uv_offset;
        d->layers[1].pitch[0] = s->pitch;
    }
    return VA_STATUS_SUCCESS;
}
