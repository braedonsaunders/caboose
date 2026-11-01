# Executor switch layer

`VK_LAYER_CABOOSE_executor_switch` is an implicit Vulkan layer that moves applications
back onto the phone's GPU when it becomes available again.

While no phone GPU executor is connected (the app is in the background, closed, or off
the network), the Caboose ICD fails `vkCreateInstance` and the Vulkan loader offers the
computer's own CPU implementation (lavapipe) instead, so applications keep rendering.
When the phone returns, those applications would stay on lavapipe. This layer watches
for the executor and makes a CPU device that was created while no executor existed
report `VK_ERROR_DEVICE_LOST`. The application then recreates its device, as it does
after any device loss, and finds the phone's GPU; Chromium restarts its GPU process.

The executor counts as available while the broker's socket, named by
`CABOOSE_GFXSTREAM_SOCKET`, exists. The broker creates it once a phone executor is
ready and removes it when the executor leaves. The layer checks at most once every
100 ms, from the calls it wraps.

Only devices on a CPU implementation (`VK_PHYSICAL_DEVICE_TYPE_CPU`, or Mesa's vendor ID,
which lavapipe keeps when the routing layer presents it as a GPU) created while the socket
was absent are affected. A device on the phone's GPU, or a CPU device made while the
executor existed, is left alone. Once lost, a device stays lost.

Only processes that recover from device loss move, as `CABOOSE_GPU_ON_LOSS` says (the rule
the phone's driver applies): `auto` moves Chromium-family GPU processes (by `--type=gpu-process`,
or `--type=zygote` for one forked from a zygote, as Steam's web views are) and Qt, `pause`
moves nothing, and any other value moves every such device. A process that stays keeps its
CPU device and is recorded as running on the CPU until relaunched: once a phone executor is
available, the layer writes `placement/<pid>` beside the broker's socket (directory 0700),
one line `cpu-until-relaunch <start>` with the process's start time in clock ticks
(`/proc/<pid>/stat` field 22, which also identifies it across a Flatpak sandbox's pid
namespace), written to a temporary file and renamed. The running-apps list (`guest/scopes`)
reports it as `gpuPlacement`. The record is removed when the process destroys its last such
device.

A device this layer did not see created (a driver that reaches the device functions through
`vkGetInstanceProcAddr`, past this layer's `vkCreateDevice`) is served through the next
layer's functions, unmanaged, and reported once on stderr as `CABOOSE_GPU_EXECUTOR_SWITCH:
<call> on a device or queue this layer did not create; served unmanaged`.

Wrapped calls: `vkQueueSubmit`, `vkQueueSubmit2(KHR)`, `vkQueuePresentKHR`,
`vkAcquireNextImage(2)KHR`, `vkWaitForFences`, `vkGetFenceStatus`,
`vkWaitSemaphores(KHR)`, `vkDeviceWaitIdle` and `vkQueueWaitIdle`. Everything else
goes straight to the next layer.

`CABOOSE_GPU_EXECUTOR_SWITCH_TRACE=1` logs every instance, device and proc-address lookup
the layer handles, with dispatch keys, as `CABOOSE_GPU_EXECUTOR_SWITCH_TRACE` lines on stderr.

## Build and test

```sh
make                 # libVkLayer_caboose_executor_switch.so and test_executor_switch
./check.sh           # builds, then runs the test on lavapipe with the layer enabled
```

`test_policy` checks the decisions apart from Vulkan (`policy.h`). Both need a C++17
compiler and the Vulkan headers and loader. `make CXX=i686-linux-gnu-g++` and
`CXX=i686-linux-gnu-g++ ./check.sh` build and check the layer for i386, for 32-bit
applications, with the i386 loader and lavapipe installed. The test also needs
lavapipe (`mesa-vulkan-drivers`). The test creates a lavapipe device and renders, then
binds a socket at `CABOOSE_GFXSTREAM_SOCKET`. It requires submits and waits to report
device loss within 500 ms. It then requires a CPU device created while the socket
exists to keep working. `check.sh` runs it twice: with `CABOOSE_GPU_ON_LOSS=restart` as
above, and with `pause`, where the device must keep working and the placement record must
appear, and disappear when the device is destroyed.

## Install

Install `libVkLayer_caboose_executor_switch.so` in `/usr/local/lib/caboose-gpu-live/`
and `implicit_layer.json` as
`/usr/local/share/vulkan/implicit_layer.d/caboose_executor_switch.json`, or let
`guest/gpu/install-live.py --executor-switch` do it, which also installs an i386 build as
`VK_LAYER_CABOOSE_executor_switch_32` in `/usr/local/lib/caboose-gpu-live/i386/`. The layer is
active only in processes with `CABOOSE_GPU_EXECUTOR_SWITCH=1`, which the display
session sets with the GPU socket environment. `CABOOSE_GPU_EXECUTOR_SWITCH_DISABLE=1`
turns it off.

Chromium should run with `--disable-gpu-process-crash-limit`. Each departure and
return of the phone restarts its GPU process once, and without that flag repeated
restarts would move it to software compositing for the rest of its life.
