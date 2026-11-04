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
the shader and upload caches a directory; without it the executor does not offer
`shader-cache` or `upload-cache`, so the computer sends every module and upload. A window bound with no extent takes `--display` (default 1920x1080), the extent of
the executor's offscreen display. SIGTERM or SIGINT drains the executor (`EXECUTOR_DRAIN`);
it exits 0 after a normal close that followed its `REVOKED`. `--sessions N` connects again
after a session ends, as the phone does, for N sessions in all, on the same runtime; each end
logs how long cleanup took and the executor's resident memory.

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

`--no-checksums` presents without captures. `--pictures DIR` writes each window's newest
captured picture to `DIR/window-ID.ppm`, at most ten a second, and logs its content
measures: the fraction of texels that repeat their left neighbour and the distinct colours
sampled (up to 64). A rendered window repeats in most texels and has a few colours; memory
never written, or read with the wrong layout, is noise (it repeats in almost none); a
picture nothing drew into has one colour.

```
CABOOSE_LINUX_EXECUTOR picture window=0x1 serial=32 868x558 format=44 content=0.965 colours=64
```

`python3 test_pictures.py` covers the measures and the PPM output.

A broker that answers the upgrade with 503 (restarting, say) is tried again for up to 10 s,
with a backoff from 0.25 s to 2 s; `python3 test_connect.py` covers it.

`--fail-binds N` answers each session's first N
surface binds with EAGAIN, as a phone whose layer for the window is not ready does. `CABOOSE_LINUX_EXECUTOR_TRACE=1` also logs each
present as it is run. SIGUSR1 prints every Python thread's stack.

[`broker_host.py`](broker_host.py) hosts a broker for it in place of the owner's display:
it starts `guest/gpu/gfxstream/caboose-gpu-broker` from this checkout with its control
socket and a fresh token, hands each TCP connection on `--listen` to the broker as the
display hands it the relayed phone, and answers the broker's compositor records. It grants
every surface bind to the window it names and every revoke, without the compositor's check
that the bound process made the window, so it belongs on disposable test computers only.
SIGUSR1 replaces its broker with a new one, as a display restart does. With `--supervised` the
broker listens on its own control socket, as it does supervised beside the display, and SIGUSR1
reconnects only the compositor, with a new epoch: the executor's session and guest streams go on.

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
PASS sync-check: 17 cases
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

## Capability-query latency

Build `guest/gpu/gfxstream/driver/sync-check/capability_queries.c` with the Vulkan headers
and `-lvulkan`, then run:

```sh
sh apps/ios/GPUStream/gfxstream/linux-executor/check-capabilities.sh IMAGE WORK DRIVER CAPABILITY_PROBE OUT
```

This creates a fresh broker/cache directory and runs four independent probe processes:
an uncached baseline (`CABOOSE_CAPABILITY_CACHE_DISABLE=1`), a cold process on the empty
cache, and two that reuse the seat cache. Each reports setup, format queries, device
creation, descriptor-support queries, records appended and time spent appending, and
whole-process time. All answer hashes must match, no process may write more than one
record per new answer, the cold process may take at most 10% plus 50 ms longer than the
baseline, and the executor must drain cleanly. These Linux measurements do not establish
phone latency.

## GL client after its executor leaves

```sh
sh apps/ios/GPUStream/gfxstream/linux-executor/check-gl-loss.sh IMAGE WORK DRIVER GL_LOSS_EXIT OUT
```

`GL_LOSS_EXIT` is `guest/gpu/gfxstream/driver/sync-check/gl_loss_exit.c` built against
libdl. It renders through Zink into an offscreen colour buffer and flushes every frame; the
check ends the executor mid-frame and requires the program to tear its context down and
exit. It prints the frames rendered and the teardown time. `KEEP_EXECUTOR=1` keeps the
executor, for the same client's teardown with its executor present. `COMPUTER=NAME` runs it in
that running computer instead of a disposable one from `IMAGE`: the check's broker is hosted
there on a port of its own, and the computer's own executor is untouched.

