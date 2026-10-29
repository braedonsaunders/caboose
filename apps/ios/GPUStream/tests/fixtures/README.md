# Synthetic Vulkan cube capture

`vkcube.gfxr` contains the disposable Vulkan-Tools cube scene, its shaders and texture,
not owner applications, files, credentials or a desktop recording. The retained producer
handoff identifies `guest/gpu/check.sh` at Caboose `bf3d529`, on AMD64, running:

```sh
vkcube --wsi xcb --use_staging --c 300
```

The launcher selects the Khronos mock ICD and the GFXReconstruct capture layer with
`GFXRECON_CAPTURE_COMPRESSION_TYPE=NONE`. The producer bundle pins GFXReconstruct
`4401228c791b11fb7ea15b93795cbd1e938307c0` (Vulkan SDK 1.4.363.0, capture format 1.0.5),
Vulkan-Tools mock ICD `6fe2055cf2fa921d52a4c6a31528cfc279a6977f` and Vulkan-Profiles
`fce885d30ebafed32e03c0b199bc67d6a758887f`. The installed `vkcube` package version is
not retained; the pinned Vulkan-Tools revision describes the mock ICD, not that binary.

The handoff reports 300 frames replayed with zero errors and retains
`screenshot_frame_299.png`. That is producer evidence; the hosted workflow independently
rebuilds the player and asserts all 300 frames for transfer, resume, file-prefix and
concurrent replay. Size and SHA-256 are independently checked during staging:

- Bytes: `1710239`
- SHA-256: `90db2232be2940106b852eb8af5959872c1d2d2cc69dedccc57d981bcbaae123`

The scene and embedded shaders derive from Vulkan-Tools' cube demo, Apache-2.0:
Copyright (c) 2015-2019 The Khronos Group Inc., Valve Corporation and LunarG, Inc.;
the shader notices use 2015-2016. See `Vulkan-Tools-LICENSE.txt` and the upstream
[cube source](https://github.com/KhronosGroup/Vulkan-Tools/tree/vulkan-sdk-1.4.363.0/cube).
The capture producer GFXReconstruct is MIT; its notice is retained in
`../../../Caboose/Resources/GPU-Licenses/GFXReconstruct-LICENSE.md`.
This trace is an unmodified captured scene, renamed for this fixture.
