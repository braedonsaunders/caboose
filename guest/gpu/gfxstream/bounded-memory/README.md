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
| `write_watch.h` | The blocks an application wrote to coherent memory since they were last sent, recorded with userfaultfd write protection (`/dev/userfaultfd`), so the flush before a submit sends only those; without the device, whole mappings. Lazy readback (below) uses the same descriptor |
| `upload_cache.h` | The phone's upload cache (docs/gpu-live.md, "Upload cache"): the inventory and allowance per executor, the pieces each device stream stored, what a whole 4096-byte piece of a range of at least 16 KiB is sent as, and its wire form; BLAKE3 and the bytes are checked against `../upload-cache/vectors.json` by `../upload-cache/test_upload_cache_vectors.cpp` |
| `cb_staging.h` | A command buffer's local, budgeted recording stream, sent with its queue submit |
| `deferred_replies.h` | Replies the caller does not wait for, read as they arrive and drained in order once 64 KiB of replies or 24 MiB of their commands are owed; prefetched fence waits; guest-assigned handle checks |
| `deferred_destroys.h` | Frees and destroys held until every queue submission sent before them has completed (Deferred frees, below) |
| `event_status.h` | Event status asked for without waiting when the completion tracker does not follow the event |
| `memory_traffic.h` | What a process moves, always counted and reported every five seconds in which anything moved: bytes its sockets sent and received, mapped memory flushed and read back by the application or the driver's coherent upkeep, and the readback ranges copies into buffers marked |
| `async_allocation.h` | Which device-memory allocations may skip the round trip: plain ones that keep their heap at most half committed |
| `requirements_cache.h` | Image and buffer memory requirements by exact creation parameters, so an identical object needs no query; kept by device identity in a file shared by every process made the same way |
| `static_query_cache.h` | Answers of physical-device format queries, which cannot change, by their exact parameters |
| `device_answers.h` | Device fingerprints and the parameters of a descriptor set layout support question, whose answers join the capability cache (Physical capability cache, below) |
| `query_results.h` | Query results without a round trip: a no-wait vkGetQueryPoolResults returns what its earlier identical request found, and resets drop stale results |
| `completion_feed.h` | The completion feed's wire format, its record reader, and the tracker of every fence, timeline semaphore, event and query the process follows, with the query values and memory captures records bring, and which waits it may report complete before their records (Speculated waits, below); the pause-on-loss waits: a paused process holds a loss until a new executor's socket appears, including a loss the phone replies with and a device stream that ends before the broker removes the old socket (`test_pause_on_loss.cpp`) |
| `gpu_writes.h` | The GPU's writes of coherent memory: up to eight disjoint spans per allocation, what an invalidate reads of them (each span its own atom-aligned range unless one range takes no more 64 KiB round trips), and the bytes a copy from an image writes in its buffer, from the texel block size |
| `completion_payloads.h` | Completion payloads with hello `0x200000` (docs/gpu-live.md, "Completion payloads"): `COMPLETION_WATCH2`, the captures in a record's payload, which query pools are captured, and `vkGetQueryPoolResults`' output written from captured values for every flag and layout |
| `guest_set_ids.h` | Set ids a batched descriptor pool chooses with hello `0x100000`: the guest handles after the pool's own, in one block of the handle counter, and the create flag that tells the decoder so (docs/gpu-live.md, "Guest-chosen set ids") |
| `silent_success.h` | Silent success with hello `0x800000` (docs/gpu-live.md, "Silent success"): its commands, the REPLY_MODE packet, which device streams have switched, feed records with payloads and the FAULT record, which is device loss |
| `handles.h` | Vulkan handles as 64-bit keys and back, without the cast through `uintptr_t` that drops the upper half of a non-dispatchable handle in 32-bit builds |
| `flush_timing.h`, `rpc_timing.h` | Bounded opt-in timing records (`CABOOSE_PRIVATE_GPU_FLUSH_TIMING=1`, `CABOOSE_PRIVATE_GPU_RPC_TIMING=1`) |

## Mapped memory

