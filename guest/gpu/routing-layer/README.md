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
- **CPU implementations beside the phone.** While the phone's GPU is listed, CPU
  implementations such as lavapipe are not, so applications that pick a device by their
  own rules, or judge the computer by every device they are offered (Steam turns its GPU
  web views off on seeing llvmpipe), see only the phone. Without it they are listed again,
  last; devices made on them before the phone attached are moved by the executor switch.
- **Pipeline pre-compiling.** Steam's `fossilize_replay`, which compiles a game's recorded
  pipelines for the driver's disk cache before the game starts, does not see the phone's
  GPU: the phone's driver keeps no cache on the computer, so that work would only cross the
  network and be discarded.

## Build and test

```sh
make            # libVkLayer_caboose_gpu_routing.so and test_routing
./test_routing
```

Both need a C++17 compiler and the Vulkan headers. `guest/gpu/install-live.py
--routing-layer libVkLayer_caboose_gpu_routing.so` installs the layer with its implicit
manifest, also into the Flatpak `host` GL extension. `guest/gpu/check-apps.sh` checks it
in a disposable seat container.
