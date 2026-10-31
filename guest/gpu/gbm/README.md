# vgem_gbm.so: the GBM backend for the Caboose render node

A computer's render node is the kernel's `vgem` device (`/dev/dri/renderD128`, with its
primary node `/dev/dri/card0`). Mesa's GBM loader opens `<driver>_gbm.so` from its backend
directory for a device's DRM driver name before its own DRI backend, so every GBM user
that opens the render node (Chromium's Wayland GPU path, Mesa's EGL, VA-API, compositors)
loads this backend without configuration. The buffer contract it implements is
[docs/gpu-buffers.md](../../../docs/gpu-buffers.md).

A buffer is a vgem GEM object exported as a dma-buf. Two layouts share one geometry:
tightly stacked planes with rows aligned to 256 bytes.

| Modifier | The dma-buf's bytes | `gbm_bo_map` |
| --- | --- | --- |
| `DRM_FORMAT_MOD_LINEAR` | the pixels, in ordinary shared memory | maps them |
| `CABOOSE_FORMAT_MOD_REMOTE` (`0xcb00000000000001`) | none: the pixels are phone GPU memory | fails with `EINVAL` |

A remote buffer's pages are never touched, so it costs no guest memory; its dma-buf still
has the nominal size, and its inode identifies it to the Caboose Vulkan driver and to
caboose-display. `gbm_bo_create_with_modifiers` chooses remote when the caller offers it
and does not ask for `GBM_BO_USE_LINEAR`, `GBM_BO_USE_WRITE` or `GBM_BO_USE_CURSOR`;
otherwise linear. `gbm_bo_create` without modifiers is always linear, because such a
caller may map the buffer or hand it on without a modifier. Imports
(`GBM_BO_IMPORT_FD`, `GBM_BO_IMPORT_FD_MODIFIER`) take one descriptor per plane, all of
the same buffer, and check strides and offsets against its size. Buffer objects of the
same buffer share one GEM handle on the device's descriptor, closed with the last of them.
GBM surfaces (EGL's GBM platform) and `wl_buffer`/`EGLImage` imports need a GL driver for
the device and fail with `ENOSYS`.

Formats: `XRGB8888`, `ARGB8888`, `XBGR8888`, `ABGR8888`, `RGB565`, the four 10-bit
`2101010` formats, `XBGR16161616F`, `ABGR16161616F`, `R8`, `GR88`, `R16`, `GR1616`, `NV12`
and `P010` (`include/caboose_drm_formats.h`, shared with the Vulkan driver and
caboose-display).

vgem creates objects only on its primary node, so the backend opens the primary node of
the device it is given (`drmGetDevice2`) when the device is created; a sandboxed process
must create its GBM device before entering its sandbox, as Chromium's GPU process does.
The backend's ABI is Mesa's versioned `gbm_backend_abi.h`, copied unmodified from Mesa
25.0.7 into `include/` (MIT).

## Build and test

Needs a C11 compiler, `pkg-config`, `libdrm-dev` and, for the test, `libgbm-dev`.

```sh
make                 # build/vgem_gbm.so, build/gbm_test
make check           # the test, through the system libgbm, on the machine's vgem node
make install         # into $(pkg-config --variable=libdir gbm)/gbm; DESTDIR is honoured
```

`gbm_test` loads the backend through the real loader (`GBM_BACKENDS_PATH`) and checks
backend selection, formats and plane counts, linear mapping visible through the exported
descriptor, remote allocation and its refusal to map, the shared handle of an imported
buffer, stride and plane validation, `NV12` plane layout, and that 500 4K allocations leak
no descriptors. It exits 77 without a vgem render node. Load the module on the test
machine with `modprobe vgem` (it ships with the WSL2 kernel and with distribution
kernels). The test passes as an unprivileged user under AddressSanitizer and
UndefinedBehaviorSanitizer.
