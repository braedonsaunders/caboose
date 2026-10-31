# GPU buffers: the render node and phone-resident dma-bufs

A computer's render node is the kernel's virtual GEM device, `vgem`: a real DRM device with
a primary node (`/dev/dri/cardN`) and a render node (`/dev/dri/renderDN`) whose buffers are
real dma-bufs. Every toolkit that shares GPU buffers on Linux does so through such a node
and its GBM allocator. Caboose provides both, so a buffer can be named, passed between
processes and fenced the way Linux expects, while its pixels live wherever the GPU is.

## Buffers

`vgem_gbm.so` ([guest/gpu/gbm](../guest/gpu/gbm/README.md)) is the GBM backend for the
node; Mesa's GBM loader selects it by the device's driver name. Buffers have one geometry:
tightly stacked planes, each row aligned to 256 bytes (`include/caboose_drm_formats.h`,
which lists the formats). Two DRM format modifiers describe where the pixels are:

| Modifier | Value | Pixels |
| --- | --- | --- |
| `DRM_FORMAT_MOD_LINEAR` | `0` | In the dma-buf, as ordinary shared memory |
| `CABOOSE_FORMAT_MOD_REMOTE` | `0xcb00000000000001` | In phone GPU memory; the dma-buf has the nominal size and no meaningful bytes |

A remote buffer's pages are never touched, so it costs no computer memory. Its identity
is the dma-buf's inode: the kernel numbers dma-bufs from a counter that does not repeat
while it runs, and every descriptor of one buffer, in any process, has the same inode.
Vendor `0xcb` is not allocated in `drm_fourcc.h`.

A caller that offers `CABOOSE_FORMAT_MOD_REMOTE` among its modifiers and does not ask for
a CPU-visible layout (`GBM_BO_USE_LINEAR`, `GBM_BO_USE_WRITE`, `GBM_BO_USE_CURSOR`) gets a
remote buffer; any other allocation is linear. A remote buffer cannot be mapped.

## In the Vulkan driver

In socket mode the Caboose Vulkan driver (`guest/gpu/gfxstream`) implements
`VK_EXT_external_memory_dma_buf` and `VK_EXT_image_drm_format_modifier` for remote buffers
only. Each format it can share (`dmabuf/remote_images.h`) lists one modifier,
`CABOOSE_FORMAT_MOD_REMOTE`, with the host's optimal tiling features; other modifiers and
linear dma-bufs are unsupported. A remote image is an ordinary optimally tiled host image:
external-memory and modifier structures never reach the host. Its memory-plane layout,
from `vkGetImageSubresourceLayout`, is the one it was created with, or the nominal layout
above for an image created from a modifier list.

Within a process, memory imported from or exported as one dma-buf is one host allocation
(`dmabuf/dmabuf.h`). Exporting creates a vgem object for it; the first import of a buffer
allocates the host memory; later imports of the same buffer get their own guest handles
for the same host allocation, which is freed with the last of them. The driver keeps one
descriptor of each such buffer, so `vkGetMemoryFdKHR` returns the same buffer.

## Presenting a buffer in a window

When remote memory is allocated for a dedicated image, the driver registers the buffer
with the GPU broker over the private surface socket (`dmabuf/registration.h`): CGLS
kind 40, 48 bytes, carries the host instance, device, queue and image handles, the
image's format and extent, and the queue family, with the dma-buf itself in
`SCM_RIGHTS`; kind 41, 16 bytes, forgets a buffer by device and inode when its last
memory object is freed. One connection per process carries these records; closing it
forgets all of the process's buffers. A buffer is registered once, for its first image.

caboose-display names the render node as the main device of its linux-dmabuf global's
feedback, and with the phone GPU configured also advertises the remote modifier for every
remote format. It accepts a remote dma-buf without mapping it. When a toplevel commits a new remote buffer, it sends the broker
`BUFFER_PRESENT` (CGB1 kind 9, 56 bytes: request, window, the dma-buf's device and inode,
width and height) and holds the client's `wl_buffer` until the broker answers with
`BUFFER_RELEASED` (kind 10, 32 bytes: request and status, 0 when the buffer was shown or
an errno). If the broker is lost, every held buffer is released.

The broker looks the buffer up and binds the window to the process that registered it:
it asks the compositor for a grant with a bind in the `BUFFER_WINDOW` namespace (2),
whose object is the window ID. The compositor grants only a toplevel it has an
unreleased buffer present for, to a live process of its own user. The broker then
presents the registered image through the GPU stream's ordinary `SURFACE_BIND` and plain
`PRESENT` (no waits, `GENERAL` layout), one frame in flight per window. A commit that
arrives while a frame is in flight waits; a newer one replaces it, and the replaced buffer
is released unshown. The phone's source release releases the shown buffer. A present the
phone refuses because the window's previous frame is still on screen (`EBUSY`) is offered
again 4 ms later, at most 64 times. A buffer of another process or size retires the
window's grant first. A client must have finished rendering a buffer before committing
it: Chromium's GBM presentation waits for its rendering fence first, and the image is
copied on the registering process's queue.

## Requirements

The `vgem` module ships with the WSL2 kernel and with distribution kernels and is loaded
with `modprobe vgem`; it creates buffers only on its primary node, so a process that
allocates needs both nodes. Chromium skips render nodes whose driver is `vgem` when it
looks for one, so it is started with `--render-node-override` naming the computer's
render node.
