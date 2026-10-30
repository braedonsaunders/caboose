# guest/gpu

`caboose-gpu-run` runs a Vulkan application with the client as its GPU: the application
renders nothing on the computer, and the client draws its window from the stream of Vulkan
calls it makes. The design, the relay in caboose-display and the protocol are in
[docs/gpu-stream.md](../../docs/gpu-stream.md).

| File | What |
| --- | --- |
| `caboose-gpu-run` | The launcher (Python 3, no dependencies) |
| `build.sh` | Builds the driver and layers it loads, from pinned sources |
| `profile.json` | The client GPU the application is shown (Khronos profiles format) |

## Building

```sh
guest/gpu/build.sh /usr/local/lib/caboose-gpu
```

needs git, cmake, ninja, a C++17 compiler, python3 with venv and its shared library (the profiles layer's build installs its Python requirements and freezes a tool with PyInstaller) and the X11, XCB (with xcb-keysyms) and Wayland development
headers, and fetches, at the commits of Vulkan SDK 1.4.363.0:

- the Khronos mock ICD from Vulkan-Tools, a Vulkan driver that accepts every call and
  renders nothing (`icd.json`, `libVkICD_mock_icd.so`);
- the GFXReconstruct capture layer, which writes the stream
  (`layers/VkLayer_gfxreconstruct.*`); the client's player reads this release's format;
- the Khronos profiles layer (`layers/VkLayer_khronos_profiles.*`).

`CABOOSE_GPU_JOBS` sets the build's parallelism (default 4).

`profile.json` is an Apple GPU's capabilities as MoltenVK reports them (`vulkaninfo --json`
on an M4 Pro), without the `VK_KHR_portability_subset` extension and without the BC texture
formats. It is a fixed profile, not a query of the connected phone; actual device support
is available through `GPUDeviceCapabilities.queryJSON()` in CabooseKit.

The images build it in their `gpu` stage. To build it for a computer of another architecture
than the machine building, and copy it out (an amd64 bundle from an arm64 Mac runs under
emulation and takes much longer):

```sh
docker build --platform linux/amd64 --target gpu --build-arg GPU_BUILD_JOBS=2 \
  -t caboose-gpu-build:amd64 -f guest/container/Dockerfile guest
id=$(docker create caboose-gpu-build:amd64)
docker cp "$id:/out/caboose-gpu" ./caboose-gpu-amd64 && docker rm "$id"
```

At run time the bundle needs Vulkan's loader (`libvulkan1`) and `libxcb-keysyms1`, which guest
components install. `caboose-gpu-run` uses the bundle only when its driver is built for the
computer's architecture, and otherwise runs the application unchanged.

`test_gpu_run.py` unit-tests the launcher (`python3 guest/gpu/test_gpu_run.py`).

## Running

On the owner's display, with its launch environment:

```sh
set -a; . /run/caboose/display.env; set +a
caboose-gpu-run --title 'Vulkan Cube' -- vkcube
```

`CABOOSE_GPU_DIR` names the directory `build.sh` installed into (default
`/usr/local/lib/caboose-gpu`). Without it, without `CABOOSE_GAME_SOCKET`, or when no
connected client renders Vulkan streams, the command runs unchanged.

## Checking

```sh
guest/display/scripts/dev.sh cargo build
guest/gpu/check.sh            # in the display's dev container; leaves guest/gpu/out/gpu-check.gfxr
```

builds the driver and layers into `guest/gpu/out/caboose-gpu` the first time (the container
gets the build dependencies, Vulkan's loader and `vkcube`), starts a private caboose-display,
and runs `vkcube --use_staging` under `caboose-gpu-run` while `caboose-display-probe
--gpu-save` takes its stream like a client. It checks that the probe gets `gpu.create` for the
window, that the window sends no pictures, and that the saved stream is a GFXReconstruct
capture. `CABOOSE_DISPLAY_CPUS`, `CABOOSE_DISPLAY_MEMORY` (default 2 and 3g) and
`CABOOSE_GPU_JOBS` (default 2) bound it. `bash guest/gpu/check.sh --here` runs the same steps
as root on a computer with everything installed.

The saved stream replays on any GPU with `gfxrecon-replay` from Vulkan SDK 1.4.363.0, for
example on a Mac with MoltenVK:

```sh
gfxrecon-replay --remove-unsupported -m rebind guest/gpu/out/gpu-check.gfxr
```

## Offscreen feature checks

[emulation-check](emulation-check/README.md) builds a bounded offscreen Vulkan renderer
and checks real image samples on a selected stock MoltenVK archive. Control, cull-distance,
direct geometry, indirect geometry and indexed-indirect geometry are reported separately;
unsupported features are not enabled or counted as passes.
