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
initial native 32-bit zero client flags; the adapter sends no extra handshake.
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

For an isolated checkout whose `HEAD` is exactly the candidate Mesa revision,
`python3 guest/gpu/gfxstream/prepare_mesa.py /path/to/mesa` checks SHA-256 of
all three changed upstream files before applying the integration. It refuses an
already patched or different tree. For an isolated Linux build environment with
the required Mesa build dependencies already installed, the proposed minimal
headless configuration is:

```sh
meson setup /path/to/build /path/to/mesa -Dplatforms= -Dgallium-drivers= -Dvulkan-drivers=gfxstream -Dbuildtype=release
ninja -C /path/to/build
```

This command has not been compiled or validated, and the complete source and
dependency download sizes are not measured. No source fetch, build or install is
performed by the preparation script. Do not use the output as a working ICD.