Socket-mode host-visible memory is a guest shadow. A flush validates every range, then
splits it into atom-aligned fragments that end at the current mapping for `WHOLE_SIZE`,
keeps only the blocks the host does not already hold, and packs them into flush packets.
What the host holds is known per 256-byte block (`flush_shadow.h`): from a copy of the bytes
it was sent for an allocation up to 32 MiB (48 MiB of copies in all), and otherwise from an
XXH64 hash of each whole block (16 MiB of hashes, for 512 MiB of mappings), so memory an
application rewrites with the bytes it already held is not sent again.
The first failed packet's result is returned and no later packet is sent; a partial send
or a failed reply read invalidates the stream. An invalidate retains every chunk until
all ranges succeed, then publishes them in their original order, overlaps included;
budget exhaustion or a failed chunk publishes nothing.

The host-coherent type's upkeep reads back after a wait what copies into its buffers wrote
on the GPU (`gpu_writes.h`): each command buffer and each watched submission keeps up to
eight disjoint spans per allocation, and a copy from an image marks the bytes of the copied
aspect's texel blocks. The invalidate after a wait reads the spans of the submissions that
completed, less what their completion records delivered (below), in one call: each span as
its own range, unless reading neighbours as one range takes no more 64 KiB round trips.
Every copy into a coherent buffer is marked, including copies into buffers the GPU also
reads (vertex, index, uniform, storage, indirect or transfer-source usage); the completion
record of a submission carries only the bytes of copies into buffers the GPU does not read.

## Lazy readback

What the invalidate would read back is filled on its first use instead (`write_watch.h`):
an application that reads part of a readback, or none of it, does not pay for the rest. Each
16 KiB block of watched coherent memory the invalidate would read is made lazy: its pages are
dropped, and the first access to one, a read or a write by the application or the kernel, is
a missing-page fault on the write watch's userfaultfd. The watch's thread hands it to a
filler thread, which reads the block and the lazy blocks after it, three to a round trip (the
64 KiB invalidate chunk), and installs them write-protected, so a write after the fill is
recorded as any write is. A block is read at once, as before, when it holds writes not yet
sent, when it is not wholly inside the mapping, when a completion record is being stored into
its memory, or when the process has no userfaultfd; `CABOOSE_LAZY_READBACK=0` reads every
block at once. A block made lazy again while a fill reads it is read again.

