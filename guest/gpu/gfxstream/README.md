# Gfxstream source compatibility check

`python3 guest/gpu/gfxstream/check_opcodes.py` downloads two individual source
headers at fixed revisions, checks their SHA-256 hashes, and compares the guest
Vulkan opcode names and numbers with the decoder's. It requires Python 3 and
network access. `python3 -m unittest discover -s guest/gpu/gfxstream` runs its
offline parser tests. Neither command builds or installs an ICD.

The candidate Mesa revision is `541c56aa3fd24027ed46ae350287d21dcd56c901`,
the Mesa development dependency recorded in gfxstream's
[`third_party/mesa/mesa.MODULE.bazel`](https://github.com/google/gfxstream/blob/f0ce013371a68e85b5a1a1b0cf14ac9ad729f4be/third_party/mesa/mesa.MODULE.bazel).
The decoder revision is `f0ce013371a68e85b5a1a1b0cf14ac9ad729f4be`.
All 370 guest opcode definitions have the same numeric values in the host
header; the host has 41 additional definitions. Matching opcode numbers alone
does not establish compatible marshaling, feature negotiation or execution.

At this Mesa revision, `src/gfxstream/guest/connection-manager/GfxStreamConnectionManager.cpp`
selects QEMU pipe, virtio pipe or address-space transports and writes a zero
client-flags word on connection. It has no socket transport selection.
`src/gfxstream/guest/vulkan_enc/HostVisibleMemoryVirtualization.cpp` maps
coherent memory through a `VirtGpuResourceMapping`. A network stream alone
therefore does not provide mapped-memory semantics. This directory does not
provide a runnable ICD or claim GPU remoting works.

## Experimental socket integration

`SocketStream.cpp` adapts Mesa's guest `IOStream` to an ordered, bidirectional
Unix stream socket. The socket path is selected with `CABOOSE_GFXSTREAM_SOCKET`;
access to the socket must be restricted to the intended broker and guest user.
There is one connection per Mesa thread-local connection manager. Mesa writes the
initial native 32-bit zero client flags after the private handshake described below.
The broker must bind connections to the authenticated process and session outside
the raw byte stream. Closing the peer unblocks a waiting read; no cancellation
API or bounded write timeout is provided here.

The integration is **fail-closed**: setting that variable makes Vulkan instance
setup return `VK_ERROR_INCOMPATIBLE_DRIVER`. In particular, this does not expose a
physical device with an unusable coherent memory type. Removing this gate requires
actual process association and memory visibility, including host writes before
submission and real GPU-written bytes before legal CPU observation of coherent
memory, together with proof against Vulkan synchronization requirements. The
upstream QEMU process pipe is a separate `GLProcessPipe` exchange (native int32
100, native uint64 process UID); the socket adapter does not implement it.

Once a source download is authorized, `guest/gpu/gfxstream/fetch_mesa.sh /path/to/new/mesa`
fetches a depth-one checkout at the exact candidate commit and refuses an existing
destination. Fetch size depends on the remote server and has not been measured.

For an isolated checkout whose `HEAD` is exactly the candidate Mesa revision,
`python3 guest/gpu/gfxstream/prepare_mesa.py /path/to/mesa` checks SHA-256 of
all eight changed upstream files before applying the integration. It refuses an
already patched or different tree. Then run
`python3 guest/gpu/gfxstream/fix_instance_gate.py /path/to/mesa`: the original
Mesa instance creation only treats one initialization error as failure, so this
second patch is required to reject socket mode before any encoder lookup. For an isolated Linux build environment with
the required Mesa build dependencies available, the headless configuration is:

```sh
meson setup /path/to/build /path/to/mesa --wrap-mode=nodownload -Dplatforms= -Dgallium-drivers= -Dvulkan-drivers=gfxstream -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dbuildtype=release
ninja -C /path/to/build -j2
```

The build produces `src/gfxstream/guest/vulkan/libvulkan_gfxstream.so` and a
development ICD manifest. The manifest contains the build-time absolute path;
it must be adjusted for the environment that loads the library. No source fetch,
build or install is performed by the preparation script. Socket mode remains
gated and is not a working ICD.

## Non-direct memory transfer at the pinned revisions

Mesa's generated `VkEncoder.cpp` emits a uint64 byte count and bytes after
the flush command when `usingDirectMapping()` is false, and reads the Vulkan
result, a uint64 count and bytes on invalidate. The host decoder's matching
handlers copy flush bytes into the mapped host allocation before calling Vulkan,
and return invalidated allocation bytes after calling Vulkan. Its non-direct
mode requires both `GlDirectMem` and `VirtioGpuNext` disabled. The upstream flush
packet header excludes the appended data; a streaming decoder must preserve
incomplete commands and consume the full payload.

The guest's `ResourceTracker.cpp` currently hardcodes direct mapping, and its
host-visible allocations use Goldfish or VirtGpu mappings. Its fence status and
wait paths do not synchronize a socket-backed guest shadow. The host's
`VulkanDisableCoherentMemoryAndEmulate` queue-submit branch flushes host mapped
buffer ranges; it does not return GPU-written bytes to the guest and does not
provide coherent socket semantics. It cannot replace guest synchronization.

The preparation script corrects the generated non-direct flush and invalidate
`VK_WHOLE_SIZE` calculation to end at the current mapping and sends an explicit
range length to the host, and makes upstream's range bounds check resistant to
integer overflow. These changes do not enable
non-direct mapping. The socket Vulkan gate remains in place. The patched encoder checks each invalidate reply length and invalidates the
socket on mismatch; upstream aborts the application on a truncated read.

## Experimental explicit-transfer shadow

The socket patch includes a guest-owned, aligned shadow for an ordinary
HOST_VISIBLE, non-HOST_COHERENT allocation. It allocates actual device memory
on the decoder, records the local pointer in Mesa's memory tracker, and selects
the existing non-direct flush/invalidate payload path. The shadow is released
when Mesa unregisters the device memory or destroys the device. Allocation
extension chains and custom callbacks are rejected for this experiment.

The decoder must disable `GlDirectMem`, `VirtioGpuNext`, and `ExternalBlob` so
it maps host-visible allocations and exchanges the actual contents. A client
must perform the required Vulkan barriers, fence waits, flushes and invalidates.
This experiment requires a guest-advertised non-coherent host-visible type.
The decoder can project such a type over coherent physical memory and maps the
guest allocation index back to its backing type; raw provider flags alone do
not establish the guest's memory properties. The [memory audit](private-memory-profile/README.md)
describes the feature constraints and the actual-query and byte-transfer checks.
Guest coherent allocations are rejected. The public Vulkan initialization gate
remains closed because mandatory coherent-memory semantics are incomplete.

The socket shadow records one active map range per allocation, validates map
bounds, mapped flush/invalidate bounds and non-coherent atom alignment, and
clears that range on unmap. Socket EOF or write failure shuts down the stream.
The Python range and reply fixtures are reference cases, not native tests.

## Private bounded mapped-memory calls

`prepare_bounded_memory.py PREPARED_PRIVATE_MESA` adds the indexed-only
[bounded transfer path](bounded-memory/README.md) after socket/shadow preparation.
It sends ordinary synchronous encoder calls, preserves memory-type indices, and
leaves public and direct-mapping paths unchanged. The broker reserves outbound
queue credit after socket readability and before reading local payload bytes. Idle
streams keep bytes in the kernel, hold no payload credit, and use no automatic
userspace read-ahead. FIFO admission prevents ready streams from losing their turn.
The broker releases queued credit only
after the writer drains. Cancellation of a local read releases its reservation.

## Flush and invalidate disconnection handling

The preparation patch gives the two mapped-memory entrypoints a non-aborting
read boundary: a truncated result, length or invalidate payload shuts down the
stream and returns `VK_ERROR_DEVICE_LOST`. Invalidate data is staged and copied
into mapped guest memory only after every range in the reply arrives and the
host result is successful. A failed staging allocation shuts down the stream
and reports host allocation failure. Other Vulkan calls still use upstream's
abort-on-read-failure path, and output/write failure paths are not fully
converted; the socket ICD gate remains closed.

For a later isolated Linux build, the pinned Mesa `meson.build` requires Meson
1.4.0 or later, C11 and C++17 compilers, Python 3.10 or later with Mako 0.8.0
or later, PyYAML, and `packaging` or `distutils`; its Linux libdrm baseline is 2.4.109,
and it probes zlib 1.2.3 or later. Check the actual selected configuration's
Meson log for further requirements. Use `--wrap-mode=nodownload` on the
headless setup command above to prevent unplanned dependency downloads. The
dependency availability depends on the build environment; this file does not
fetch or install dependencies.

## Private manifest and socket gate check

`python3 guest/gpu/gfxstream/make_manifest.py LIBRARY SHA256 OUTPUT 1.3.358`
checks an existing library hash and writes a private ICD manifest with its
absolute path. It refuses to replace a manifest. Resolve the library's dynamic
dependencies in the intended Linux environment before loading it.

After building the two source patches, run the private gate check with
`timeout 20 python3 guest/gpu/gfxstream/check_instance_gate.py LIBRARY PRIVATE_DIR`.
It calls the ICD's `vkCreateInstance` through `vk_icdGetInstanceProcAddr` with
a listening Unix socket, and requires `VK_ERROR_INCOMPATIBLE_DRIVER`, an
unchanged instance output and no incoming socket connection. This is a negative
gate check, not proof of working remoting.

The Linux receiver opens one process context through
`caboose_gfx_process_open(registry, process_id)` and runs each authenticated
thread stream through `caboose_gfx_process_run(registry, process_id, fd,
max_packet, max_buffer)`. The broker binds those streams to that context outside
the raw protocol and calls stop and finish for its lifetime. Each Mesa thread
sends native uint32 zero client flags; the socket path does not implement the
QEMU `GLProcessPipe` exchange. The public ICD does not yet connect the private feature agreement to its
no-render-control initialization path. It remains gated.

## Private encoder probe

`python3 guest/gpu/gfxstream/prepare_probe.py /path/to/mesa` adds a private
`caboose_gfxstream_encoder_probe` target to the already prepared Mesa tree.
Build it with `ninja -C /path/to/build -j2
    src/gfxstream/guest/vulkan/caboose_gfxstream_encoder_probe`. Invoke the
result with the receiver's private Unix socket path and an external timeout.
The probe uses Mesa's generated `VkEncoder::vkEnumerateInstanceVersion` and
prints the actual Vulkan result, returned API version and instance extension count after querying the returned properties. It does not open the
public ICD or exercise coherent memory, compute, readback or presentation.
Transport loss in this probe can still terminate its process through upstream
encoder reads; run it only as a supervised private child.

Before Mesa's native zero client flags, the socket exchanges exactly 48 bytes:
`CBGLREF1`, little-endian uint32 version 2, little-endian uint32 feature mask,
and a 32-byte SHA-256 source-tuple fingerprint. The client expects mask `0x10`;
the receiver checks its actual immutable configuration and echoes the hello
only on an exact match. Mask bits 0, 1, 2 and 3 describe seqno, direct memory,
VirtioGpuNext and ExternalBlob respectively; bit 4 selects the upstream
null-optional-strings wire format. Unknown or mismatched bits fail
before raw commands. Both peers require little-endian hosts. The fingerprint
is SHA-256 of the following exact UTF-8 bytes including the final newline:

```text
caboose-gfxstream-private-v1
gfxstream=f0ce013371a68e85b5a1a1b0cf14ac9ad729f4be
mesa=541c56aa3fd24027ed46ae350287d21dcd56c901
```

Its value is `20d3bb2e30337cabf0febb006ed102ab25ccf6d9ddbfaf624c7e68f9040969c0`.
The fingerprint identifies the source tuple; it is not proof of complete wire
compatibility. The broker authenticates and associates each connection with its
process context separately. Hardware properties must come from Vulkan queries,
not from the hello.

The private `caboose_gfxstream_buffer_probe` performs explicit shadow flush,
GPU buffer fill, fence wait and invalidate with a fresh 32-bit challenge.
`caboose_gfxstream_compute_probe` runs the existing `feedback.comp` shader,
checks the returned five words, derives new words on the CPU, flushes them,
and verifies a second GPU copy. These are diagnostics using real commands, not
proof of the public ICD, coherent memory, drawing, or phone execution. The
memory flags printed by these probes are the guest-visible types returned by the
decoder; they are not necessarily the physical backend's memory flags. Both
probes require a supervised private receiver and a strict external timeout.

`caboose_gfxstream_draw_probe` uses the same compute shader and guest shadow,
validates the five GPU-written words, changes the indirect draw arguments on the
CPU, flushes them, and submits an offscreen draw followed by image readback.
Invocation is `draw_probe SOCKET SEED COMPUTE_SPV SHADER_DIR OUTPUT_RGBA`; SEED
must be a uint32 congruent to 3 modulo 4. Its JSON output and actual RGBA bytes
are checked with the existing `guest/gpu/emulation-check/verify.py` and
`expected.json` `compute_cpu_feedback` case. This private result is not evidence
of a physical-phone executor or a working public ICD.

## Private loader diagnostic build

After `prepare_mesa.py` and `fix_instance_gate.py`,
`python3 guest/gpu/gfxstream/prepare_private_icd.py /path/to/mesa` applies a
hash-checked diagnostic patch. Build this source in a **separate** build tree
with `-Dcpp_args=-DCABOOSE_GFXSTREAM_PRIVATE_ICD` in addition to the headless
options above. Without that compile-time option, both socket gates remain in
place. The diagnostic ICD must be selected only through a private loader
manifest and must not be installed or advertised as a usable Vulkan device.

In the diagnostic build, a socket-selected instance uses the validated version 2
private handshake and does not query VirtGpu caps, render control or VirtGpu
metadata. The receiver/broker must authenticate and bind all streams from the
client to the same process context; this association is outside the raw stream.
The private mode exposes only the experimental non-coherent shadow path and is
not a conformant device: it does not provide mandatory coherent-memory semantics,
full transport-loss handling, or recovery. Test it with a supervised process,
real backend, fresh challenge and `guest/gpu/emulation-check/verify.py` rather
than using it for workloads.

## Private live broker source

`caboose-gpu-broker` is the private owner-compositor child. It accepts an
inherited Unix control socket and a per-wake token-file path, and binds the
requested local socket only after the executor reports real session readiness.
Its modules use the CGLV codec in `guest/gpu/broker/live_protocol.py`. The
compositor's routing hook is disabled by default; `/gpu` returns HTTP 503 until
it is explicitly wired and the private bridge is validated. The broker is not
installed by the component build, and the public ICD remains gated.

Run source-only checks with `python3 -m unittest discover -s
guest/gpu/gfxstream -p 'test_*.py'`. These do not establish phone execution,
coherent mapped memory, WSI presentation, or compositor integration.

A local stream EOF stops work admission for that stream. The broker retains its
process binding while draining native replies and FIN, including when the original
creator has exited; replies to an exited creator are discarded. Only the actual
PROCESS_RETIRED receipt releases the process identity. New bytes, sockets and
surface requests still require the original live peer identity.

### Private WSI handle mapping

The local WSI control records carry the encoder's host-boxed Vulkan IDs. Mesa
`internal_object` values are guest gfxstream handles, so instance, physical device,
device, queue, image, semaphore and fence fields use the pinned
`get_host_u64_Vk*` mappings before serialization. Ordinary encoder and
ResourceTracker calls still receive their guest handles. Surface and swapchain
wrapper pointers remain local; the control protocol identifies their native
objects with authenticated grants and returned swapchain IDs.

`virtual-wsi/check_host_handles.py COMPILE_DATABASE SOURCE OUT` runs from the
retained Mesa build directory, compiles the real `Resources.cpp`, and executes all
eight control-wire expressions with host IDs distinct from guest addresses.
`SOURCE` contains the WSI include files and `wire.h`; `OUT` is a new private
directory. `--expect-reject` verifies the same fixture rejects the original
pointer-cast implementation. This check uses no Vulkan loader or GPU.

The private broker accepts `CABOOSE_PRIVATE_GPU_PROGRESS=1` for diagnostic runs.
It records at most 128 surface-control direction/kind/timestamp and successful capability-extent records and one
limit marker per session; records contain no payloads or credentials. Queued
requests do not establish delivery, GPU completion or presentation.
