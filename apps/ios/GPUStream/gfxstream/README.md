# gfxstream decoder foundation (source preparation)

This directory is not a runnable decoder or an app feature. `socket_stream.*` adapts
an already connected, blocking socket to the pinned upstream `gfxstream::IOStream`.
The decoder thread owns the adapter; the caller owns the descriptor and may call
`shutdown` to interrupt it, but must not close/reuse it until the decoder exits.
The first I/O failure is retained. DMA and socket snapshot serialization are not
supported; DMA records ENOTSUP and snapshot operations abort. The caller must stop
and fail the session on an adapter error. No recovery or GPU completion is implied.
This code has not been compiled or run on Apple platforms.

Upstream source: google/gfxstream commit
`f0ce013371a68e85b5a1a1b0cf14ac9ad729f4be`, Apache-2.0. Its
`third_party/mesa/mesa.MODULE.bazel` names Android Mesa
`541c56aa3fd24027ed46ae350287d21dcd56c901` as a development dependency;
matching opcode values do not establish wire compatibility. The encoder and
serialization schema must be verified together before a session is accepted.

The upstream `host/render_thread.cpp` consumes a native uint32 client-flags
word before the stream. Its loop reads an eight-byte native opcode/total-length
header, buffers the full packet, and calls `host::vk::VkDecoder::decode` with
an IOStream, process resources, and a decoder context. Replies can be synchronous;
the transport must be full duplex. An implementation must enforce packet bounds,
reject unknown opcodes and EOF, maintain process/sequence resources, and unblock
both directions on cancellation. Socket receipt or decode progress is not GPU
completion. Device-written data must return to the guest under actual Vulkan
synchronization; snapshot object topology does not preserve those bytes.

## Integration proposal; not applied

The existing `GPUStream/CMakeLists.txt` builds the diagnostic GFXReconstruct player.
Add a separate `add_subdirectory(gfxstream)` only after the upstream target below
exists; do not add gfxstream to the replay target. The new target should link the
same process-wide nativeVulkan/MoltenVK provider as capability queries, not load
another `libvulkan.dylib` or bundle another copy. A C API should accept an owned
session context and connected duplex transport, expose readiness and a terminal
error, and offer shutdown/join; schema and ownership must be agreed with the guest
and broker before fixing signatures. No API should report completion on receipt.

At the pinned upstream revision the necessary changes are larger than removing
framework flags:

* Root `CMakeLists.txt` unconditionally defines `GFXSTREAM_ENABLE_HOST_GLES=1`.
  A Vulkan-only option must set this to 0 and restrict its scope to the new target.
* `host/CMakeLists.txt` unconditionally adds `gl` and `renderControl_dec` and
  `gfxstream_backend_static` links GL, framebuffer, renderer and desktop window
  code. Add a separate Vulkan-only target; do not replace AppKit with UIKit as a
  dummy dependency. The Apple AppKit/QuartzCore/IOSurface link at line 156 belongs
  to the existing desktop backend, not the new target.
* `host/vulkan/CMakeLists.txt` includes presentation, compositor and external-memory
  sources alongside `vk_decoder.cpp`, `vk_decoder_global_state.cpp`, generated
  snapshot code and dispatch. Its declared dependencies include decoder_common,
  emulated_textures, common_base, logging, features, host_common,
  compressed_textures, iostream, library, renderdoc, tracing, GL dispatch headers,
  Vulkan and XCB headers, cereal and native_window. This is the upstream declared
  target closure, not a verified minimal link closure. The decoder global state
  references framebuffer-related facilities; those must be separated with real
  implementations before the GL target can be removed.
* `host/vulkan/vulkan_dispatch.cpp` initializes a singleton using dynamic loader
  paths. Inject the already-owned nativeVulkan dispatch before its first use, under
  the existing initialization lock, rejecting replacement after initialization.
  Both capability queries and decoding must use that same lifetime.

An exact source/dependency hash manifest, build recipe, generated schema comparison,
real decoder wrapper, process resources, memory mapping and Apple link closure remain
unimplemented. A successful static build and live Linux compute -> physical phone ->
GPU readback -> CPU-dependent second draw are required before claiming viability.