## Bind the phone fails

```sh
sh apps/ios/GPUStream/gfxstream/linux-executor/check-bind-retry.sh COMPUTER WORK DRIVER WAYLAND_PRESENT OUT
```

Runs against a running computer container: the executor joins its network namespace with
`--fail-binds 1` and serves it for the check's duration, replacing any executor it had, and
`caboose-display-probe` is connected as the viewer. `WAYLAND_PRESENT`
(`guest/gpu/gfxstream/driver/sync-check/wayland_present.c`) presents 30 frames through
`DRIVER`, loaded for that process only. The check requires the client to see the failed bind,
bind on a later attempt and have all 30 frames presented.

## DXVK under each negotiation

```sh
sh apps/ios/GPUStream/gfxstream/linux-executor/check-dxvk.sh COMPUTER WORK DRIVER BENCH_DIR OUT
```

Runs DXVK's d3d11 triangle (`BENCH_DIR/triangle.exe`, in the Steam Flatpak's data) through Proton
in a running computer, with `DRIVER` loaded for that process only, on the real Linux executor
under the phone's feature list (batched descriptor sets, guest-chosen set ids, completion
payloads, ordering barriers and silent success), the same with only the set ids, without the set
ids, without batched descriptor sets, and an older phone's. The broker is this checkout's
(`broker_host.py`, every bind granted) on a port of its own, so the computer's own executor and
displays are untouched. Each case requires DXVK to report the device without skipping it, a D3D11
device, a swapchain and presented frames, and no executor fault. Each case runs `SECONDS_RUNNING`
(default 45, at least 30) from its first frames and requires the frame rate of its last 15 s to
be at least half that of its first 15 s, from the broker's surface reports: a driver whose
descriptor pools never report themselves full makes DXVK allocate sets without end, and the
executor stalls once its memory is spent, after about 40 frames. The triangle runs with
`CABOOSE_READ_PROFILE=1`; each case prints the time descriptor set allocations spent waiting for
earlier replies (`drain20077`) and the waits the driver speculated (`speculated`), and the phone's
case requires guest-chosen set ids, completion payloads, ordering barriers and silent success
granted and no such allocation wait. `PORT`, `DISPLAY_ENV` (the display the triangle presents
on), `SOCKETS` (a shorter directory for the GPU sockets) and `CASES` (a subset) let it run beside
other checks on one computer; it ends only the triangle started from `BENCH_DIR`.
`APP` runs another program from `BENCH_DIR` instead, with `APP_ARGS`, and `APP_ENV` adds
environment to it: `d3d11-stress.cpp` beside the script (built with MinGW-w64, as its header
shows) is a multi-threaded load, deferred contexts on worker threads recording hundreds of draws
each with their own textures, samplers and dynamic constant buffers, per-frame texture churn, a
compute pass copied to staging buffers read back on the CPU and occlusion queries
(`APP=d3d11_stress.exe APP_ARGS="SECONDS THREADS DRAWS" APP_EXPECT=frames=`). The program runs from a
batch file that sends its output to the case's log, since Proton's launcher does not pass a
program's output through. A line starting `FAIL ` from the program, output without a match for
`APP_EXPECT` (an extended regular expression), or a `CABOOSE_LOCK_ORDER` report
(`APP_ENV=CABOOSE_LOCK_ORDER=1`) fails the case.
The release seal runs it.

## Readback cost at a phone's round-trip time

```sh
python3 apps/ios/GPUStream/gfxstream/linux-executor/readback_profile.py COMPUTER WORK RELEASE OUT \
    --steam-home DIR --exe PATH [--args '60 4 50'] [--rtt-ms 30] [--seconds 75] [--env NAME=VALUE]
```

