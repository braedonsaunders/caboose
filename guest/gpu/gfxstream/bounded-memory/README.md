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
| `async_allocation.h` | Which device-memory allocations may skip the round trip: plain ones that keep their heap at most half committed |
| `requirements_cache.h` | Image and buffer memory requirements by exact creation parameters, so an identical object needs no query |
| `static_query_cache.h` | Answers of physical-device format queries, which cannot change, by their exact parameters |
| `completion_feed.h` | The completion feed's wire format and the tracker of every fence and timeline semaphore the process follows |
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

Flushes, fence and command-pool resets, binds, queue submits, guest-assigned creates and
plain allocations within the heap budget do not wait for their replies. `DeferredReplies` queues them per encoder; every later read drains them
first, in stream order, and in-flight deferred commands stay under 960 KiB. A failed
reset or flush is reported on stderr. A failed bind, or a create whose handle the
device refused or renamed, invalidates the stream: the application can no longer observe
that failure, so the device is lost. Only the first encoder of a process may defer; a
second encoder turns deferral off for the process. Before the WSI surface socket names
objects or work from the stream, `drainObjects` reads replies through the last pending
create or submit and leaves later fence waits and plain results pending.

Without the completion feed, a submit that signals a fence is followed by a bounded
(250 ms) wait for that fence. When the wait's reply reports success, the fence is known
signaled until it is reset, destroyed or imported; a generation counter discards
prefetches that complete after such a change. `drainAvailable` reads only replies that
have fully arrived, so a fence status query never waits for one.

## Completion feed

With the completion feed ([docs/gpu-live.md](../../../../docs/gpu-live.md#completion-feed)),
the tracker in `completion_feed.h` follows each fence from creation (signaled or not)
through resets and watched submissions to the feed record of its serial, and each
timeline semaphore from its initial value through host signals and watched submissions.
Status queries and waits are answered from it. A signal operation the guest cannot
follow (an imported or exportable payload, a presentation-engine acquire, sparse binding,
an unwatched queue) makes that object untracked until a reset, and it is asked about on
the device stream. Device loss reaches every waiter; a closed feed hands waits back to
the device.

## Executor loss

The phone executor's streams end only when it leaves (the app goes to the background or
closes, or the phone drops off the network). The first sign of that, whether an ended
feed, an ended device stream or a failed write, marks the process's executor lost
(`markExecutorLost`). From then on every device is lost: waits and status queries
answer `VK_ERROR_DEVICE_LOST` from the tracker, and a reply read on the ended stream
reads as `VK_ERROR_DEVICE_LOST` instead of failing. Nothing waits for the phone and
nothing aborts. Deferred replies the old connection owed are dropped. A later
`vkCreateInstance` connects the process's stream again (patch 0025, and
`caboose_gfxstream_reconnect_ended` in `SocketStream.cpp`). Tracking then starts afresh,
and objects of the lost devices are asked about on the ended stream, which reports loss.

With `CABOOSE_GPU_ON_LOSS=pause` (set per application by the launcher), every call that
would report the loss first waits until the broker has a new executor: its socket
reappears, as a socket made since the loss. Then it reports `VK_ERROR_DEVICE_LOST`, so
the application recreates its device directly on the returned phone instead of moving to
another implementation meanwhile. The devices themselves cannot survive: their objects
lived on the executor that left.

## Tests

`../driver/test.sh` builds and runs every `test_*.cpp` here on Linux with the driver's
toolchain; the driver build runs it first. Each also builds by hand on any C++17 compiler:

```sh
c++ -std=c++17 -Wall -Wextra -Werror -pthread -UNDEBUG test_ranges.cpp -o /tmp/test_ranges && /tmp/test_ranges
```

The tests cover 32 MiB transfers, failure without publication, overlapping ranges,
partial maps, allocation tails, atom limits, budget pressure from concurrent callers,
command buffer staging, changed-block shadows, packet limits, deferred replies, fence
prefetch generations, guest-assigned handle checks (single and arrays), deferred submit
results, the object drain, non-blocking drains, the allocation budget, single-encoder
ownership, the requirements cache keys and lookups, and the completion tracker's fences,
timelines, stale serials, untracked objects, device loss and feed closure. They exercise
the headers, not the generated encoder or a device. `test_requirements_cache.cpp` needs
Vulkan's headers on the include path (`test.sh` uses Mesa's, or
`CABOOSE_VULKAN_INCLUDE`).
