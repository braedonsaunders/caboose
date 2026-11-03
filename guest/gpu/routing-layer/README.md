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
  `Caboose` and gfxstream's driver ID, on which applications and OpenGL on Vulkan key no
  CPU-specific workarounds. Applications that choose their rendering path once at launch
  take their GPU paths and keep them; the executor switch moves them to the phone when it
  attaches. The CPU implementation is only the fallback while no phone is attached: every
  process is treated alike, and none is kept off the phone.
- **CPU implementations beside the phone.** While the phone's GPU is listed, CPU
  implementations such as lavapipe are not, so applications that pick a device by their
  own rules, or judge the computer by every device they are offered, see only the phone.
  Without it they are listed again, last; devices made on them before the phone attached are
  moved by the executor switch.

## Dma-bufs without the phone

Lavapipe exports memory as a dma-buf through `/dev/udmabuf`, which a computer's kernel may
lack (WSL2's is built without `CONFIG_UDMABUF`); every export then fails, and with it every
GBM buffer that OpenGL on Vulkan (Zink, through Mesa's GBM backend) makes for a GPU process
such as Chromium's. On a device made on a CPU implementation presented as the GPU, memory
allocated for dma-buf export is therefore a buffer of the computer's vgem device, imported
in place of the export request, and `vkGetMemoryFdKHR` returns that buffer's dma-buf:
ordinary shared memory in linear layout, as a LINEAR GBM buffer is
([docs/gpu-buffers.md](../../../docs/gpu-buffers.md)). Memory whose export asked for other
handle types as well exports only as a dma-buf.

## Build and test

```sh
make            # libVkLayer_caboose_gpu_routing.so and test_routing
./test_routing
```

Both need a C++17 compiler and the Vulkan headers. `make check_cpu_dmabuf` builds the device
check: with lavapipe as the only driver, a vgem node (`modprobe vgem`) and this layer
enabled, it exports a dma-buf from the CPU device and requires bytes written through the
dma-buf to read back through `vkMapMemory`, printing `PASS` or `FAIL`. `make CXX=i686-linux-gnu-g++` builds
both for i386, for 32-bit applications (Debian's `g++-i686-linux-gnu`). `guest/gpu/install-live.py
--routing-layer libVkLayer_caboose_gpu_routing.so` installs the layer with its implicit
manifest, also into the Flatpak `host` GL extension; given the i386 build as well, it
installs that as `VK_LAYER_CABOOSE_gpu_routing_32` beside it and into the `host` GL32
extension. `guest/gpu/check-apps.sh` checks it
in a disposable seat container.
