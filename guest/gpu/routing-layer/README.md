# GPU routing layer

`VK_LAYER_CABOOSE_gpu_routing` is an implicit Vulkan layer for the seat that renders on
the phone's GPU ([docs/gpu-live.md](../../../docs/gpu-live.md#applications)). The launch
environment enables it with `CABOOSE_GPU_ROUTING=1`; `CABOOSE_GPU_ROUTING_DISABLE=1`
turns it off.

- **Device order.** `vkEnumeratePhysicalDevices` and `vkEnumeratePhysicalDeviceGroups`
  list the phone's GPU (Apple's vendor ID, which no other Linux driver reports) first,
  then discrete, integrated, other and virtual GPUs, and CPU implementations such as
  lavapipe last, keeping the driver's order among equals. Applications that take the
  first device, and toolkits such as Zink that take the first suitable one, render on
  the phone whenever it is attached.
- **CPU implementations without the phone.** While no phone is listed, a CPU implementation
  is presented as a virtual GPU named `Caboose GPU (no phone attached)`, with driver name
  `Caboose` and gfxstream's driver ID: Steam turns its web views' GPU acceleration off for
  lavapipe's ID, and Zink keys no workarounds on gfxstream's, so it treats lavapipe as an
  ordinary GPU. Applications
  that choose their rendering path once at launch (Chromium's and Steam's GPU acceleration,
  Firefox's WebRender, Zink, which refuses CPU devices) take their GPU paths and keep them;
  the executor switch moves those that recover from device loss to the phone when it attaches.
  `fossilize_replay`, kept off the phone, sees the CPU implementation as it is; Steam's
  update window, also kept off it, sees it presented.
- **CPU implementations beside the phone.** While the phone's GPU is listed, CPU
  implementations such as lavapipe are not, so applications that pick a device by their
  own rules, or judge the computer by every device they are offered (Steam turns its GPU
  web views off on seeing llvmpipe), see only the phone. Without it they are listed again,
  last; devices made on them before the phone attached are moved by the executor switch.
- **Pipeline pre-compiling.** Steam's `fossilize_replay`, which compiles a game's recorded
  pipelines for the driver's disk cache before the game starts, does not see the phone's
  GPU: the phone's driver keeps no cache on the computer, so that work would only cross the
  network and be discarded.
- **Steam's update window.** Steam's bootstrap shows its progress window from a child
  process (`-child-update-ui`) that holds the bootstrap's single-instance pipe until it
  exits. On the phone its OpenGL context (Zink) takes seconds to tear down across the
  network, and the Steam client the bootstrap starts next then finds the pipe held, takes it
  for a running Steam and exits. The window draws on the computer's CPU instead, which is
  presented as a GPU there as for a process with no phone.

## Build and test

```sh
make            # libVkLayer_caboose_gpu_routing.so and test_routing
./test_routing
```

Both need a C++17 compiler and the Vulkan headers. `make CXX=i686-linux-gnu-g++` builds
both for i386, for 32-bit applications (Debian's `g++-i686-linux-gnu`). `guest/gpu/install-live.py
--routing-layer libVkLayer_caboose_gpu_routing.so` installs the layer with its implicit
manifest, also into the Flatpak `host` GL extension; given the i386 build as well, it
installs that as `VK_LAYER_CABOOSE_gpu_routing_32` beside it and into the `host` GL32
extension. `guest/gpu/check-apps.sh` checks it
in a disposable seat container.
