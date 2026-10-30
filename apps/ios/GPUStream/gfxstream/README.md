# gfxstream decoder foundation

This directory contains experimental source adapters. It is not connected to the
shipping player or display handshake and does not provide a working iOS virtual
GPU. The [macOS reference](macos-reference/README.md) contains a real-backend build
recipe and lifecycle fixture. The Linux reference executes the private Mesa
compute/CPU/indirect-draw oracle on lavapipe; the iOS reference links the real
backend and stock MoltenVK. Neither establishes physical-phone execution.

## Pinned source

The decoder pin is Google gfxstream
`f0ce013371a68e85b5a1a1b0cf14ac9ad729f4be` (Apache-2.0). Its Mesa development
dependency is `541c56aa3fd24027ed46ae350287d21dcd56c901`. The guest source checks
are in [guest/gpu/gfxstream](../../../../guest/gpu/gfxstream/README.md).
Matching opcode values does not establish compatible marshaling or execution.

`source-hashes.json` pins the three upstream headers used by the standalone socket
adapter syntax check. `fetch-audit-headers.py` downloads only these bounded files
and verifies their hashes. From the repository root:

```sh
python3 apps/ios/GPUStream/gfxstream/fetch-audit-headers.py /tmp/caboose-gfx-headers
clang++ -std=c++17 -fsyntax-only \
  -I /tmp/caboose-gfx-headers/host/iostream/include \
  -I /tmp/caboose-gfx-headers/host/include \
  -I /tmp/caboose-gfx-headers/common/logging/include \
  apps/ios/GPUStream/gfxstream/socket_stream.cpp
```

This check passes on macOS. It does not link or exercise the decoder.

## Socket and decoder ownership

`socket_stream.*` adapts an already connected blocking socket to the upstream
`IOStream`. The caller owns the descriptor and can use `shutdown` to interrupt
I/O, but keeps the descriptor open until the decoder returns. The first I/O error
is retained. DMA returns an unsupported error; snapshot serialization aborts.
Neither transport receipt nor decoder progress means GPU execution completed.

`decode_connection.*` consumes the upstream client-flags word, then buffers and
decodes the ordered stream using real upstream process resources and TLS. The
non-direct flush command appends resource bytes beyond the packet's declared
length. `packet_framing.*` buffers its null-`pNext` metadata and complete range
payloads before entering the decoder once. Unknown opcodes, malformed framing,
unsupported flush extensions and zero decoder progress terminate the connection.
`decoder-opcodes.inc` is generated from hash-verified pinned decoder source.
General generated field unmarshalling and object handles are not validated by
this framing check. This is not a safe public endpoint for hostile payloads.

The GPU-independent fragmentation fixture covers every prefix of a two-range
flush, with and without sequence numbers, and rejects unknown opcodes and
unsupported extensions. Build and run it separately:

```sh
c++ -std=c++17 -I apps/ios/GPUStream/gfxstream \
  apps/ios/GPUStream/gfxstream/tests/packet_framing_test.cpp \
  apps/ios/GPUStream/gfxstream/packet_framing.cpp -o /tmp/caboose-framing-test
/tmp/caboose-framing-test
```

The standalone framing fixture passes on macOS with assertions enabled. It does
not invoke the upstream decoder or validate arbitrary Vulkan command fields;
the integrated Linux receiver also exercises the decoder. Arbitrary payload and
handle validation is not established by these checks.

## Process lifetime

`process_registry.h` defines the experimental C API. A broker-owned 64-bit process
identity maps to a distinct, monotonically allocated nonzero 32-bit internal ID.
That ID keys the framebuffer resources and both upstream TLS identities; external
IDs are never truncated. All connections for a process share `ProcessResources`.

The registry exclusively owns framebuffer process registration. Callers serialize
registry destruction and framebuffer finalization against every API call. A run
call uses one socket on its calling thread. Stop revokes admission, signals guest
process death and shuts down active sockets. Finish rejects processes with active
runs; destruction waits for upstream asynchronous cleanup. A connection error is
returned to its caller and does not stop unrelated processes. The registry is linked into the iOS reference and its two-process lifecycle is
exercised by the Linux reference. Physical-device cleanup remains unverified.

## Real backend and loader

`0001-inject-vulkan-loader.patch` adds install-before-first-use injection to the
upstream dispatch singleton. Its resolver supplies actual loader export trampolines;
`vkGetInstanceProcAddr(NULL, name)` alone cannot resolve instance/device exports.
The resolver and GIPA must belong to one provider whose lifetime covers all decoder
use. The patch applies to the pin; mixed capability-query/decoder execution remains
unverified.

`headless_framebuffer.*` calls the real upstream framebuffer initializer with an
offscreen Vulkan compositor. It rejects native swapchain, direct/shared-memory
mapping, external blob and snapshot features. It starts upstream synchronization
and vsync threads; offscreen does not mean compositor-free. Initialization and
teardown are serialized. Decoder threads and processes must finish and cleanup
must complete before framebuffer finalization.

The adapter CMake target requires upstream backend targets. The macOS reference
retains the real GL-capable desktop backend and its AppKit dependencies. The
patches in `patches/` provide the GLES-disabled iOS reference. Its static link
includes the real framebuffer, Vulkan decoder and stock MoltenVK; native surfaces
and GL readback remain unsupported. The [source audit](patches/apple-source-audit.md)
describes these boundaries.

## Memory and proof boundary

The decoder's non-direct flush/invalidate path carries actual mapped memory bytes.
The experimental Mesa patches add explicit non-coherent shadows but keep driver
initialization disabled. Mandatory coherent memory, complete schema validation and hostile-input safety
remain unimplemented or unproven. Explicit non-coherent GPU feedback and a
CPU-dependent indirect draw pass through the private Linux receiver. No feature bits or existing game settings are changed.

The [compute acceptance fixtures](../../../../guest/gpu/emulation-check/README.md)
require actual GPU words and a CPU-dependent second draw. A physical-phone run of
that live path, along with lifecycle and synchronization tests, is absent. The
macOS lifecycle fixture sends startup flags and EOF only; it is not compute or
readback evidence.

`0009-propagate-compositor-pipeline-failure.patch` returns pipeline creation
failure to `CompositorVk::create` after releasing its temporary shader modules.
The upstream emulation initializer treats that failure as fatal. The macOS
reference currently fails on a MoltenVK argument-buffer shader conversion error;
a successful process exit without checking those pipeline failures is not a
valid backend acceptance result.
