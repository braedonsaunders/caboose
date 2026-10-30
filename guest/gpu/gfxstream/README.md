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
