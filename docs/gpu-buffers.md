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

## Requirements

The `vgem` module ships with the WSL2 kernel and with distribution kernels and is loaded
with `modprobe vgem`; it creates buffers only on its primary node, so a process that
allocates needs both nodes.
