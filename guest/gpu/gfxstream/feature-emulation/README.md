# Device features the phone's GPU lacks

`feature_emulation.h` is the header-only part of patch 0035 of the Caboose Vulkan driver
(`../driver/README.md`). Zink, Mesa's OpenGL on Vulkan, needs `logicOp` and
`VK_EXT_custom_border_color` among its base requirements for desktop OpenGL. Metal, which
the phone's MoltenVK runs on, has neither. When the phone's device lacks one, the driver
offers it anyway and keeps it from the phone:

| Feature | What applications get |
| --- | --- |
| `logicOp` | Reported as supported and left out of device creation. A pipeline that enables a logic operation is created without it and writes its colour as its blend state says. OpenGL reaches logic operations only through `glLogicOp`. |
| `VK_EXT_custom_border_color` | Listed among the device's extensions, with `customBorderColors` and `customBorderColorWithoutFormat`, and left out of device creation. A sampler's custom border colour becomes the nearest of transparent black, opaque black and opaque white (by alpha, then by mean brightness). OpenGL's default border colour is transparent black, which is exact. |

A device that has either feature is used as before, without these changes. Whether the host
has `logicOp` is learned from the application's own feature query, or asked once at device
creation when it has made none.

## Direct3D 11

`d3d11_emulation.h` and `d3d11_tracker.inc` are the owned part of patch 0037. DXVK, which
runs Direct3D 11 games under Proton and Wine, refuses a device without the features below,
and Zink refuses one without `nullDescriptor`. The phone's GPU has none of them. When the
phone's device lacks one, the driver offers it and keeps it from the phone:

| Feature | What applications get |
| --- | --- |
| `geometryShader` | A graphics pipeline with a geometry stage is created from its vertex stage alone, with rasterization discarded, also when rasterizer discard is dynamic: its draws produce nothing and the device carries on. |
| `shaderCullDistance` | A shader's cull distance variables become private variables initialised to zero, in `vkCreateShaderModule` and in a stage's own `VkShaderModuleCreateInfo` (first in its chain, where DXVK puts it): writes to them are dropped, and no primitive is culled by them. A cull distance that is a member of a block is left as it is. |
| `VK_EXT_depth_clip_enable` | Listed with `depthClipEnable`. A pipeline's depth clip state becomes its depth clamp: clipping off clamps depth, clipping on clips it, as Direct3D's `DepthClipEnable` does. |
| `VK_EXT_robustness2` `nullDescriptor`, `robustBufferAccess2` | Offered with the extension itself when the phone lacks it, else alone. A null buffer, buffer view or image view in `vkUpdateDescriptorSets` or a descriptor update template, and a null vertex buffer or `vkCmdBindIndexBuffer2` index buffer, becomes an object the driver makes for each device that enables `nullDescriptor` and clears to zero at creation: a 64 KiB buffer, an R8G8B8A8 view of it, and a 2D view of a 1x1 R8G8B8A8 image in the general layout. A shader that reads a null image as another view type reads that 2D view. With `robustBufferAccess2` the phone keeps the `robustBufferAccess` the application enables. |

DXVK also requires `VK_KHR_maintenance5`, `VK_KHR_maintenance6` and
`VK_KHR_load_store_op_none`, which the phone has and the driver passes through. Binds are
sent without waiting for the phone, so a bind's `VkBindMemoryStatus` reports the result of
its call.

Patch 0038 clears the pointers of a descriptor write that its type does not use before the
encoder marshals it: DXVK points all three at one union of descriptor data, and the encoder
otherwise reads a buffer's offset as an image view.

The phone's features are learned from the application's own feature query, or asked once
at device creation; device creation keeps every offered feature, including 0035's, from the
phone.

## Test

```sh
g++ -std=c++17 -O2 -Wall -Wextra -Werror -I MESA/include feature_emulation_test.cpp -o feature_emulation_test && ./feature_emulation_test
```

`MESA/include` is the pinned Mesa checkout's Vulkan headers (any Vulkan 1.3 headers work).
It checks the nearest border colour for float and integer colours, including OpenGL's
default, a missing colour and values that would overflow, and that only pipelines that
enable a logic operation change, through copies of their blend state that keep everything
else. It passes under AddressSanitizer and UndefinedBehaviorSanitizer.

```sh
g++ -std=c++17 -O2 -Wall -Wextra -Werror -I MESA/include d3d11_emulation_test.cpp -o d3d11_emulation_test && ./d3d11_emulation_test [SPIRV_DIRECTORY]
```

runs in `../driver/test.sh` before every build. It rewrites a vertex shader's cull distance
for SPIR-V 1.0 and 1.4 and checks the result, reusing existing types, leaving modules
without cull distances alone and refusing malformed ones; adjusts pipelines for each
combination of missing features, checking copies replace only what changes; and checks the
null stand-ins, bind statuses and the pointers kept for each descriptor type. With a directory it writes the shaders it rewrites, which
`spirv-val --target-env vulkan1.3` accepts. It passes under AddressSanitizer and
UndefinedBehaviorSanitizer.