Driver code never reads or writes a lazy block while it holds a lock, since the filler takes
the encoder: an invalidate decides what is lazy with the encoder held and stores only the
rest, a flush fills the lazy blocks of what it sends first (on its own thread, with the
encoder it holds), an unmap fills the memory's lazy blocks while it is still mapped, and a
completion record stores only the parts of its capture that are not lazy (the fill reads
the phone's copy, which holds them). Missing-page faults are taken only in allocations that
have had a lazy block; a page of one never used before is installed zero and
write-protected. The watch's lock is below every lock in `lock_order.h`. A pointer into
mapped coherent memory passed as a command's own data (a pipeline cache's initial data, a
query's results) is read or written with the encoder held: one into a lazy block waits for a
fill that waits for that encoder. No driver or translation layer passes one; an application
that does runs with `CABOOSE_LAZY_READBACK=0`. The memory traffic
line counts the bytes made lazy (`lazy_bytes`) and what fills read (`lazy_filled_bytes`,
`lazy_fills`).

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
deferred commands are sent, once 256 KiB of commands or 4 KiB of replies are owed. Past
64 KiB of owed replies (at most 16384) or 24 MiB of commands the phone has not answered (eight
frames of a game that sends 3 MiB a frame), a send reads the oldest replies until half of each
is owed. The guest keeps about 80 bytes per owed reply and none of the commands. The broker
queues each stream's replies on their own, so unread replies hold back no other stream, and
ends a stream that leaves 8 MiB unread (docs/gpu-live.md, "Toward guest streams"). The command bound
keeps a burst of uploads from queueing seconds of decoding ahead of the next present; frame
pacing, not these bounds, limits the frames in flight. A failed
reset or flush is reported on stderr. A failed bind, or a create whose handle the
device refused or renamed, invalidates the stream: the application can no longer observe
that failure, so the device is lost. Only the first encoder of a process may defer; a
second encoder turns deferral off for the process. Before the WSI surface socket names
objects or work from the stream, `drainObjects` reads replies through the last pending
create or submit and leaves later fence waits and plain results pending. On a stream switched
to silent success (`silent_success.h`) the creates, allocations, binds, submits (with their
staged command buffer begins and ends), command buffer begins and ends and event operations
it lists queue no reply; the encoder then follows `drainObjects` with one round trip when such
a command went out since the last.

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

With completion payloads (hello `0x200000`,
[docs/gpu-live.md](../../../../docs/gpu-live.md#completion-payloads)) a batch's watch names
its ended occlusion and timestamp queries, as ranges, and the coherent memory its commands
write, within 256 entries and 1 MiB of captures (`completion_payloads.h`). Its record's
captures give each query its value, which `vkGetQueryPoolResults` writes in every layout the
call asks for without the device; a `WAIT` waits for the records. A reset, or a later batch
that ends the query again, drops the value. A batch an idle wait completes keeps its queries
pending until the record arrives, and `vkDestroyQueryPool` waits until every record that
captures the pool has. Captured memory is copied into the allocation's shadow under the
tracker's lock, then the flush shadow notes that the host holds those bytes and the write
watch forgets the copy, and only then does the watch complete (an idle wait meanwhile waits
for it); memory a later batch also writes, or whose batch an idle wait already completed, is
left alone. The ranges stored are delivered: the invalidate after the wait takes them
(`takeDelivered`) and does not read them from the phone. Ranges a record left out, a failed
capture, and writes without the feed or the grant are read back as before; at most 4096
allocations' delivered ranges wait to be taken, the oldest dropped first (then read back).

## Speculated waits

With `WAIT_SERIAL` (hello `0x400000`,
[docs/gpu-live.md](../../../../docs/gpu-live.md#completion-feed)) the tracker may answer a
blocking `vkWaitForFences` or `vkWaitSemaphores` before the records it waits for arrive. Each
watch is classified when it is sent. It may be speculated when the submission's batches write
no host-visible memory the guest refreshes, set, reset or wait for no event, end or reset no
query, signal no fence or semaphore whose payload is imported or exportable (nor an untracked
timeline), wait for no imported payload or untracked timeline, and its watch goes out on the
process's only device stream. A submission no watch follows hands what it waits for and
signals to the next watch of its queue, which completes behind it; a sparse bind makes that
watch unqualified. A wait is speculated when the watches it needs qualify, together with every
earlier outstanding watch of their queues and, in turn, the watches that signal the timeline
values those wait for; a timeline value that no outstanding watch signals and that is not yet
reached is something the process has not sent, and stops it. Their fences are then signaled
and their timelines reached, the queue must have had a record (the phone watches it), and at
most three speculated watches per queue may await their records.

Every command on the device stream takes the encoder lock first; there the encoder sends
`WAIT_SERIAL` for the latest speculated watch of each queue not yet held behind, before the
command. A watch whose record arrived first needs none. Another device stream's encoder waits
for the speculated records instead, since the phone knows a watch only once its stream has
been decoded that far. A record later reporting device loss makes the fence report device loss
and the timeline be asked on the device, as for any watch; values reported reached are never
lowered. Held frees still wait for the records. A new executor connection forgets what was
held. `CABOOSE_GPU_SPECULATE=0` turns speculation off.

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

## Physical capability cache

`static_query_cache.h` reuses exact format and image-format answers across processes.
A physical handle is associated with an identity only after the current executor has
answered its properties query. The identity includes the accepted protocol fingerprint
and feature mask, a broker-issued executor-session nonce, actual backend device/driver UUIDs, versions and names, pipeline-cache
UUID, architecture, and the guest driver's complete prepared-source fingerprint. A new
connection clears all handle associations. Cache records are reusable only within one
executor session; a newly connected executor gets a fresh nonce even if its advertised
identifiers match. Without the nonce extension, the cache remains process-local. The broker socket path selects storage only;
it does not establish device identity.

The seat cache is `capabilities/` beside `CABOOSE_GFXSTREAM_SOCKET`, inside the directory
already exposed to Flatpak and pressure-vessel. Without an absolute socket path, storage
uses `$XDG_CACHE_HOME/caboose-gpu` or `~/.cache/caboose-gpu`. No additional sandbox mount
is added. Format queries accept no extension chain or exactly `VkFormatProperties3`;
image-format queries require empty input and output extension chains. Other chains go
to the executor. Image answers persist only success or format-not-supported results.

Descriptor set layout support depends on the extensions and features a device was made
with, so its answers are kept in the physical device's scope under the device's
fingerprint (`device_answers.h`): two 64-bit digests of the device's creation, its queues,
its extensions in any order, its features and each pNext structure's contents as the
executor receives them. A device made with a structure the encoder does not know, a
device group or a memory report callback has no fingerprint and always asks. The question
is the layout's flags, bindings, binding flags and mutable descriptor types; a layout with
immutable samplers, or a structure of another kind, is always asked, and so is an output
chain other than the variable descriptor count. The instance version has a scope of its
own, the instance scope, in an `instance-` log: every process of the session shares the
answer one of them received, and the broker deletes the log when the next session starts.

Files are untrusted seat-user data, not an authorization source. Readers require a
private directory and regular private files owned by the effective user, and reject
symlinks in every path component. Each file is an append-only log: a header carrying the
complete identity, then records, each with its sizes, a checksum and the full scope
prefix in its key. Readers take records in order and stop at the first damaged or partial
one, so a torn tail left by a crash costs only the records after it; a file of another
format or with a damaged header supplies nothing. Checksums detect damaged records, not
malicious writes by the same user. Values contain only fixed-size capability scalars,
never pointers or object handles. Bounds are 8192 entries, 64 device scopes, 4096-byte
values and 8 MiB per file.

A process opens a scope's directory, lock and file once. Each new answer is appended as
one record under the exclusive lock, which every reader and writer takes for at most 5 ms
(holders keep it for one read or append), after adopting records other processes
appended since and cutting any torn tail; nothing already written is rewritten and there
is no fsync, since the cache is optional. While another process holds the lock, new
records wait in a 256 KiB per-scope buffer and go out with the next append, or in one
last attempt when the process exits. A forked child opens its own lock before writing.
Unsafe paths, a lock held past 5 ms, oversized or corrupt records produce cache misses.
Current connection/device identity always comes from real queries.
`CABOOSE_CAPABILITY_CACHE_DIAGNOSTICS=1` prints hits, misses, appended records and bytes,
time spent appending and contended locks at exit, and the requirements cache's
`CABOOSE_REQUIREMENTS_CACHE` line: questions answered from it, asked and kept, and asked
uncached because of the object's creation or the question's own chains;
`CABOOSE_CAPABILITY_CACHE_DISABLE=1` bypasses the cache.

`test_static_query_cache.cpp` covers fresh-process reuse, changed identities/protocols,
the instance scope, concurrent and forked writers, lock contention and held-back records, append-only write
volume, unsafe permissions, symlinks, size limits, torn tails, corrupt records and other
formats. `test_device_answers.cpp` covers fingerprints, device lifetimes and layout
questions. `../../../../apps/ios/GPUStream/gfxstream/linux-executor/check-capabilities.sh`
measures a genuinely empty cache and two fresh warmed processes, with separate format,
device-creation and descriptor-query timings. A warmed result does not measure first-use
latency.

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

With `CABOOSE_GPU_ON_LOSS=pause` every call that would report the loss first waits until the broker has a new executor: its socket
reappears, as a socket made since the loss. Then it reports `VK_ERROR_DEVICE_LOST`, so
the application recreates its device directly on the returned phone instead of moving to
another implementation meanwhile. The devices themselves cannot survive: their objects
lived on the executor that left. Any other value, the launch environment's `auto` included,
reports the loss at once, the same for every process.

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
held destroys across queues, devices and executors, speculated waits (which batches qualify,
the watches taken together, the per-queue limit, the WAIT_SERIAL each stream sends, device loss
and a new executor after them), event status replies, the blocks of
guest-chosen descriptor set ids, and completion payloads: `COMPLETION_WATCH2`'s bytes, payload
parsing (padding, unknown kinds, truncation), query results written from captured values,
and the tracker fed records through a socket, fault reports, idle waits, held pool destroys
and memory stored in a shadow included; delivered memory (`test_delivered_memory.cpp`): which
stored ranges count as delivered, notes before completion, idle waits during a store, and
what the invalidate still reads; GPU writes (`test_gpu_writes.cpp`): bounded spans,
subtraction, invalidate ranges and image copy sizes; and lazy readback
(`test_lazy_readback.cpp`): lazy-block bookkeeping, and where userfaultfd is available, fills
on a read, a write and a kernel access, blocks holding unsent writes or outside the mapping,
deliveries, settles, newer writes during a fill and the allocation's end. They exercise
the headers, not the generated encoder or a device. `test_requirements_cache.cpp` and
`test_device_answers.cpp` need Vulkan's headers on the include path (`test.sh` uses Mesa's, or
`CABOOSE_VULKAN_INCLUDE`).

`CABOOSE_CAPABILITY_CACHE_DISABLE=1` bypasses lookups and stores for a baseline run
(see "Physical capability cache" for the diagnostics).
