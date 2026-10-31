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

Only devices on a CPU implementation (`VK_PHYSICAL_DEVICE_TYPE_CPU`) created while
the socket was absent are affected. A device on the phone's GPU, or a CPU device made
while the executor existed, is left alone. Once lost, a device stays lost.

Wrapped calls: `vkQueueSubmit`, `vkQueueSubmit2(KHR)`, `vkQueuePresentKHR`,
`vkAcquireNextImage(2)KHR`, `vkWaitForFences`, `vkGetFenceStatus`,
`vkWaitSemaphores(KHR)`, `vkDeviceWaitIdle` and `vkQueueWaitIdle`. Everything else
goes straight to the next layer.

## Build and test

```sh
make                 # libVkLayer_caboose_executor_switch.so and test_executor_switch
./check.sh           # builds, then runs the test on lavapipe with the layer enabled
```

Both need a C++17 compiler and the Vulkan headers and loader. The test also needs
lavapipe (`mesa-vulkan-drivers`). The test creates a lavapipe device and renders, then
binds a socket at `CABOOSE_GFXSTREAM_SOCKET`. It requires submits and waits to report
device loss within 500 ms. It then requires a CPU device created while the socket
exists to keep working.

## Install

Install `libVkLayer_caboose_executor_switch.so` in `/usr/local/lib/caboose-gpu-live/`
and `implicit_layer.json` as
`/usr/local/share/vulkan/implicit_layer.d/caboose_executor_switch.json`. The layer is
active only in processes with `CABOOSE_GPU_EXECUTOR_SWITCH=1`, which the display
session sets with the GPU socket environment. `CABOOSE_GPU_EXECUTOR_SWITCH_DISABLE=1`
turns it off.

Chromium should run with `--disable-gpu-process-crash-limit`. Each departure and
return of the phone restarts its GPU process once, and without that flag repeated
restarts would move it to software compositing for the rest of its life.