`readback_profile.py` runs a Windows program through Proton on a private seat of
`check_chaos.py`'s (its own compositor, broker and guest driver from RELEASE, served by the
executor in WORK/build through a proxy that holds each direction's bytes for half of
`--rtt-ms`), with `--steam-home` a home of its own. PATH is inside that home's Steam Flatpak
data, for example `d3d11_stress.exe` built from `d3d11-stress.cpp`, which reads back a staging
copy every frame; `--env CABOOSE_LAZY_READBACK=0` reads every invalidated range at once. The
report gives the program's frame rates and FAIL lines, the bytes it sent and received and how
coherent memory was read back (invalidated, delivered, made lazy, filled), and its synchronous
round trips per command.

## Bind of an unmapped popup

```sh
sh apps/ios/GPUStream/gfxstream/linux-executor/check-unmapped-bind.sh COMPUTER WORK DRIVER SYNC_CHECK OUT
```

Runs against a running computer container, as the bind retry check does, with the executor
writing pictures (`--pictures`). `SYNC_CHECK`
(`guest/gpu/gfxstream/driver/sync-check/sync_check.c`) runs its `unmapped_popup` case through
`DRIVER`: an override-redirect window binds its swapchain and presents while unmapped, another
process maps it half a second later, and 30 frames follow. The check requires the compositor's
log to show the bind held and then attached to a window when the popup mapped, the executor to
retire that window's swapchain with frames presented, and the window's newest picture to have
at least half its pixels lit (the client's colours keep green half on; black fails).

## Pictures after an executor loss

```sh
sh apps/ios/GPUStream/gfxstream/linux-executor/check-loss-pixels.sh COMPUTER WORK DRIVER OUT
```

Makes a seat of its own in a running computer that has Chromium: a `caboose-display` on its
own port, token, Wayland socket, X display, runtime directory and private GPU sockets, with
`DRIVER` for the compositor and its clients, the real executor serving it with `--pictures`,
and `caboose-display-probe` as the viewer. None of the computer's own session is used.
Chromium (ANGLE on Zink, a fresh profile in the check's own home) shows a page; then the
executor and the viewer leave mid-run, as a phone that drops off does, and a new executor
and viewer connect while the compositor and Xwayland live on. A fresh Chromium must then draw
its page as well. Each phase requires a presented picture that is neither noise nor one colour
(a repeat fraction from `MIN_REPEAT`, default 0.3, to 0.999, and at least 3 colours).
Chromium runs as a Wayland client, so its frames reach the compositor as phone-resident
dma-bufs registered by the driver. `SECONDS_RUNNING` (default 25) is each Chromium's time.
The release seal runs it, in the computer DXVK's check uses.

## Executor chaos

```sh
python3 apps/ios/GPUStream/gfxstream/linux-executor/check_chaos.py COMPUTER WORK RELEASE OUT \
    [--cycles 50] [--seed N] [--steam-home DIR] [--triangle PATH]
```

Makes a seat of its own in a running computer, like the loss pixels check, running RELEASE's
own compositor, GPU broker (`CABOOSE_GPU_BROKER`) and guest driver for both architectures (a
release directory of `guest/release`), with the real executor serving it with `--pictures` and
`caboose-display-probe --children` as the viewer (it shows child windows, as the phone does).
Long-lived apps run through every cycle: an animated Chromium page and, with `--steam-home` (a
home of the check's own with a Steam Flatpak profile, never the computer owner's), Steam's CEF
client. Each cycle applies one event at a random point: the executor ends and a new one
connects (an app relaunch); the executor and the viewer end and return (a network drop, a
lock); the executor stops answering for 2-8 s (a stall); the viewer reconnects; or fresh apps
start and the executor ends 0-2 s later (during their warm-up, first bind and first present).
Then the long-lived apps must present real pictures again, and so must a freshly started
Chromium, glxgears (shown in the compositor's own images) and, with `--triangle` (DXVK's
d3d11 triangle in that home's Flatpak data), DXVK through Proton, each judged at its own
window size. The check prints one line per cycle and fails on the first cycle whose apps did
not all present; `--seed` repeats a run. The executor declares the phone's features. The seat
listens on port 14695 with X display :181; `CHAOS_PORT` and `CHAOS_X_DISPLAY` move it, so two
checks can run on one computer. The release seal runs it with 50 cycles.

