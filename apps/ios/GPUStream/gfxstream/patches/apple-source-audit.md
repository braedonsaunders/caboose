# Apple source boundary at gfxstream f0ce013371a68e85b5a1a1b0cf14ac9ad729f4be

The private iOS arm64 reference compiles and links the real Vulkan decoder,
framebuffer, process registry and adapter. The standalone diagnostic app also
links with the private patched MoltenVK archive. Neither result establishes
physical-phone execution. The macOS reference executes the compositor lifecycle
with that patched provider, and the independent sampling fixture checks real
Metal readback. See [diagnostics](../diagnostics/README.md).

## Compiled target boundaries

- Patches 0002 and 0003 disable GLES ownership and calls while retaining actual
  Vulkan color-buffer and compositor operations. The iOS target uses Mach thread
  CPU accounting without AppKit/IOKit desktop implementations.
- Patch 0004 uses `_NSGetExecutablePath` on iOS and preserves the macOS path.
  It rejects native surface creation before the Cocoa layer lookup. The headless
  target has no `CAMetalLayer` binding or phone swapchain presentation endpoint.
- Patches 0005 through 0008 expose actual Khronos declarations and Vulkan methods
  outside GLES guards. GL binding and post-callback readback are unsupported;
  they do not replace actual Vulkan memory readback.
- Patches 0010 and 0012 expose the existing compositor/registration and device-info
  implementations to the GLES-disabled build. No replacement GPU, fake window,
  capability result or success-returning placeholder is linked.
- Patch 0001 injects one process-owned provider before first dispatch. Its GIPA
  and export resolver must have the same lifetime and provider. The app force-loads
  one selected MoltenVK archive; arbitrary mixed-loader operation is unverified.
- Patch 0009 propagates real compositor pipeline failure. With stock MoltenVK,
  supported multi-plane immutable YCbCr layouts hit the pinned SPIRV-Cross padding
  lookup failure. Patch 0011 applies to SPIRV-Cross, not gfxstream, and fixes the
  tested scalar cases. Arrays are outside that fix.

The target retains vendored GL type headers required by the upstream interfaces;
those declarations do not implement GL rendering. Native subwindows, direct or
shared host memory mapping, external blobs and snapshots are rejected by the
experimental initializer. Generated Vulkan field unmarshalling and handle usage
are not validated for hostile input.

## Build and runtime scope

Use the exact private patch sequence in the [iOS reference](ios-reference/README.md),
then include 0009 for runtime acceptance and 0012 for the diagnostic app's real
executor identity query. Link the final executable: building static archives alone
does not detect missing backend methods. The [app recipe](../diagnostics/app/README.md)
describes the selected archive and same-provider dispatch.

The iOS SDK compilation and final link do not establish the runtime behavior of
all upstream `__APPLE__` branches. Phone initialization, Network.framework duplex
transport, driver teardown and GPU feedback remain device acceptance gates. The
public guest ICD stays gated because transparent coherent memory and other general
Vulkan semantics are unfinished. The explicit-transfer diagnostic and its pixel
oracle do not claim general game compatibility or production recovery.
