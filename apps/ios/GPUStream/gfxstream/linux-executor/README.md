# Linux executor

Stands in for the phone so a guest driver release can be checked end to end without an
iPhone. It is the phone's GPU executor on Linux: the phone's native runtime (the gfxstream
fork at the commit [`../fork.env`](../fork.env) pins, with its Caboose commits, and the
adapter in [`..`](..), the sources the iOS build links) on the computer's Vulkan driver
instead of MoltenVK, driven by [`executor.py`](executor.py), which speaks the live protocol
([docs/gpu-live.md](../../../../../docs/gpu-live.md)) as CabooseKit's `LiveGPUSession`,
`LiveGPUNativeBinding`, `LiveGPUSurfaceController`, `LiveGPUIndexedSurface` and
`LiveGPUAcquireTask` do. Presentation is offscreen: each bound window gets a
`VK_EXT_headless_surface` of its decoder instance (fork commit "Caboose:
linux-headless-executor"), its swapchains present into images nothing displays, and every
presented picture is captured and checksummed. None of it is part of the iOS build.

## Build

On an x86-64 Linux host with Docker, from the repository root:

```sh
sh apps/ios/GPUStream/gfxstream/linux-executor/build.sh WORK [GFXSTREAM_CHECKOUT]
```

The script clones the fork into `WORK/gfxstream` (read access to the private fork is
needed) unless a checkout at the pinned commit is given, verifies its decoder inputs with
`generate-v4-profile.py --check --patched`, builds the [`Dockerfile`](Dockerfile) image
`caboose-linux-executor` (Debian trixie with Mesa's lavapipe and vulkan-tools) and builds
`WORK/build/libcaboose_gpu_executor.so` in it, the network disabled. `CPUS` (default 4)
bounds the container; a first build takes about 20 minutes on four cores.

The library exports the runtime's C API ([`../native_runtime.h`](../native_runtime.h)),
the presentation drafts ([`../presentation_api_draft.h`](../presentation_api_draft.h),
[`../presentation_swapchain_api_draft.h`](../presentation_swapchain_api_draft.h)) with
their headless entry points (`caboose_gpu_surface_attach_headless`,
`caboose_gpu_surface_detach_headless`, `caboose_gpu_surface_configure_extent_headless`), and
`caboose_gpu_executor_start(loader)`, the counterpart of the phone's
`caboose_gpu_live_start_v4`: it opens the Vulkan loader (`libvulkan.so.1` for `NULL`) for
the process lifetime and starts the runtime on it exactly as the phone does (v4 indexed
virtual WSI, synchronous proof, null optional strings). The Vulkan driver is the loader's:
lavapipe in the image, or whatever ICD `VK_DRIVER_FILES` selects.

## Run

```sh
python3 executor.py --connect HOST:PORT --token-file TOKEN --library WORK/build/libcaboose_gpu_executor.so
```

The executor connects to a broker's WebSocket as the host relay connects the phone: the
`/gpu` upgrade with the computer's per-wake token, an executor UUID, `X-Caboose-GPU-Computer`
and the phone's capability names in `X-Caboose-GPU-Features` (`--features` replaces them).
It negotiates the v4 session (and, as the phone, the zstd stream and executor resume's
acknowledgements), opens a native process per `PROCESS_OPEN`, runs each stream on a
socketpair with `caboose_gpu_runtime_run` (completion feeds, ORDER marks, shader and upload
inventories are the runtime's), and serves surface binds, queries, indexed swapchains,
acquisitions and ordered presents through the presentation drafts. `--cache-root DIR` gives
the shader and upload caches a directory; without it the computer sends every module and
upload. A window bound with no extent takes `--display` (default 1920x1080), the extent of
the executor's offscreen display. SIGTERM or SIGINT drains the executor (`EXECUTOR_DRAIN`);
it exits 0 after a normal close that followed its `REVOKED`.

Each line it logs starts with `CABOOSE_LINUX_EXECUTOR`: the session, processes, streams,
surface binds and queries, swapchains, and presented frames. A presented frame is one whose
copy and present both completed (`PRESENT_RETIRED`); the first and every `--log-every`
(default 60) of a swapchain are logged with the CRC-32 of the picture the application
presented, and a retired swapchain reports its frames, captured pictures, distinct pictures
and a chain of all its checksums:

```
CABOOSE_LINUX_EXECUTOR presented window=0x200000 swapchain=1 frames=60 serial=60 checksum=714f47f9
CABOOSE_LINUX_EXECUTOR swapchain retired window=0x200000 swapchain=1 frames=300 captured=300 distinct=50 chain=e51ca5e4
```

`--no-checksums` presents without captures. `CABOOSE_LINUX_EXECUTOR_TRACE=1` also logs each
present as it is run. SIGUSR1 prints every Python thread's stack.

[`broker_host.py`](broker_host.py) hosts a broker for it in place of the owner's display:
it starts `guest/gpu/gfxstream/caboose-gpu-broker` from this checkout with its control
socket and a fresh token, hands each TCP connection on `--listen` to the broker as the
display hands it the relayed phone, and answers the broker's compositor records. It grants
every surface bind to the window it names and every revoke, without the compositor's check
that the bound process made the window, so it belongs on disposable test computers only.

## Check

```sh
sh apps/ios/GPUStream/gfxstream/linux-executor/check.sh IMAGE WORK DRIVER SYNC_CHECK [OUT]
```

runs a guest driver release end to end: a disposable container of the computer image
`IMAGE` runs `broker_host.py` and an Xvfb display, an executor container shares its network
namespace, the [synchronization probe](../../../../../guest/gpu/gfxstream/driver/sync-check/README.md)
`SYNC_CHECK` runs on the driver `DRIVER` against an executor with the phone's capabilities,
and vkcube presents 300 frames through another with the same capabilities. Both
executors must drain cleanly, and each of the probe's child windows (a covering and an inset
child of one top-level, an inset child of another) must retire its surface with every frame
on the executor: `broker_host.py` grants each window its own bind, as the compositor grants
a child window its own. Each window bind is answered 0.4 s late (`BIND_DELAY`), as a
phone waiting for its window's layer is, and surfaces report the R8G8B8A8 formats besides
lavapipe's two (`EXTRA_FORMATS`), as the phone does, so the answers a window gets before and
after its bind differ; `broker_host.py --bind-delay` and `executor.py --extra-formats` do
this. With `caboose-computer:flathub-79f46a1` and the driver of
`guest/gpu/gfxstream/driver/build.sh`:

```
PASS sync-check: 15 cases
PASS child windows: 3 surfaces presented 30 frames each
PASS vkcube: window=0x200000 swapchain=1 frames=300 captured=300 distinct=50 chain=e51ca5e4
```

The probe's `surface_enumeration` case reports the range of format counts it saw
(`formats=2..3`): a range shows the bind changed the answer within the run, and a driver
whose enumeration does not survive that change fails it. vkcube's frames are deterministic:
the same build and settings give the same chain.

## Limits

- The phone's application lifecycle is absent: the executor never suspends
  (`EXECUTOR_SUSPEND`, `QUIESCE`) and never reconnects with a resume credential, so a lost
  socket ends it; it acknowledges the broker as a resumable phone does. It never requests a
  surface revocation, since no view shows a window.
- Phone-decoded video: the runtime's portable media reports no formats, so guests decode
  every video stream themselves.
- Display timing for frame lab and the memory-audit receipts are not collected.
