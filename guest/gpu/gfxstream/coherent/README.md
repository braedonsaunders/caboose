# Exact-byte publication core

`publication.cpp` implements the guest publication half of an exact-store journal.
It is a standalone C++17 library, not connected to Mesa or a network protocol.
The guest driver does not use it ([`../driver`](../driver/README.md) provides host-coherent memory by flushing mapped coherent allocations before each submit).

One `Publisher` belongs to one logical device. Allocation IDs increase monotonically
for that device and cannot be reused after detach. Buffer/image aliases resolve to
the same ID and allocation-relative offsets before publication. Caller-owned mapped
storage stays alive until detach returns. Application mapping operations and allocation
lifetime require the usual external synchronization.

A completion contains final values for exact, disjoint byte intervals at a GPU
synchronization cut, including stores that leave a byte unchanged. Queue serials start
at one and advance without gaps; dependencies identify earlier published cuts, including
cross-queue dependencies. A gap or unpublished dependency returns `pending` without
changing application memory. Replays, unknown allocations, overlaps, out-of-bounds
intervals and invalid cuts lose only this publisher's device. The complete transaction
is validated before any destination byte changes. The caller bounds decoded transaction
sizes before constructing these vectors; the library is not an untrusted wire parser.

The caller exposes a successful synchronization observation only after `published`.
Failed polls and timeouts are not completion packets. Host loads after that observation
see the published bytes through ordinary pointers; concurrent legal host stores to
disjoint bytes are preserved. The caller must supply synchronization between its
publication thread and the application thread receiving that observation. The mutex
protects publisher metadata; it does not make overlapping unsynchronized application
access legal. Coherent destinations are never rounded to page, word or noncoherent-atom
boundaries. Noncoherent backing storage still needs correctly aligned staging/cache
maintenance on the producer; that cannot expand guest byte ownership.

**Missing prerequisite:** neither the GPU store journal producer nor ordinary CPU
store capture/upload exists here. Exact GPU coverage includes dynamically addressed
shader writes, image stores, atomics, aliases, transfer/fill/clear and fixed-function
writes, including same-value stores. Completion values must be captured at the relevant
cut, before later writes can replace them. Events may require cuts inside a submission;
waiting for the entire submission can deadlock a host-event handshake. Dependencies
must include every ordering edge, and journal overflow or incomplete coverage must
fail closed. This library cannot validate omitted stores or omitted ordering edges.
It therefore does not establish general HOST_COHERENT support or game compatibility.

`protected_mapping.cpp` supplies a separate Linux primitive: an anonymous mapping
registered for userfaultfd write protection, with an RAII read-only snapshot cut.
Ordinary CPU stores block during that short cut and resume when protection clears.
Pages are populated before registration so protection also covers initially unused
memory on kernels without missing-PTE write protection. The primitive requires
kernel-origin faults as well as userspace faults: USER_MODE_ONLY would turn an ordinary
`read(fd, mappedPointer, size)` destination into SIGBUS while protected. Failure to
release protection closes the descriptor to unregister/wake faults and marks only
that mapping lost. The caller checks `lost()` before relying on the cut.

The cut owner must only read through the mapping while protected: publishing through
that pointer would fault the owner itself. This primitive is not composed with
`Publisher`; protected publication needs a separately controlled write path. It does
not track dirty pages, produce upload deltas, handle fork aliases, or synchronize remote
GPU snapshots. No GPU wait, transport wait or application callback is allowed inside
the cut. Holding a cut across those operations reintroduces the event deadlock.

## Build and test

In an allocated isolated build slot:

```sh
cmake -S guest/gpu/gfxstream/coherent -B /tmp/coherent-publication
cmake --build /tmp/coherent-publication --parallel 1
ctest --test-dir /tmp/coherent-publication --output-on-failure
python3 -m unittest discover -s guest/gpu/gfxstream/coherent -p 'test_*.py'
```

The C++ test uses an ordinary CPU store loop next to a published GPU byte, allocation
aliases, independent queues, dependency ordering, same-value journal entries,
transaction validation, stale IDs, replay rejection and isolated device loss. It tests
the library, not a Vulkan transport. It can also run under ThreadSanitizer.

On Linux, `protected_mapping_test` also checks a real ordinary CPU store across the
write-protection cut. Exit 77 is unsupported and is reported as skipped, never passed.
In the capped isolated Linux container, both libraries compile, the publication test
passes, and userfaultfd creation returns EPERM, so the protection runtime is unverified.
The native alias litmus control passes on lavapipe with memory flags `0x0f`.

`native-alias-litmus.patch` applies to the native Vulkan litmus source at commit
`8c2d735d`. Apply it in an isolated checkout containing that source, then use that
directory's CMake and `run.py` instructions. The variant binds two real buffers to
the same memory at a nonzero allocation offset. The GPU writes through the alias while
the CPU updates the adjacent word; a prefix guard detects allocation-offset mistakes.
Its original host event, pending fence and timeout checks remain intact. A native
control pass does not prove socket coherence.

## Rejected mechanisms

`test_counterexamples.py` executes four narrowly scoped counterexamples:

* Whole-page readback replaces a CPU byte at offset zero with stale remote data when
  the GPU writes only offset four.
* Holding page ownership until GPU completion blocks that CPU store before the same
  thread can set the event required by the GPU, forming a wait cycle.
* Snapshot differences cannot certify exact stores: no store and a store of the
  existing value have identical before/after snapshots. This alone does not disprove
  every possible diff-based coherence algorithm.
* Reading a CPU snapshot and later replacing the page loses an ordinary intervening
  CPU store, even if the remote modification is disjoint.

Linux [userfaultfd write protection](https://www.kernel.org/doc/html/v6.14/admin-guide/mm/userfaultfd.html)
tracks page faults; unprotecting a page permits subsequent writes without per-store
notifications. It does not provide an exact store journal. Vulkan's
[memory contract](https://docs.vulkan.org/spec/latest/chapters/memory.html)
distinguishes coherent host memory from explicit noncoherent flush/invalidate ranges.
Advertising coherent properties does not remove the implementation's visibility duty.

Guest CPU protection alone does not make a remote whole-allocation scan safe. A legal
application can wait for queue A's write of X and read X while independent queue B
writes disjoint Y. Scanning Y to compute a diff introduces an overlapping host read
that the application never requested, without synchronizing B. A range-aware sampler
must establish that its actual reads exclude active writes or synchronize those writes;
waiting for all queues can recreate the host-event cycle. This rejects an unprotected
whole-allocation sampler, not every synchronized diff design. No legal same-value
counterexample to a fully protected, properly ordered baseline-diff algorithm is
established here.
