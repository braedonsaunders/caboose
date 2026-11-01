# gfxstream decoder foundation

This directory contains experimental source adapters. It is not connected to the
shipping player or display handshake and does not provide a working iOS virtual
GPU. The [macOS reference](macos-reference/README.md) contains a real-backend build
recipe and lifecycle fixture. The Linux reference executes the private Mesa
compute/CPU/indirect-draw oracle on lavapipe; the iOS reference links the real
backend and stock MoltenVK. The standalone diagnostic also links with the private
patched MoltenVK archive. The private physical-phone test executes the unchanged
compute/CPU/indirect-draw fixture on an Apple A20 Pro GPU and passes its independent
pixel oracle. It uses explicit non-coherent flush/invalidate and offscreen readback;
it does not establish on-screen presentation, game compatibility or a general driver.

## Pinned source

The decoder source is the Caboose fork of Google gfxstream (Apache-2.0),
[github.com/braedonsaunders/gfxstream](https://github.com/braedonsaunders/gfxstream)
(private). Its `caboose` branch is upstream
`f0ce013371a68e85b5a1a1b0cf14ac9ad729f4be` plus one commit per Caboose change, each
subject naming the change (`Caboose: 0028-completion-markers`); this document refers to
them by number. [`fork.env`](fork.env) pins the exact commit every build checks out, and
`generate-v4-profile.py --check --patched` verifies that checkout's decoder inputs by
SHA-256. A decoder change is a commit on a topic branch of the fork, merged into
`caboose`, with `fork.env` and the profile hashes updated in the same Caboose pull
request. [`provider-patches/`](provider-patches) holds the changes to other projects:
SPIRV-Cross (multi-plane padding, and MSL type names such as `sampler` or `texture2d`
treated as reserved, since Zink names variables that way and a variable named like a type
hides it from the Metal source) and MoltenVK (persistent Metal pipeline binaries), all
applied to the MoltenVK build, and MoltenVK missing-layer queries, for the layer
diagnostic. `sh provider-patches/tests/check-msl-type-names.sh /path/to/spirv-cross` checks
the type-name patch with a SPIRV-Cross command-line build: a shader whose variables, block
and member are named `sampler`, `texture2d`, `array`, `float4` and `half` must convert to
Metal source that compiles for iOS, with and without argument buffers. Its Mesa development
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

## Completion feed

`completion_feed.*` serves the completion feed described in
[gpu-live.md](../../../../docs/gpu-live.md#completion-feed). `decode_connection.cpp`
answers `COMPLETION_WATCH` and `COMPLETION_FEED` itself, before framing and decoding,
and only for a process that has a feed (`process_registry.cpp` creates one per process).
A watch submits a marker through `VkDecoderGlobalState::submitCabooseCompletionMarker`
(fork commit 0028) and returns; the feed's watcher thread waits for markers in order, and the
feed stream writes their records. Finishing a process waits for its outstanding
markers. The portable fixture uses a fake marker backend and real socket pairs:

```sh
c++ -std=c++17 -Wall -Wextra -Werror -pthread -I apps/ios/GPUStream/gfxstream \
  apps/ios/GPUStream/gfxstream/tests/completion_feed_test.cpp \
  apps/ios/GPUStream/gfxstream/completion_feed.cpp -o /tmp/caboose-completion-feed-test
/tmp/caboose-completion-feed-test
```

## Suspension

`executor_gate.*` lets the phone suspend its executor before the app leaves the foreground
([gpu-live.md](../../../../docs/gpu-live.md#suspending-an-executor)). Every decoder thread
(`decode_connection.cpp`, including media streams) registers with the gate and passes it
before each command; a thread waiting in a read, and a completion-feed stream, counts as
idle. `caboose_gpu_runtime_suspend` closes the gate, waits until every registered thread is
idle or parked before its next command, then waits every queue idle through
`VkDecoderGlobalState::waitCabooseQueuesIdle`, each under its queue lock.
`caboose_gpu_runtime_resume` opens it. A stopped process leaves the gate without running
the command it was parked before. The portable fixture runs threads against the gate:

```sh
c++ -std=c++17 -Wall -Wextra -Werror -pthread -UNDEBUG -I apps/ios/GPUStream/gfxstream \
  apps/ios/GPUStream/gfxstream/tests/executor_gate_test.cpp \
  apps/ios/GPUStream/gfxstream/executor_gate.cpp -o /tmp/caboose-executor-gate-test
/tmp/caboose-executor-gate-test
```

## Shader cache

`shader_store.{h,cpp}` is the phone's persistent SPIR-V store and the decoder's
`vkCreateShaderModule` hooks; `decode_connection.cpp` answers `SHADER_INVENTORY`
([docs/gpu-live.md](../../../../docs/gpu-live.md#shader-cache)). Keys are BLAKE3, from
[`blake3/`](blake3). `caboose_gpu_runtime_set_cache_root` selects a computer's directory,
for the store, the persistent pipeline cache and the Metal binary archive. The store's
fixture checks its keys, tokens and inventory against the vectors the guest driver is
tested with, persistence, recovery from damaged and interrupted files, eviction at open
and the per-computer roots:

```sh
for f in blake3.c blake3_dispatch.c blake3_portable.c blake3_neon.c; do
  cc -O2 -c apps/ios/GPUStream/gfxstream/blake3/$f -o /tmp/caboose-$f.o
done
c++ -std=c++17 -I apps/ios/GPUStream/gfxstream apps/ios/GPUStream/gfxstream/tests/shader_store_test.cpp \
  apps/ios/GPUStream/gfxstream/shader_store.cpp /tmp/caboose-blake3*.o -o /tmp/caboose-shader-store-test
/tmp/caboose-shader-store-test guest/gpu/gfxstream/shader-cache/vectors.json
```

`tests/pipeline_archive_check.sh` checks the MoltenVK binary archive on a Mac's GPU, with
the patched provider built by the "MoltenVK Package (macOS only)" scheme: it creates 64
distinct pipelines in four processes and requires that the archive is written, that the
process loading it finds every pipeline there, and that loading it costs no more than
Metal's own warm shader cache. On an M4 Pro a cold pipeline takes about 20 ms and a
pipeline from either cache under 0.5 ms; the archive is the cache Caboose keeps, in
Application Support, where iOS does not purge it.

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
exercised by the Linux reference. The bounded physical-phone fixture observes decoder cleanup before process termination;
this does not establish retirement of future presentation resources.

## Real backend and loader

Fork commit 0001 adds install-before-first-use injection to the
upstream dispatch singleton. Its resolver supplies actual loader export trampolines;
`vkGetInstanceProcAddr(NULL, name)` alone cannot resolve instance/device exports.
The resolver and GIPA must belong to one provider whose lifetime covers all decoder
use. Mixed capability-query/decoder execution remains unverified.

`headless_framebuffer.*` calls the real upstream framebuffer initializer with an
offscreen Vulkan compositor. It rejects native swapchain, direct/shared-memory
mapping, external blob and snapshot features. It starts upstream synchronization
and vsync threads; offscreen does not mean compositor-free. Initialization and
teardown are serialized. Decoder threads and processes must finish and cleanup
must complete before framebuffer finalization.

The adapter CMake target requires upstream backend targets. The macOS reference
retains the real GL-capable desktop backend and its AppKit dependencies. The fork's
commits provide the GLES-disabled [iOS reference](ios-reference/README.md), and
[`../../scripts/build-live-gpu.sh`](../../scripts/build-live-gpu.sh) builds and packages
the runtime from the pinned commit. Its static link includes the real framebuffer and
Vulkan decoder; GL readback remains unsupported. The [source audit](apple-source-audit.md)
describes these boundaries.

## Display times for frame lab

With `CABOOSE_FRAMELAB=1` in the app's environment, the gfxstream fork's commit
"Caboose: enable VK_GOOGLE_display_timing for frame lab" enables
`VK_GOOGLE_display_timing` on the decoder's device when the device offers it, every
native present carries its present serial as the present ID, and once a frame's present
fence completes the swapchain's past presentation timings are written to standard error
as `caboose-framelab: present window=W seq=S presented_ns=P now_ns=N`
(`framelab_timing.h`). [Frame lab](../../../../guest/framelab/README.md) turns these into
input-to-glass latency. Without the variable, device creation and presents are unchanged.

## Images of another size

A plain present whose image is not the bound window's size (a compositor buffer, an
application that keeps its own resolution after its window changed size) is placed by
`presentation_placement.h`: a window's overscan (the image lengthened along one axis)
shows its top-left part unscaled; any other size is scaled by the GPU's sampler
(`vkCmdBlitImage`, linear) to fit the window with its aspect ratio, centred, with black
where it does not reach. The placement rule has a portable fixture:

```sh
c++ -std=c++17 -Wall -Wextra -Werror -I apps/ios/GPUStream/gfxstream \
  apps/ios/GPUStream/gfxstream/tests/presentation_placement_test.cpp -o /tmp/caboose-placement-test
/tmp/caboose-placement-test
```

## Memory and proof boundary

The decoder's non-direct flush/invalidate path carries actual mapped memory bytes.
The experimental Mesa patches add explicit non-coherent shadows but keep driver
initialization disabled. Mandatory coherent memory, complete schema validation and hostile-input safety
remain unimplemented or unproven. Explicit non-coherent GPU feedback and a
CPU-dependent indirect draw pass through the private Linux receiver. No feature bits or existing game settings are changed.

The [compute acceptance fixtures](../../../../guest/gpu/emulation-check/README.md)
require actual GPU words and a CPU-dependent second draw. The physical-phone run uses seed `2956451331`, returns GPU words
`[6, 1, 0, 0, 3709642742]`, and passes all four independent pixel samples. The
32 KiB RGBA SHA-256 is
`00a06364928c2f82f290b50aa14097d4757fcbcc2cdd914b4f0e409b525bafe1`.
The guest, broker and session exit successfully, phone decoder cleanup is observed,
and owned processes, sockets and credentials are absent after cleanup. Coherent
memory, on-screen presentation and game execution remain unverified. The
macOS lifecycle fixture sends startup flags and EOF only; it is not compute or
readback evidence.

Fork commit 0009 returns pipeline creation
failure to `CompositorVk::create` after releasing its temporary shader modules.
The upstream emulation initializer treats that failure as fatal. The macOS
reference fails on the stock MoltenVK multi-plane argument-buffer conversion
error. The SPIRV-Cross provider patch resolves scalar immutable YCbCr
bindings: the private macOS driver passes real two-/three-plane sampling and
readback, and the same lifecycle fixture initializes its compositor. Descriptor
arrays retain their previous behavior. A successful exit without checking
pipeline failures is not a valid backend acceptance result.

## Phone-decoded video

The phone's half of [docs/gpu-media.md](../../../../docs/gpu-media.md). `decode_connection.cpp`
hands a stream whose first word is `CBVM` to `runMediaSession` (`media_session.*`) instead of
the Vulkan decoder, and executes each `CBVL` LATCH packet of a Vulkan stream
(`executeLatch`, `media_latch.*`) in stream order, before the command that follows it.

- `media_wire.h` parses media records and LATCH packets; `media_bitstream.*` turns units into
  what Core Media takes (H.264 and HEVC parameter sets by ID and length-prefixed pictures,
  AV1 temporal units and `av1C`, VP9 frames and `vpcC`).
- `media_session.*` answers HELLO with CAPS, opens one decoder per stream, and applies the
  FAIL and REPLAY rules. `media_registry.*` keeps each connection's latest picture per surface
  for the whole executor; a latch waits on it for at most 200 ms.
- `media_videotoolbox.mm` decodes in hardware with VideoToolbox into IOSurface-backed,
  Metal-compatible buffers in a bi-planar 4:2:0 format matching the stream (`420v`, `420f`,
  `x420`, `xf20`), so samples are copied unconverted. CAPS lists what
  `VTIsHardwareDecodeSupported` reports.
- `media_copy.mm` imports the picture's planes as MoltenVK images (`CVMetalTextureCache`,
  `VkImportMetalTextureInfoEXT`) and copies them with `vkCmdCopyImage` into the application's
  image (2-plane 4:2:0, or a single luma or chroma plane) on its queue, under its queue mutex,
  between barriers that leave it in `GENERAL`; carried pixels go through a staging buffer. A
  reclaimer thread waits for each copy's fence before releasing its resources and then the
  decoder leases, so destroying the image or device waits only for the copy itself.
- The decoder fork's `Caboose: media-latch-objects` commit adds `acquireCabooseMediaLatchObjects`, which
  validates that the queue and a 2D single-level transfer-destination image belong to the
  stream's context and returns them with instance, device, image and memory leases, and enables
  `VK_EXT_metal_objects` on host devices that have it. The guest driver must create the phone
  image of an imported dmabuf with `VK_IMAGE_USAGE_TRANSFER_DST_BIT`; images without it are
  not latched.
- Elsewhere (the Linux reference receiver) `media_platform_portable.cpp` reports no formats, so
  the guest decodes every stream locally, and latches are validated and change nothing.

Fixtures (`CABOOSE_GFXSTREAM_MEDIA_TESTS=ON` in a full configure, or directly):

```sh
cd apps/ios/GPUStream/gfxstream
c++ -std=c++17 -I. tests/media_wire_test.cpp -o /tmp/media-wire && /tmp/media-wire ../../../../guest/vaapi/tests/gpu-media-vectors.txt
c++ -std=c++17 -I. tests/media_bitstream_test.cpp media_bitstream.cpp -o /tmp/media-bitstream && /tmp/media-bitstream
c++ -std=c++17 -I. tests/media_session_test.cpp media_session.cpp media_registry.cpp executor_gate.cpp -o /tmp/media-session && /tmp/media-session
# macOS, real VideoToolbox; the AV1 and VP9 cases need tests/media_fixtures.sh (FFmpeg)
sh tests/media_fixtures.sh /tmp/media-fixtures
clang++ -std=c++17 -fobjc-arc -I. tests/media_videotoolbox_test.mm media_videotoolbox.mm media_bitstream.cpp \
  media_session.cpp media_registry.cpp executor_gate.cpp -framework VideoToolbox -framework CoreMedia -framework CoreVideo \
  -framework Foundation -o /tmp/media-vt && /tmp/media-vt /tmp/media-fixtures
# macOS, real MoltenVK (Homebrew molten-vk and vulkan-loader)
clang++ -std=c++17 -fobjc-arc -I. -I/opt/homebrew/include tests/media_copy_test.mm media_copy.mm \
  media_videotoolbox.mm media_bitstream.cpp media_session.cpp media_registry.cpp executor_gate.cpp -L/opt/homebrew/lib -lvulkan \
  -framework Metal -framework IOSurface -framework VideoToolbox -framework CoreMedia -framework CoreVideo \
  -framework Foundation -o /tmp/media-copy && /tmp/media-copy
```

The VideoToolbox fixture sends H.264 (with B-frames, video and full range), HEVC Main 10, AV1
(8- and 10-bit) and VP9 (profiles 0 and 2, with hidden alt-ref frames) through
`runMediaSession` as the guest driver sends them, waits for every serial as a latch would, and
checks the output format and luma against the source (H.264, HEVC) or FFmpeg's decode (AV1,
VP9). The copy fixture latches synthetic `420v` and `x420` pictures and a decoded H.264 frame
into 2-plane and single-plane images, and carried pixels into an odd-sized image, and reads
every copied byte back. They establish decoding and copying on Apple silicon with MoltenVK;
they do not exercise the gfxstream decoder, the accessor patch or a phone.
