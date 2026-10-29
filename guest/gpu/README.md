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

needs git, cmake, ninja, a C++17 compiler, python3 and the X11, XCB and Wayland development
headers, and fetches, at the commits of Vulkan SDK 1.4.363.0:

- the Khronos mock ICD from Vulkan-Tools, a Vulkan driver that accepts every call and
  renders nothing (`icd.json`, `libVkICD_mock_icd.so`);
- the GFXReconstruct capture layer, which writes the stream
  (`layers/VkLayer_gfxreconstruct.*`); the client's player reads this release's format;
- the Khronos profiles layer (`layers/VkLayer_khronos_profiles.*`).

`CABOOSE_GPU_JOBS` sets the build's parallelism (default 4).

`profile.json` is an Apple GPU's capabilities as MoltenVK reports them (`vulkaninfo --json`
on an M4 Pro), without the `VK_KHR_portability_subset` extension and without the BC texture
formats, which iPhone GPUs do not sample.

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

`caboose-display-probe --gpu-save DIR` takes streams like a client and writes each to
`DIR/gpu-<id>.gfxr`; `gfxrecon-replay` from the same Vulkan SDK replays it on any GPU, for
example on a Mac with MoltenVK:

```sh
caboose-display-probe --gpu-save /tmp/streams --duration 20 --json &
caboose-gpu-run -- vkcube --wsi xcb --c 300
gfxrecon-replay --remove-unsupported -m rebind /tmp/streams/gpu-1.gfxr
```
