# Bounded memory and reply headers

Header-only C++17 parts of the guest driver ([`../driver`](../driver/README.md)). The
driver's patches include them from `src/gfxstream/guest/vulkan_enc/caboose-bounded-memory/`;
`prepare.py` copies them there. They hold the logic of the socket transport's memory
transfer and reply handling, so it can be tested without Mesa.

| Header | What |
| --- | --- |
| `ranges.h` | The process memory budget (96 MiB) shared by shadows and staging, and the planning of flush and invalidate ranges into atom-aligned chunks of at most 64 KiB per RPC |
| `flush_packet.h` | One multi-range flush packet: up to 64 fragments under 15 × 64 KiB; an upload cache piece takes a fragment of its own |
| `flush_shadow.h` | The bytes the host last received per allocation; a flush sends only the 256-byte blocks that differ among the blocks the host holds whole, and every block the device wrote is sent again |
| `poll_stall.h` | Status polls that never change: an object polled for 10 seconds without change is named in `CABOOSE_GPU_POLL_STALLED`, again every minute |
| `write_watch.h` | The blocks an application wrote to coherent memory since they were last sent, recorded with userfaultfd write protection (`/dev/userfaultfd`), so the flush before a submit sends only those; without the device, whole mappings |
| `upload_cache.h` | The phone's upload cache (docs/gpu-live.md, "Upload cache"): the inventory and allowance per executor, the pieces each device stream stored, what a whole 4096-byte piece of a range of at least 16 KiB is sent as, and its wire form; BLAKE3 and the bytes are checked against `../upload-cache/vectors.json` by `../upload-cache/test_upload_cache_vectors.cpp` |
| `cb_staging.h` | A command buffer's local, budgeted recording stream, sent with its queue submit |
| `deferred_replies.h` | Replies the caller does not wait for, read as they arrive and drained in order once 6 MiB of commands or 64 KiB of their replies are owed; prefetched fence waits; guest-assigned handle checks |
| `deferred_destroys.h` | Frees and destroys held until every queue submission sent before them has completed (Deferred frees, below) |
| `event_status.h` | Event status asked for without waiting when the completion tracker does not follow the event |
| `async_allocation.h` | Which device-memory allocations may skip the round trip: plain ones that keep their heap at most half committed |
| `requirements_cache.h` | Image and buffer memory requirements by exact creation parameters, so an identical object needs no query; kept by device identity in a file shared by every process made the same way |
| `static_query_cache.h` | Answers of physical-device format queries, which cannot change, by their exact parameters |
| `query_results.h` | Query results without a round trip: a no-wait vkGetQueryPoolResults returns what its earlier identical request found, and resets drop stale results |
| `completion_feed.h` | The completion feed's wire format and the tracker of every fence, timeline semaphore, event and query the process follows; the pause-on-loss waits: a paused process holds a loss until a new executor's socket appears, including a loss the phone replies with and a device stream that ends before the broker removes the old socket (`test_pause_on_loss.cpp`) |
| `handles.h` | Vulkan handles as 64-bit keys and back, without the cast through `uintptr_t` that drops the upper half of a non-dispatchable handle in 32-bit builds |
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
first, in stream order. Replies that have fully arrived are read without blocking as more
deferred commands are sent, once 256 KiB of commands or 4 KiB of replies are owed. Only past
64 MiB of commands (more than the broker takes ahead of the phone) or 64 KiB of owed
replies does a send wait, for the oldest half. A failed
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

Events and queries are followed too. An event is known from its creation, host sets and
resets, and the completed batches whose command buffers set or reset it. A query's result is
available once the batch whose command buffer ended it (a query end or a timestamp write)
has completed, and unavailable from a reset until then; a batch that sets or resets an event,
or ends or resets a query, is watched even without a fence. `vkGetEventStatus` is then
answered locally, and `vkGetQueryPoolResults` without `WAIT` (nor availability or partial
results) returns `VK_NOT_READY` without a request while the result cannot be there. A range
polled then is asked for with the next queue submission after its batch has completed; that
request, or one a poll sends once the result is available, is read later with the deferred
replies, and the next identical call returns it (`query_results.h`). An event the tracker does not follow is
asked about the same way (`event_status.h`): a poll returns what the latest answered request
found, and no poll waits for the phone.

## Deferred frees

With the completion feed, `vkFreeMemory`, `vkDestroyBuffer`, `vkDestroyImage`,
`vkDestroyImageView` and `vkDestroyBufferView`, and the parked views an image or buffer
destroy releases, are held until every queue submission the process sent before them has
completed on the phone. Work still running on any queue of the device can keep an object
resident there (a descriptor set bound in an argument buffer, a chunk-sized buffer under
suballocations), and releasing it under that work loses the device. A held destroy carries
the latest watch serial; it is sent once no watch up to that serial is outstanding on any
queue. A queue whose latest submissions no watch follows (they signal nothing and touch no
event, query or coherent memory) gets a `COMPLETION_WATCH` when a destroy is held, so every
submission is covered. Held destroys are sent, in order, after submits and idle waits and
before allocations; a destroyed device's go before it. Those held under an executor that has
left are never sent. A free releases its share of the asynchronous allocation budget
(`async_allocation.h`) when it is sent, so an allocation decided meanwhile still sees it. At
most 8192 are held; past that a destroy waits up to a second for the oldest.

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

With `CABOOSE_GPU_ON_LOSS=pause`, or `auto` (the launch environment's value) in a process
that is neither a Chromium-family GPU process nor a Qt application, every call that
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
ownership, the requirements cache keys and lookups, the completion tracker's fences,
timelines, events, queries, stale serials, untracked objects, device loss and feed closure,
held destroys across queues, devices and executors, and event status replies. They exercise
the headers, not the generated encoder or a device. `test_requirements_cache.cpp` needs
Vulkan's headers on the include path (`test.sh` uses Mesa's, or
`CABOOSE_VULKAN_INCLUDE`).
