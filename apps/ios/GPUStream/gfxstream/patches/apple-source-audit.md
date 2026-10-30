# Apple source boundary at gfxstream f0ce013371a68e85b5a1a1b0cf14ac9ad729f4be

These are source observations, not a complete compiled or linked dependency closure.
No configure, compiler, simulator or device check was run for these patches.

`0002-headless-target-draft.patch` proposes a separate GLES-disabled framebuffer
backend, rejects native subwindows, and selects a Mach thread CPU implementation on
iOS instead of the macOS source. `0003-framebuffer-gl-guards.patch` applies after
0002: it removes GLES object ownership and GL calls only when GLES is disabled,
passes a null GL implementation to real Vulkan buffer/color-buffer paths, and
retains the upstream GLES-enabled behavior. Absence of GL means no GL lock exists;
no GPU operation is simulated. The two patches have only been applied to a private
copy of the affected source files and inspected, not compiled.

Remaining explicit desktop/Apple boundaries in the pinned tree:

- Root `CMakeLists.txt:102-104`, `host/vulkan/CMakeLists.txt:83`, and
  `host/vulkan/cereal/CMakeLists.txt:27` define both Metal and macOS MVK platform
  macros for every Apple target. iOS support and generated structure layout must be
  checked consistently across all targets before changing these definitions.
- `common/base/CMakeLists.txt:74-77,113-116` selects `system-native-mac.mm` and
  links Foundation, AppKit and IOKit on all Apple targets. That source imports
  AppKit/IOKit for desktop app-nap, dock and disk queries; the candidate iOS branch
  supplies only the real Mach CPU routine used by `System.cpp:409-420`. It does not
  provide those desktop-only functions. Their complete external symbol usage still
  needs a link audit.
- `common/base/System.cpp:35-39,342-355` includes `<libproc.h>` and calls
  `proc_pidpath` in its Apple program-directory path. Its iOS SDK availability and
  semantics are unverified; the candidate Mach CPU split does not fix this.
- `host/native_window/CMakeLists.txt:3-5` selects `native_sub_window_cocoa.mm`,
  which imports Cocoa and implements AppKit view/window operations. The candidate
  headless target retains only the native-window headers and rejects framebuffer
  subwindow operations. It provides no Cocoa window implementation.
- `host/vulkan/display_surface_vk.cpp:37-52` still calls `getMetalLayerFromView`
  when the Metal platform macro is set. That function is provided by the excluded
  Cocoa native-window implementation. The offscreen configuration does not request
  native swapchains, but an unreachable runtime path can still produce a link-time
  dependency. It must be factored or deliberately retained with a real implementation;
  a no-op surface is not a solution.
- `host/CMakeLists.txt:74-75,156` adds GL and render-control subtrees and links the
  desktop backend against AppKit, QuartzCore and IOSurface. The candidate headless
  branch bypasses that backend and keeps header targets required by Vulkan; actual
  source and static-link closure still needs measurement. `host/decoder_common` still
  compiles `glUtils.cpp` and uses vendored GL headers; this alone is not proof of a
  linked GL runtime.
- `host/vulkan/vulkan_dispatch.cpp:286-289` searches `libvulkan.dylib` on Apple.
  The separate loader-injection patch must be applied before first dispatch to bind
  the same process-owned MoltenVK provider as capability query. Dynamic macOS loader
  behavior is not a static iOS loader recipe.
- `host/vulkan/vk_common_operations.cpp`, `vk_decoder_global_state.cpp`,
  `external_memory.cpp`, and `vk_emulated_physical_device_memory.cpp` have numerous
  `__APPLE__` branches including Metal and external-memory handling. These are Apple
  branches, not evidence that each API or memory path is available on iOS; verify
  their SDK and runtime closure with the selected profile.

The decoder's generated unmarshalling is not safe against arbitrary malformed input;
the separate mapped-memory and coherent visibility gaps remain. Nothing here enables
an app feature or demonstrates GPU execution or readback.
