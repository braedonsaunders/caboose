/* Surface memory. A surface is linear NV12 or P010 in a sealed memfd, exported to
 * the app as a dmabuf through /dev/udmabuf, so GL, Vulkan and Wayland can import
 * it like any decoder's output. Apps that bring their own dmabufs (Chromium
 * allocates through GBM) are imported when the buffer is linear. */
#define _GNU_SOURCE
#include "cbva.h"
#include "marker.h"

#include <drm_fourcc.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/dma-buf.h>
#include <linux/udmabuf.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <va/va_drmcommon.h>

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
    cb_mark_paint(s->map, s->pitch, s->width, s->height, s->bps, 63, 0, -1);
    s->mark = 63 << 6;
    cb_surface_end_cpu(s);
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
    s->size = ALIGN(s->uv_offset + (size_t)s->pitch * s->rows / 2, 4096);
    s->memfd = s->dmabuf = -1;
    s->owner = VA_INVALID_ID;
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
    if (s->dmabuf >= 0) {
        struct stat st;
        if (fstat(s->dmabuf, &st) == 0) {
            s->dev = st.st_dev;
            s->ino = st.st_ino;
        }
    }
    paint_initial(s);
    return VA_STATUS_SUCCESS;
fail:
    cb_surface_free(s);
    return VA_STATUS_ERROR_ALLOCATION_FAILED;
}

VAStatus cb_surface_import(cb_driver *d, cb_surface *s, const VADRMPRIMESurfaceDescriptor *desc)
{
    (void)d;
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
    s->size = desc->objects[0].size;
    if (s->size < uv_off + (size_t)uv_pitch * ((s->height + 1) / 2) || s->rows < s->height)
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    s->dmabuf = fcntl(desc->objects[0].fd, F_DUPFD_CLOEXEC, 0);
    if (s->dmabuf < 0)
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    s->map = mmap(NULL, s->size, PROT_READ | PROT_WRITE, MAP_SHARED, s->dmabuf, 0);
    if (s->map == MAP_FAILED) {
        s->map = NULL;
        cb_surface_free(s);
        return VA_STATUS_ERROR_UNSUPPORTED_MEMORY_TYPE;
    }
    struct stat st;
    if (fstat(s->dmabuf, &st) == 0) {
        s->dev = st.st_dev;
        s->ino = st.st_ino;
    }
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

void cb_surface_mark(cb_surface *s, unsigned tag, uint32_t seq)
{
    int want = (int)((tag & 63) << 6 | (seq & 63));
    if (s->mark == want)
        return;
    cb_surface_begin_cpu(s);
    if (s->mark < 0) {
        /* It held decoded pixels: restore neutral chroma and paint everything. */
        if (s->bps == 1) {
            memset(s->map + s->uv_offset, 128, (size_t)s->pitch * ((s->height + 1) / 2));
        } else {
            for (size_t y = 0; y < (s->height + 1) / 2; y++) {
                uint16_t *row = (uint16_t *)(s->map + s->uv_offset + y * s->pitch);
                for (unsigned x = 0; x < s->pitch / 2; x++)
                    row[x] = 512 << 6;
            }
        }
        cb_mark_paint(s->map, s->pitch, s->width, s->height, s->bps, tag, seq, -1);
    } else {
        cb_mark_paint(s->map, s->pitch, s->width, s->height, s->bps, tag, seq, s->mark);
    }
    s->mark = want;
    cb_surface_end_cpu(s);
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
