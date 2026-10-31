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
- **Device-loss policy.** The phone's driver reads `CABOOSE_GPU_ON_LOSS`: `restart`
  reports device loss when the phone goes away, `pause` holds the application until it
  returns. The launch environment sets `auto`, which the layer resolves for its process
  before the first instance reaches the driver: `restart` for a Chromium-family GPU
  process (`--type=gpu-process`: Chromium, Electron), which restarts, and for processes
  using Qt's GUI library, whose scene graph recreates its renderer; `pause` otherwise.
  An explicit `restart` or `pause` is left alone.

## Build and test

```sh
make            # libVkLayer_caboose_gpu_routing.so and test_routing
./test_routing
```

Both need a C++17 compiler and the Vulkan headers. `guest/gpu/install-live.py
--routing-layer libVkLayer_caboose_gpu_routing.so` installs the layer with its implicit
manifest, also into the Flatpak `host` GL extension. `guest/gpu/check-apps.sh` checks it
in a disposable seat container.
