# Linux executor

The phone's native GPU runtime built for Linux: the gfxstream fork at the commit
[`../fork.env`](../fork.env) pins, with its Caboose commits, and this directory's adapter
(the same sources the iOS build links), on the computer's Vulkan driver instead of
MoltenVK. It initializes exactly as the phone does (`caboose_gpu_runtime_start_v4`: v4
indexed virtual WSI, synchronous proof, null optional strings, the memory-audit build) and
presents offscreen: a bound window's surface is a `VK_EXT_headless_surface` of its decoder
instance (fork commit "Caboose: linux-headless-executor"), so its swapchains present into
images nothing displays. It is not part of the iOS build.

## Build

On an x86-64 Linux host with Docker, from the repository root:

```sh
sh apps/ios/GPUStream/gfxstream/linux-executor/build.sh WORK [GFXSTREAM_CHECKOUT]
```

The script clones the fork into `WORK/gfxstream` (read access to the private fork is
needed) unless a checkout at the pinned commit is given, verifies its decoder inputs with
`generate-v4-profile.py --check --patched`, builds the [`Dockerfile`](Dockerfile) image
(Debian trixie with Mesa's lavapipe) and builds `WORK/build/libcaboose_gpu_executor.so` in
it, the network disabled. `CPUS` (default 4) bounds the container; a first build takes
about 20 minutes on four cores.

The library exports the runtime's C API ([`../native_runtime.h`](../native_runtime.h)),
the presentation drafts ([`../presentation_api_draft.h`](../presentation_api_draft.h),
[`../presentation_swapchain_api_draft.h`](../presentation_swapchain_api_draft.h)) with
their headless entry points (`caboose_gpu_surface_attach_headless`,
`caboose_gpu_surface_detach_headless`, `caboose_gpu_surface_configure_extent_headless`), and
`caboose_gpu_executor_start(loader)`, the counterpart of the phone's
`caboose_gpu_live_start_v4`: it opens the Vulkan loader (`libvulkan.so.1` for `NULL`) for
the process lifetime and starts the runtime on it. The Vulkan driver is the loader's:
lavapipe in the build image, or whatever ICD `VK_DRIVER_FILES` selects.

## Test

The runtime starts on lavapipe and runs a process through open, stop and finish:

```sh
docker run --rm --network none -v WORK:/work caboose-linux-executor python3 -c '
import ctypes
l = ctypes.CDLL("/work/build/libcaboose_gpu_executor.so")
t = ctypes.c_uint64()
assert l.caboose_gpu_executor_start(None) == 0
assert l.caboose_gpu_runtime_open(ctypes.byref(t)) == 0 and t.value
assert l.caboose_gpu_runtime_stop(t) == 0 and l.caboose_gpu_runtime_finish(t) == 0
print("runtime ok")'
```
