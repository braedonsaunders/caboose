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

## Source-only integration artifacts

`decode_connection.*` is an uncompiled upstream decoder-loop integration, not a
public API or a safe endpoint for untrusted bytes: upstream generated unmarshalling
reads packet fields without proving each field stays inside the packet. Per connection,
the wrapper creates upstream `RenderThreadInfoVk` TLS with the externally bound
nonzero context ID and shared `ProcessResources`. `VkDecoderGlobalState` must already
exist. `FrameBuffer::Impl::Create` constructs `VkEmulation` with its real `GlobalState`,
initializes its features, and then initializes that singleton; it also requires a
compositor. Factoring a real headless `GlobalState` and the paths it uses remains
necessary. Shutdown needs coordinated guest-process death notification for Vulkan
waits, not merely socket shutdown.

`0001-inject-vulkan-loader.patch` applies to the pinned upstream tree with
`git apply --unidiff-zero 0001-inject-vulkan-loader.patch`. It adds a
lock-protected, install-before-first-use injection to the real `vkDispatch` singleton.
The injected callback must resolve actual loader export trampolines, including instance
and device functions; `vkGetInstanceProcAddr(NULL, name)` returns only global commands
and is insufficient. The GIPA and resolver must belong to the same process-owned
MoltenVK provider used by capability queries. Both must outlive decoder use. Patch
application is checked; the patch is uncompiled and has not been linked to the query.

`CMakeLists.txt` defines only the adapter archive and requires the real upstream
`gfxstream-vulkan-server` and `gfxstream_host_iostream` targets to already exist.
It does not provide the missing iOS backend or exact link closure. After a suitable
pinned upstream target is constructed, set `GFXSTREAM_REPO_ROOT`, add this directory,
and link `caboose_gfxstream_connection` with the backend and shared MoltenVK provider.
The upstream target still requires framebuffer and GL-related dependencies, so this
is not a complete iOS build recipe.

A narrow adapter syntax check needs the three headers listed in `source-hashes.json`
under `host/iostream`, `host/include/render-utils`, and `common/logging`; it does not
require the decoder or linking. Given those files in `<gfxstream>`, the command is:

```sh
clang++ -std=c++17 -fsyntax-only \
  -I <gfxstream>/host/iostream/include -I <gfxstream>/host/include \
  -I <gfxstream>/common/logging/include \
  apps/ios/GPUStream/gfxstream/socket_stream.cpp
```

The pinned repository tree contains 1,938 tracked blobs totaling 61,415,876
uncompressed bytes (GitHub tree metadata); archive transfer size, external
dependency sizes, compiler memory and build output are not yet measured.
