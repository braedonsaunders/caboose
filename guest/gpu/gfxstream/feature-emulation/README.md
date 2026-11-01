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

## Test

```sh
g++ -std=c++17 -O2 -Wall -Wextra -Werror -I MESA/include feature_emulation_test.cpp -o feature_emulation_test && ./feature_emulation_test
```

`MESA/include` is the pinned Mesa checkout's Vulkan headers (any Vulkan 1.3 headers work).
It checks the nearest border colour for float and integer colours, including OpenGL's
default, a missing colour and values that would overflow, and that only pipelines that
enable a logic operation change, through copies of their blend state that keep everything
else. It passes under AddressSanitizer and UndefinedBehaviorSanitizer.
