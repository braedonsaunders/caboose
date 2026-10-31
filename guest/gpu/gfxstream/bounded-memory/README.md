# Bounded memory and reply headers

Header-only C++17 parts of the guest driver ([`../driver`](../driver/README.md)). The
driver's patches include them from `src/gfxstream/guest/vulkan_enc/caboose-bounded-memory/`;
`prepare.py` copies them there. They hold the logic of the socket transport's memory
transfer and reply handling, so it can be tested without Mesa.

| Header | What |
| --- | --- |
| `ranges.h` | The process memory budget (96 MiB) shared by shadows and staging, and the planning of flush and invalidate ranges into atom-aligned chunks of at most 64 KiB per RPC |
| `flush_packet.h` | One multi-range flush packet: up to 64 fragments under 15 × 64 KiB |
| `flush_shadow.h` | The bytes the host last received per allocation; a flush sends only the 256-byte blocks that differ, within pages the host already holds |
| `cb_staging.h` | A command buffer's local, budgeted recording stream, sent with its queue submit |
| `deferred_replies.h` | Replies the caller does not wait for, drained in order; prefetched fence waits; guest-assigned handle checks |
| `flush_timing.h`, `rpc_timing.h` | Bounded opt-in timing records (`CABOOSE_PRIVATE_GPU_FLUSH_TIMING=1`, `CABOOSE_PRIVATE_GPU_RPC_TIMING=1`) |

## Mapped memory

Socket-mode host-visible memory is a guest shadow. A flush validates every range, then
splits it into atom-aligned fragments that end at the current mapping for `WHOLE_SIZE`,
keeps only the blocks the host does not already hold, and packs them into flush packets.
The first failed packet's result is returned and no later packet is sent; a partial send
or a failed reply read invalidates the stream. An invalidate retains every chunk until
all ranges succeed, then publishes them in their original order, overlaps included;
budget exhaustion or a failed chunk publishes nothing.

## Command buffers and replies

In the synchronous socket profile, `vkBeginCommandBuffer`, `vkCmd*` and
`vkEndCommandBuffer` are recorded into a `CabooseCommandBufferStream` (64 KiB initial
chunk, at most 4 MiB per command buffer, from the process budget) without network
traffic. `vkQueueSubmit` sends every staged command buffer, secondaries first, and the
submit in one round trip. A command buffer that overflows fails its submit with
`VK_ERROR_OUT_OF_HOST_MEMORY` and sends nothing partial.

Flushes, fence and command-pool resets, binds and guest-assigned creates do not wait for
their replies. `DeferredReplies` queues them per encoder; every later read drains them
first, in stream order, and in-flight deferred commands stay under 960 KiB. A failed
reset or flush is reported on stderr. A failed bind, or a create whose handle the
device refused or renamed, invalidates the stream: the application can no longer observe
that failure, so the device is lost. Only the first encoder of a process may defer; a
second encoder turns deferral off for the process.

A submit that signals a fence is followed by a bounded (250 ms) wait for that fence.
When the wait's reply reports success, the fence is known signaled until it is reset,
destroyed or imported; a generation counter discards prefetches that complete after
such a change.

## Tests

`../driver/test.sh` builds and runs every `test_*.cpp` here on Linux with the driver's
toolchain; the driver build runs it first. Each also builds by hand on any C++17 compiler:

```sh
c++ -std=c++17 -Wall -Wextra -Werror -pthread -UNDEBUG test_ranges.cpp -o /tmp/test_ranges && /tmp/test_ranges
```

The tests cover 32 MiB transfers, failure without publication, overlapping ranges,
partial maps, allocation tails, atom limits, budget pressure from concurrent callers,
command buffer staging, changed-block shadows, packet limits, deferred replies, fence
prefetch generations, guest-assigned handle checks and single-encoder ownership. They
exercise the headers, not the generated encoder or a device.
