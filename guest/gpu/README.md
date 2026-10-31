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
| `install-live.py` | Installs the live GPU broker, with `--driver` the phone's Vulkan driver and with `--executor-switch` the executor-switch layer ([docs/gpu-live.md](../../docs/gpu-live.md#applications)) |
| `check-apps.sh`, `socket-recorder.py` | The application routing check below |
| `executor-switch/` | Implicit Vulkan layer that moves applications from lavapipe back onto the phone's GPU when its executor returns ([README](executor-switch/README.md)) |
| `background-check/` | Checks that Chromium's media plays on through the phone app's background and foreground ([README](background-check/README.md)) |

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

## Application routing check

[docs/gpu-live.md, "Applications"](../../docs/gpu-live.md#applications) describes how the
owner's display routes every toolkit to the phone's GPU. `check-apps.sh` checks it without
a phone, in a disposable container of a computer image with `vulkan-tools`, `mesa-utils`,
`gtk-4-examples` and `qml-qt6` added:

```sh
guest/display/scripts/dev.sh cargo build --release -p caboose-display -p caboose-display-probe
guest/gpu/check-apps.sh IMAGE guest/display/target/release path/to/libvulkan_gfxstream.so [OUT]
```

It installs the driver with `install-live.py --driver`, starts a private caboose-display as
the owner's seat with the private GPU sockets, watched by caboose-display-probe, and checks
its launch environment. `socket-recorder.py` then stands in for the broker on its two
sockets: it records which process opens one and closes the connection, as happens when no
phone is attached. For Vulkan on Wayland and X11 (`vkcube`), GLX (`glxgears`, `glxinfo`),
EGL on X11 (`eglinfo`), GTK 4 (`gtk4-widget-factory`), Qt Quick (`qml6`), Chromium and
Electron (Visual Studio Code) it checks that the Vulkan loader loaded the driver, that the
application's own process (Chromium's and Electron's GPU process) opened the broker's
socket, and that the application went on to draw on the computer: a window with a picture,
read through the display's control socket, or a clean exit. Logs, the socket record and the
windows' pictures stay in OUT (default `guest/gpu/out/apps`). `CABOOSE_CHECK_CPUS` and
`CABOOSE_CHECK_MEMORY` (default 4 and 4g) bound the container. Whether the phone renders
what arrives is for a trial with a phone. `bash guest/gpu/check-apps.sh --here [OUT]` runs
the same steps as root where everything is installed.
