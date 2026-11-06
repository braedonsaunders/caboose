# Live GPU transport

Its bounded codec is implemented in
`guest/gpu/broker/live_protocol.py` and CabooseKit’s `LiveGPUEnvelope`, with byte-exact
vectors in `live-vectors.json` and `live-surface-vectors.json`.
Applications reach it through their launch environment, as [Applications](#applications)
describes.

## Connection and authority

The host route is `/v1/gpu`, without query parameters, using the exact WebSocket
subprotocol `caboose.gpu.live.v1`. It relays to `/gpu` on the computer's GPU broker
service (port 14602), one broker shared by both seats ([Seats](#seats)), where the guest runs
it (the host connects only once a listener answers there); otherwise to the owner's display
service `/gpu` on its existing port, whose own broker serves the owner's seat alone. The phone
never names a seat or a destination. There is one executor per computer and one GPU route.
WebSocket messages are binary, uncompressed, at most 256 KiB. The broker queues at most 8 MiB
in 256 messages toward the phone ([Priority toward the phone](#priority-toward-the-phone)).
Vulkan replies use this connection independently of media.

The host sends the current per-wake display token as upstream `Authorization:
Bearer …`, together with host-created `X-Caboose-GPU-Executor` UUID and
`X-Caboose-GPU-Computer` runtime identity. It does not forward a phone bearer,
Origin, or client-provided identity headers. The guest validates the per-wake
token before interpreting those identities. A successful HTTP upgrade means
authenticated pending admission, not decoder readiness. Waiting for a decoder
handshake before sending HTTP 101 would deadlock this connection.

One pending or active executor is admitted per computer. The relay forwards a
normal WebSocket close with code 1000 and waits at most one second for the other
endpoint before terminating it. Errors and abnormal closes terminate both ends
without manufacturing a normal-close receipt. Closing both relay sockets
releases the host transport reservation; it does not prove native
resource retirement. Guest admission remains fenced until the old generation's
native cleanup is complete. Local applications are bound through kernel Unix
peer credentials, a retained peer pidfd and process start time, not a claimed
PID. Those credentials identify the socket creator; transferring the descriptor
does not authenticate a new writer.

## Envelope

All integers are little-endian. UUID bytes are in standard UUID byte order.
Without the optional compressed transport, WebSocket message boundaries have no framing meaning. A receiver retains at most
one partial envelope and applies bounded admission before retaining delivered
messages. Each direction starts at sequence 1 and increments across the entire
connection, not independently per stream.

| Offset | Width | Field |
| --- | --- | --- |
| 0 | 4 | ASCII `CGLV` |
| 4 | 2 | Envelope version, 1 |
| 6 | 2 | Kind |
| 8 | 4 | Payload bytes, at most 262080 |
| 12 | 4 | Reserved, zero |
| 16 | 16 | Nonzero authenticated executor UUID |
| 32 | 8 | Nonzero generation |
| 40 | 8 | Broker-assigned process ID, or zero for session scope |
| 48 | 8 | Broker-assigned stream ID, or zero for process/session scope |
| 56 | 8 | Nonzero directional sequence |

Unknown kinds, nonzero reserved bits, changed executor/generation, sequence gaps
or duplicates, invalid scopes, oversized payloads and truncated EOF terminate the
connection. There is no resynchronization scan. These checks do not validate
arbitrary generated Vulkan fields, object handles or application synchronization.

### Priority toward the phone

The broker queues what it sends the phone in two lanes, together at most 8 MiB (as much as
the resume window holds) in 256 messages; a local stream reads its next 64 KiB only once that
much of the queue is free. The acquires, acquire cancellations and indexed presents
(SWAPCHAIN_ACQUIRE, SWAPCHAIN_CANCEL_ACQUIRE, SWAPCHAIN_PRESENT, SWAPCHAIN_PRESENT_ORDERED) a
process sends on its surface socket, and WebSocket pongs, take the control lane. Everything
else takes the bulk lane: DATA, FIN, process and stream openings and stops, session messages,
the close, the other surface controls, and the surface controls the broker sends itself
(buffer presents, retirements, the cancellation of a departed process's acquire). The writer
takes the control lane first, but never past a bulk message queued before it that is not DATA:
a control overtakes only DATA. Each lane is first in, first out, so every stream's DATA and
FIN reach the phone in the order the broker read them, every surface's controls keep their
order across both lanes, and a control follows any opening, end, stop or other surface control
queued before it. An envelope's sequence is written as it leaves the queue, so the phone
receives consecutive sequences, and zstd records continue their stream in that order. A
control queued while the resume window is full is the first message written once it opens.

What the control lane overtakes is only DATA, and no order between a process's device stream
and its surface socket is carried by the transport anyway: the broker reads each local socket
on its own, so a surface message could already reach the phone before device-stream bytes the
process wrote earlier. The process orders the two itself, and that is what the control lane
relies on. Before an acquire or an unordered present names objects or work of its device
stream, the process reads that stream's replies through its last create or submit
(`drainObjects`), so the phone has decoded them. An ordered present names an ORDER mark, and
the phone runs it only once the decoder has passed the mark ([Ordered
presents](#ordered-presents)). An acquire made ahead of the application names a semaphore
created before the swapchain was mapped, behind such a drain, and reuses it only after the
hand-off that waited on it has completed.

| Kind | Name | Scope | Payload |
| --- | --- | --- | --- |
| 1 | SESSION | Session | 48-byte private feature hello |
| 2 | SESSION_READY | Session | Exact matching hello |
| 3 | PROCESS_OPEN | Process | Empty |
| 4 | PROCESS_READY | Process | Empty |
| 5 | STREAM_OPEN | Stream | Empty |
| 6 | STREAM_READY | Stream | Empty |
| 7 | DATA | Stream | Nonempty raw bytes |
| 8 | FIN | Stream | Empty, directional EOF |
| 9 | PROCESS_STOP | Process | Empty |
| 10 | PROCESS_RETIRED | Process | Empty |
| 11 | REVOKE | Session | Empty |
| 12 | REVOKED | Session | Empty |
| 13 | EXECUTOR_DRAIN | Session | Empty |
| 16 | SURFACE_BIND | Process | 64 bytes |
| 17 | SURFACE_BOUND | Process | 56 bytes |
| 18 | SURFACE_QUERY | Process | 56 bytes |
| 19 | SURFACE_CAPS | Process | 64-byte failure or bounded capability lists |
| 20 | PRESENT | Process | 96 bytes plus at most 64 eight-byte waits |
| 21 | PRESENT_RESULT | Process | 72 bytes |
| 22 | SOURCE_RELEASED | Process | 48 bytes |
| 23 | SURFACE_RETIRE | Process | 40 bytes |
| 24 | SURFACE_RETIRED | Process | 56 bytes |
| 37 | TRANSPORT_CONFIG | Session | Algorithm u32 = 1 or 2, maximum decoded record u32 = 65600; algorithm 2 adds window log u32 and reserved u32 zero |
| 38 | TRANSPORT_READY | Session | The configuration; algorithm 2's with the window log the phone takes |
| 39 | SWAPCHAIN_PRESENT_ORDERED | Process | Kind 34's fields plus a device-stream order mark |
| 40 | ACK | Session, sequence 0 | Highest contiguous sequence received u64 |
| 41 | RESUME | Session, sequence 0 | Highest contiguous sequence received u64, reserved u64 zero, 16-byte nonzero nonce |
| 42 | EXECUTOR_SUSPEND | Session | Empty, phone to broker |
| 43 | QUIESCE | Session | Empty, broker to phone |
| 44 | QUIESCED | Session | Empty, phone to broker |
| 45 | EXECUTOR_RESUME | Session | Mode u32 (0 in place), reserved u32 zero; phone to broker |

Kinds 14 and 15 are reserved and rejected.

Session scope has zero process and stream IDs. Process scope has a nonzero
process and zero stream ID; stream scope has both nonzero. Process and stream IDs
are monotonic and never reused within a generation. The initial admission limits
are 16 active processes and 64 active streams; retirement releases capacity without
resetting identity counters.

### Toward guest streams

The broker never waits for a guest process to read before it reads the phone's next message.
Each local stream's socket has its own writer queue, written in order as the socket takes
bytes, so the replies and the end of one stream never wait behind another's, nor behind
another process's. That matters because a process reads its device stream lazily: it leaves
deferred replies unread while it works ([Completion feed](#completion-feed) records arrive on
another stream meanwhile), and a broker that waited on that stream would stop reading the
phone, so the feed records the process is waiting for would never arrive. A stream's FIN is
written after every byte queued before it. Surface sockets have their own queues too, at most
64 replies and 8 MiB; a surface socket past either, or with a reply unread for 5 s, is ended
alone.

The protocol has no per-stream credit toward the guest, so the broker cannot hold back the
phone for one stream, and holding back the whole connection for one stream would stall every
stream behind it; it bounds what it holds instead. One stream holds at most 8 MiB its process has
not read (as much as the resume window holds), all streams together at most 32 MiB. A message
past either bound ends one stream: the one it is for, or, past the total, the stream holding
the most. The broker drops what it holds for that stream and shuts its socket, so the process
reads the end of its device stream and loses its device; the phone's further bytes for it are
discarded until its FIN, as for a process that exited. Replies a process leaves unread for a
second after its stream's FIN are dropped the same way. The session and every other stream
go on. A process that reads its replies never comes near the bound: it keeps its owed replies
within 64 KiB ([bounded memory](../guest/gpu/gfxstream/bounded-memory/README.md)).

### Compressed commands

The indexed v4 broker compresses what it sends the phone when the phone declares
`zstd-stream` (algorithm 2) and the computer has libzstd 1.5, or, failing that, with
`CABOOSE_PRIVATE_GPU_DEFLATE=1` (algorithm 1). It sends TRANSPORT_CONFIG with the
algorithm after SESSION_READY and waits for the exact TRANSPORT_READY before publishing
local sockets or reporting compositor readiness. Duplicate, unsolicited or late
negotiation terminates the session. The Vulkan hello and native runtime mode do
not change. Older modes never compress; without either, transport stays raw.

After this exchange, each broker-to-phone WebSocket message contains exactly one
whole CGLV envelope or one CGLZ record. CGLZ uses a 16-byte little-endian header:
`magic[4]="CGLZ", version:u16=1, algorithm:u16, decodedBytes:u32,
compressedBytes:u32`, the algorithm the session negotiated, followed by compressed bytes.
In both, `decodedBytes` is 65 through 65600, `compressedBytes` exactly matches the
remaining message, and the decoded bytes are exactly one CGLV DATA envelope with 1 through
65536 payload bytes, whose identity, scope and sequence pass through the existing decoder
unchanged. Control envelopes stay raw CGLV.

Algorithm 2's configuration is 16 bytes: algorithm 2, 65600, a window log and a reserved
zero. The broker's TRANSPORT_CONFIG names the largest window it compresses with (log 27,
128 MiB); TRANSPORT_READY repeats the configuration with the window the phone takes, from
log 20 up to the offer, and the broker compresses with that window. The decoder holds the
whole window, so the phone takes it by the memory the system leaves its app
(`os_proc_available_memory`): 128 MiB (log 27) with at least 3 GiB available, 64 MiB (26) with
at least 512 MiB, else 8 MiB (23), and logs `CABOOSE_GPU_COMPRESSION algorithm=2 window_log=N`. A window beyond 8 MiB is compressed with zstd's long-distance
matching, which finds content that repeats far back, such as an image uploaded again a minute
later.

With algorithm 2 every DATA envelope is a record, and the records of a session are one
zstd stream (zstd 1.5 format, no dictionary, no checksum, the negotiated window), started at
TRANSPORT_READY: the broker compresses each envelope in sequence order and
flushes the stream at the end of each record, so a record decodes completely given every
earlier record of the session, and none can be skipped. The phone feeds its decoder exactly
the records it accepts, in sequence order, each once; a record must yield exactly
`decodedBytes` and leave the decoder at the start of the next block (expecting a 3-byte
block header and holding none of it). A record may be larger than its envelope. The
broker retains and resends records as the exact bytes it wrote, and the phone discards
unread whatever arrives before the broker's RESUME, so after a splice the next record
continues the stream where the phone's decoder stands. `guest/gpu/broker/live_zstd.py`
binds the computer's libzstd; `live-zstd-stream-vectors.json` holds a record sequence and
malformed first records.

With algorithm 1 each record is one independent raw RFC 1951 DEFLATE stream, with no
shared dictionary, and the whole record must be smaller than its decoded bytes; ordinary
DATA is used when compression does not reduce size. Control messages, concatenated
envelopes, truncated streams, extra bytes after the compressed data, and output-length
mismatches are rejected under either algorithm. Phone replies remain raw, and WebSocket
extensions remain forbidden on both hops.

Phone-to-broker replies can concatenate a ready FIFO prefix of raw CGLV envelopes
into one WebSocket message, preserving envelope sequences and stream order. The
first available reply sends immediately; batching adds no timer. A batch contains
at most 64 admitted records and 256 KiB. The outbound 1 MiB budget retains all
original byte/count permits and reserves the concatenation buffer before allocation,
keeping both charges until send completion. Insufficient scratch capacity sends
the first record alone. Closing discards pending records but retains in-flight
charges until their completion callback. These are logical retained-byte limits,
not physical allocator or RSS limits.

The broker charges the original uncompressed WebSocket frame, or an algorithm 2 record
larger than it, until its send completes. Before queuing compressed work, the phone reserves the wire size plus
the declared decoded size plus one byte for bounded inflate output. The decoder
separately retains its existing single bounded partial envelope. Admission uses
the existing 1 MiB/64-message ingress limit; no limit is raised. Inflation runs
only on the serial consumer worker, uses an overflow
sentinel, and requires exact output and complete input consumption. Malformed
input closes the session and follows ordinary native revocation and cleanup;
it cannot establish successful retirement. These transformations preserve command
bytes and do not infer memory contents, GPU completion, or frame display timing.

The retained version-3 live hello is ASCII `CBGLREF1`, little-endian version 3,
mask `0x30`, and the
32-byte source tuple fingerprint
`20d3bb2e30337cabf0febb006ed102ab25ccf6d9ddbfaf624c7e68f9040969c0`.
Bit 4 requires actual `VulkanNullOptionalStrings`; bit 5 requires the explicit
private virtual-WSI mode. The other bits remain zero. The source fingerprint pins
the base sources, not general schema compatibility or hostile-input safety.
The separate version-2 diagnostic does not negotiate virtual WSI and is rejected
by this live contract. The versioned native start symbol prevents a retained
non-WSI framework from claiming this mode.

The indexed version-4 wire uses version 4 and mask `0x70`, with the same source
fingerprint and additional bit 6 requiring actual indexed acquisition. Its exact
SESSION and SESSION_READY records are in `live-v4-vectors.json`; the version-3
records remain unchanged in `live-vectors.json`. Endpoint mode selection requires
an exact match, not a subset of bits. `caboose_gpu_live_start_v4` strongly links the
actual indexed runtime; a version-3 artifact cannot authorize version 4. These
wire fixtures do not initialize a provider or activate the driver.

## Guest capability-cache session scope

The local broker hello supports optional bit `0x20000`. It is a guest/broker feature,
not a phone decoder feature. When granted, the 48-byte hello reply is immediately
followed by a 32-byte random nonce, generated once for that broker executor session.
Every guest process in the session receives the same nonce; a new executor session gets
a new nonce even if its supplied executor UUID and generation repeat. Old guests receive
only the original reply. A new guest that falls back to an older broker keeps physical
capability answers process-local. Completion-feed connections omit this bit and keep
their existing framing. The trailer is consumed locally and is never forwarded to the
native decoder.

The guest scopes its exact format/image-format cache to this nonce, negotiated protocol
and features, queried backend/device/driver properties, and guest source fingerprint.
Consequently a replacement executor or backend cannot reuse a previous session's file. The
instance scope also keeps the session's instance extensions, physical device count and the
identity of its one GPU, so a process starting later in the session asks none of its
capability answers again (bounded-memory README, Physical capability cache).
The seat-owned files contain bounded scalar query results, not authorization data;
[`static_query_cache.h`](../guest/gpu/gfxstream/bounded-memory/README.md#physical-capability-cache)
describes validation and the existing sandbox mount used for storage.

## Phone capabilities and local features

The phone app names the capabilities of its native decoder in the
`X-Caboose-GPU-Features` request header, a comma-separated list. The host forwards
only known names, lowercased and sorted: `guest-handles`, `guest-handle-arrays`,
`completion-feed`, `ordered-present`, `guest-images`, `guest-query-pools`,
`shader-cache`, `executor-resume`, `zstd-stream` ([Compressed commands](#compressed-commands)),
`upload-cache` ([Upload cache](#upload-cache)), `guest-buffer-views`,
`batched-descriptor-sets`, `batched-descriptor-sets-inline`
([Batched descriptor sets](#batched-descriptor-sets)), `guest-set-ids`
([Guest-chosen set ids](#guest-chosen-set-ids)), `completion-payloads`
([Completion payloads](#completion-payloads)), `wait-serial` ([Completion feed](#completion-feed)),
`silent-success` ([Silent success](#silent-success)), `one-way-start`
([One-way start](#one-way-start)) and `executor-stats` ([Executor stats](#executor-stats)). A host
that does not know a name drops it, so the phone must be paired with a host at least as new as its
features.
The broker reads them from the authenticated upgrade request.

A local process on the indexed v4 path may offer optional features in its 48-byte
hello by setting bits above the required mask `0x70`: `0x80` (guest-assigned handles),
`0x100` (guest-assigned descriptor sets and command buffers; requires `0x80`) and
`0x200` (completion feed), `0x400` (ordered presents), `0x800` (guest-owned swapchain
images), `0x1000` (guest-assigned query pools; requires `0x80`) and `0x2000` (shader
cache), `0x8000` (upload cache), `0x10000` (guest-assigned buffer views; requires `0x80`),
`0x40000` (batched descriptor sets without inline uniform blocks), `0x80000` (batched
descriptor sets with inline uniform blocks), `0x100000` (guest-chosen set ids; requires `0x80`),
`0x200000` (completion payloads; requires `0x200`), `0x400000` (WAIT_SERIAL; requires `0x200`),
`0x800000` (silent success; requires `0x80` and `0x200`) and `0x1000000` (one-way start;
requires `0x80`, `0x200` and `0x800000`).
The broker replies with the required mask plus the offered bits whose capability
the phone declared (`guest-handles`, `guest-handle-arrays`, `completion-feed`,
`ordered-present`, `guest-images`, `guest-query-pools`, `shader-cache`, `upload-cache`,
`guest-buffer-views`, `batched-descriptor-sets`, `batched-descriptor-sets-inline`, `guest-set-ids`,
`completion-payloads`, `wait-serial`, `silent-success`, `one-way-start` respectively); it drops
`0x100`, `0x1000`, `0x10000`, `0x100000`, `0x800000` and `0x1000000` when it does not grant `0x80`,
`0x200000`, `0x400000`, `0x800000` and `0x1000000` when it does not grant `0x200`, and `0x1000000`
when it does not grant `0x800000`. An offer with unknown bits, one of those without `0x80`,
`0x200000`, `0x400000`, `0x800000` or `0x1000000` without `0x200`, `0x1000000` without `0x800000`,
or any other difference from the v4 hello closes the local connection. A process falls back to offering fewer features.

### Feature negotiation

Every name above and its hello bit are listed once, in
[`guest/gpu/gfxstream/gpu-features.json`](../guest/gpu/gfxstream/gpu-features.json), with the
features each requires and whether the phone app declares it. A name a component does not
know is dropped there without an error, and the phone then runs without it, so
`gpu_features.py check REPO` (run by `test_feature_lists.py`, by the host's
`gpu-relay.test.ts` and by `guest/release/stage-gpu-stack.sh`) fails when the phone app's list,
the Linux executor's, the DXVK check's, the host relay's, the broker's admission and
`HELLO_FEATURES` (with its requirements) or the driver's first offer differ from it.

At run time each stage says what it passed on:

- The host relay forwards the phone's whole well-formed list beside the known names, as
  `X-Caboose-GPU-Declared`, and logs `CABOOSE_GPU_RELAY_FEATURES dropped=… forwarded=…` when it
  drops a name.
- The broker logs one line per executor session:
  `CABOOSE_GPU_SESSION_FEATURES source=relay|direct declared=… forwarded=… received=… bits=…`
  (`declared` is `-` from a relay that does not report it; `source=direct` is a session that
  did not come through the relay, such as a seat check's executor).
- Each process logs the hello it was granted, `CABOOSE_GPU_HELLO features=0x…`.

A release carries `/usr/local/libexec/caboose-gpu/expected-features.json`, written by
`gpu_features.py expected`: the phone's declared names and the hello a process of this release
is granted with them. `check_session_features.py COMPUTER` compares the last relayed session
in the owner display's log with it, and names the stage that dropped each missing feature:
the phone app, the host relay, the broker's admission, or the hello. It exits 1 on a
mismatch, 2 when there is no relayed session yet.

### Batched descriptor sets

With `0x80000` the process allocates and writes descriptor sets itself, inline uniform blocks
included. A descriptor pool asks the phone once, at creation and without waiting, for the ids
of its sets (`vkCollectDescriptorPoolIdsGOOGLE`), unless it chose them itself
([Guest-chosen set ids](#guest-chosen-set-ids)); allocations, frees and writes then stay in
the process. Just before a submit, on the same stream, one
`vkQueueCommitDescriptorSetUpdatesGOOGLE` carries every set the submit's command buffers bind
that was allocated or written since: the pending allocations (pool, layout and set id) and the
writes, one descriptor each, and for an inline uniform block every byte of the binding written
so far, as one write with its `VkWriteDescriptorSetInlineUniformBlock`. The decoder's v4
allow-list admits this one queue command besides the submits, sparse binds and
`vkQueueWaitIdle`; every other `vkQueue*` command stays forbidden. The phone app and the Linux
executor declare `batched-descriptor-sets-inline`; their devices offer inline uniform blocks,
which DXVK requires, and make every pool's set ids when the pool is created, for every process.
`0x40000` is the same without inline uniform blocks, which an older driver offers; nothing
declares `batched-descriptor-sets` now, so such a driver allocates and writes sets per call.
Each executor connection decides whether the process batches: a process that outlives its
executor (the compositor) follows the next one, batched or not, and the objects it made under
the last are lost with it.

### Guest-chosen set ids

With `0x100000` (granted with `0x80`) and batched descriptor sets, a process chooses its pools'
set ids and never asks for them. Creating a pool of `maxSets` sets takes `1 + maxSets`
consecutive guest-assigned handles in one block of the 32-bit counter: the pool is the first,
`P`, and its set ids are `P+1` through `P+maxSets`. Its `VkDescriptorPoolCreateInfo.flags`
carries `0x40000000`, outside every flag Vulkan defines, which says so; the decoder takes the
flag off before the create reaches the driver and registers those ids for the pool instead of
minting them. A flagged pool without batched descriptor sets, under a handle the guest did not
assign, or whose ids would run past the counter is an invalid command, as is an id already in
use. The flag is per pool because the decoder does not see a process's hello: an executor that
does not grant the feature leaves new pools unflagged, asking for their ids, and pools that
were made either way coexist. A pool whose handle and ids do not fit one block (`maxSets` of
`0xFFFFFFFF`) asks for its ids.

### Guest-assigned handles

With `0x80`, a create command carries an output handle the process chose, with `0xCA`
in its top byte, a 24-bit per-process tag and a 32-bit counter. The decoder registers
the object under that value instead of minting one, so the process continues without
waiting for the reply; it reads the reply later and treats a refused or renamed handle
as device loss. A graphics or compute pipeline the phone cannot compile under such handles
is not refused: the decoder registers a stand-in under the same handle, with the same
layout, render pass and dynamic state, that runs a trivial vertex stage with rasterization
discarded (or an empty kernel), so that pipeline's draws and dispatches do nothing, and the
phone prints `CABOOSE_GPU_STANDIN kind=… handle=… index=… error=…` beside the provider's
compile error. Pipeline libraries are refused as before. Under guest-assigned handles the
phone compiles pipelines off the decode thread, on a lane of two workers that holds at most
256 pipelines: the decoder registers each handle at once and decodes on, and the first
command that names the pipeline (a bind, a destroy, a library or base pipeline of another
create) waits for that compile alone. Destroying a shader module, pipeline layout, render
pass, descriptor set layout, sampler, pipeline cache, pipeline or the device first waits for
the device's compiles. The reply is then success; a pipeline that could neither compile nor
be stood in for ends the connection at its first use, which the process sees as device
loss. A create whose result the process reads back (creation feedback, or
fail-on-compile-required) and a create past the lane's bound compile in place. This covers device memory, fences, semaphores, buffers, images and
views, samplers, shader modules, pipeline caches and layouts, descriptor set layouts
and pools, command pools, render passes, framebuffers and pipelines; with `0x10000`, buffer
views too. With `0x100` it
also covers descriptor sets and command buffers: the decoder registers the i-th created
object under the i-th guest handle. The guest counts each descriptor pool's sets and
descriptors (a layout's full count for each binding, as the batched path does) and returns
`VK_ERROR_OUT_OF_POOL_MEMORY` for an allocation the pool cannot hold, as a device does:
applications such as DXVK move to another pool, and recycle a full one, only on that result.
An allocation the guest counted as fitting does not fail on the phone: when the pool still
reports `VK_ERROR_OUT_OF_POOL_MEMORY` or `VK_ERROR_FRAGMENTED_POOL` (MoltenVK returns the
latter for pools that free individual sets), the decoder allocates the sets from an overflow
pool it creates with the same flags and sizes. Overflow pools are reset and destroyed with
their application pool, and their sets are freed back to them.

The decoder also takes guest-assigned handles for the dispatchable objects that start a
process's Vulkan: `vkCreateInstance` and `vkCreateDevice` register the instance or device
under the handle the process wrote as their output. Physical devices and queues exist
before the process names them, so `vkEnumeratePhysicalDevices` (the i-th physical device under
the i-th handle of the array) and `vkGetDeviceQueue`/`vkGetDeviceQueue2` register the object
under the process's handle the first time it names one; naming it again with the same handle,
or with a value without `0xCA` in its top byte, reads it back, and naming it with another
guest-assigned handle ends the stream as invalid input. Physical devices enumerated again
keep their handles. A decoder that has these offers `one-way-start`
([One-way start](#one-way-start)); an older one mints these handles whatever the process wrote.

### Invalid commands

Nothing a process sends ends the phone's runtime or another process. A command the
decoder cannot run as sent is refused unrun: one naming a handle the decoder does not
hold (a create that failed, an object already destroyed) or naming it as another kind
of object, a guest-assigned handle already in use, an unknown structure, a malformed
stream. The phone prints `CABOOSE_GPU_GUEST_FAULT context=… opcode=… reason="…"` and
`CABOOSE_GPU_PROCESS_LOST`, and ends every stream of that process. The process reads
the end as the loss of its device (`CABOOSE_GPU_EXECUTOR_LOST`): its calls return
`VK_ERROR_DEVICE_LOST` from then on, and an application that recovers creates a new
instance. Its objects are released when it retires, as for any process; every other
process on the executor goes on. The broker treats a process socket that ends while
replies are pending as closed, so that loss never ends the executor session.

### Completion feed

With `0x200`, the process opens one more local stream with the same hello. After the
client-flags word it sends a single `COMPLETION_FEED` command and nothing else. Both
completion commands use the ordinary 8-byte packet header, little-endian:

| Command | Opcode | Size | Payload |
| --- | --- | --- | --- |
| COMPLETION_FEED | `0x4342FE01` | 16 | version u32 = 1, reserved u32 = 0 |
| COMPLETION_WATCH | `0x4342FE02` | 24 | boxed queue u64, serial u64 (both nonzero) |
| COMPLETION_ORDER | `0x4342FE03` | 16 | order serial u64 (nonzero) |
| WAIT_SERIAL | `0x4342FE04` | 16 | watch serial u64 (nonzero) |
| COMPLETION_WATCH2 | `0x4342FE05` | 32 + 32 × count | boxed queue u64, serial u64, count u32, flags u32 = 0, then the entries ([Completion payloads](#completion-payloads)) |
| REPLY_MODE | `0x4342FE06` | 16 | mode u32 = 1 (silent success) or 3 ([one-way start](#one-way-start)), reserved u32 = 0 |

After each queue submission that signals a fence or timeline semaphore, sets or resets an
event, ends or resets a query or writes coherent memory, the process sends
`COMPLETION_WATCH` with a new serial on the same device stream; neither command has a reply
on its own stream. A process that holds a free until the work before it has completed also
sends one for a queue whose latest submissions no watch follows. The decoder serves both commands itself. For a watch it
submits, under the queue's lock, an empty batch whose new fence signals once all work
submitted to that queue before it has completed, holding the queue's instance and
device alive until a watcher thread has waited for and destroyed that fence. Each queue
has its own watcher, so a record is written as soon as its queue's work completes, whatever
another queue is still doing. Queues of
another process and virtually shared queues are not watched. On the feed stream the
phone writes one record per watch: serial u64, status i32 and payload bytes u32, which is
zero except for a COMPLETION_WATCH2 watch, followed by that many bytes. Status 0 means the
work completed, `-4` the device was lost, and `1` the queue cannot be watched. Records may
arrive in any order. A record with serial 0 is not a completion but the phone's own: a FAULT
([Silent success](#silent-success)), or one a process does not know, which it skips, payload
included. Watches made before the feed stream
attaches are kept for it. Further bytes from the process on the feed stream are a
protocol error; its end, or process stop, ends the feed. Watches still outstanding are
waited for, and their records discarded.

With `0x400000` a process may send `WAIT_SERIAL` on a device stream, with no reply: the
decoder decodes nothing more from that stream until the watch with that serial has its
record (its marker completed, its device was lost, or its queue cannot be watched), so
work the process sends after it reaches the GPU after the work the watch names, without the
process waiting for the feed. A serial above the process's last watch is a protocol error
that ends the stream; process stop ends the wait.

The guest uses it to speculate: a blocking `vkWaitForFences` or `vkWaitSemaphores` returns at
once for submissions whose completion the process can observe only through the fence and
timeline state it reports. Their batches write no host-visible memory the guest refreshes,
set, reset or wait for no event, end or reset no query, and signal no fence or semaphore whose
payload is imported or exportable. A speculated watch takes every earlier watch of its queue
with it, and the watches that signal the timeline values its batches wait for; each must
qualify, and none may wait for something the process has not yet sent (a timeline value no
watch signals, an event, an imported payload), since the held stream is how it would arrive.
The process speculates on a queue once one of its records arrived, with at most three
speculated watches per queue whose records are still to come, and only while one device
stream carries all its work. Before the next command it sends on that stream, it sends
`WAIT_SERIAL` for the latest speculated watch of each queue; another device stream of the
process waits for the records instead. A record that reports device loss is device loss,
and a value reported reached stays reached. `CABOOSE_GPU_SPECULATE=0` turns speculation off.

A wait the guest answers from the feed with a timeout of a second or more ends only once that
long has passed without the phone completing work on the queues of the submissions it waits
for, while those have been sent and are watched, and at the latest at the smaller of four times
its timeout and its timeout plus thirty seconds; shorter waits end at their timeout. Applications use such a
timeout to detect a hung GPU (DXVK gives every submission five seconds, then reports the device
lost), and a submission behind a phone's pipeline compiles can take longer while the phone is
not hung: after a speculated wait, the next wait also covers the work before it. A wait still
unsatisfied after ten seconds writes `CABOOSE_GPU_WAIT_STALLED` with what it waits for and what
the guest knows of it, and the other threads' waits of five seconds or more, then again every
minute; so does an encoder held behind speculated records.

With `0x800000` a process may send `REPLY_MODE(1)` once on a device stream, which needs the
process's completion feed (without one the stream ends). From then on the commands listed in
`apps/ios/GPUStream/gfxstream/silent-success-opcodes.inc` (the commands whose replies the
guest defers: guest-assigned creates and allocates, submits, binds, event sets) write no
reply on that stream. One that fails writes a FAULT record on the feed instead: serial 0,
status `0x7FFF0001`, 8 payload bytes of opcode u32 and result i32; the process treats it as
loss of its devices.

The process then knows the state of every fence and timeline semaphore whose signal
operations it has seen, of its events, and whether each query's result is available.
`vkGetFenceStatus`, `vkWaitForFences`, `vkGetSemaphoreCounterValue`, `vkWaitSemaphores` and
`vkGetEventStatus` resolve locally, waiting for feed records without holding the device
stream; `vkGetQueryPoolResults` without `WAIT` asks the device only once the result is
available, and not at all for queries the records capture ([Completion
payloads](#completion-payloads)). Frees and destroys of memory, buffers, images and their views are held until
every submission sent before them has completed, so work still running on any queue never
loses an object it keeps resident. A fence or semaphore whose payload is
imported or exportable, a fence signaled by the presentation engine's acquire, sparse
binding signals and unwatched queues are asked about on the device stream as before.
A reported timeline value can trail the device's actual value, as a status query on any
device can. It exceeds it only after a speculated wait (`0x400000`, above), and then nothing the process
sends afterwards reaches the GPU before the device has caught up.

### Completion payloads

With `0x200000` (granted with `0x200`) a watch also names what the phone captures for its
record: the queries a batch ends and the coherent memory it writes. A batch with either is
watched with COMPLETION_WATCH2 instead of COMPLETION_WATCH. Its size counts the 8-byte header,
like every completion command: `32 + 32 × count`, little-endian, with boxed queue u64, serial
u64 (both nonzero), count u32 (1 to 256) and flags u32 = 0, then from byte 32 `count` entries of
32 bytes: kind u32, reserved u32 = 0, handle u64, a u64 and b u64.

| Kind | Handle | a | b | Captured data |
| --- | --- | --- | --- | --- |
| 1, query range | boxed `VkQueryPool` | first query | query count | b × {value u64, availability u64}: `vkGetQueryPoolResults` with 64-bit results and availability |
| 2, memory range | boxed `VkDeviceMemory` | offset | size | b bytes of the allocation |

Once the watch's marker has completed, the phone captures each entry and the record's
payload holds, per entry in order, a 32-byte head (kind u32, status i32, the capture's
`VkResult`, handle u64, a u64, b u64) and its data, padded to 8 bytes. A reader stops at a kind
it does not know. A record carries at most 1 MiB of payload, and a process at most 16 MiB of
records not yet written; past either, the record's payload bytes are 0 and nothing was
captured; a lost device's record carries none either. A capture whose status is neither `VK_SUCCESS` nor, for queries, `VK_NOT_READY` holds
nothing usable.

The process names only what the phone can capture safely. A query range names a pool of the
watched queue's device whose queries report one value each (occlusion and timestamp pools);
pipeline statistics, transform feedback and other pools are asked about on the device as
before. The phone destroys a query pool without a lock against capturing it, so the process
holds `vkDestroyQueryPool` until every record that captures the pool has arrived. A memory
range names coherent memory the batch's commands write on the GPU (copies into a buffer,
query results copied into one); the phone validates and captures it under its decoder lock,
so a free needs no hold.

`vkGetQueryPoolResults` for captured queries is answered in the process: every flag (64- or
32-bit, availability, `PARTIAL`, `WAIT`, which waits for the records) and any stride and size
that fit, without the device stream; a batch an idle wait reported complete keeps its
queries pending until its record arrives. A query captured unavailable (later work reset
it), one whose record came without a payload, and any range the process cannot answer are
asked on the device as before. Captured memory is stored in the allocation's guest shadow, where an invalidate would
write it, before the watch's submission is reported complete; a capture of memory a later
batch also writes, or whose submission an idle wait already reported complete, is not stored.
The driver's invalidate after a wait does not read stored ranges from the phone again; it
reads only the GPU-written ranges no record stored (left out of a record for size, captured
for an older batch, failed, or written without completion payloads). Copies into buffers the
GPU also reads are not captured. What the invalidate reads, it reads on first use where it
can: the blocks are filled from the phone when the application or the kernel first touches
them, and never when nothing does (`bounded-memory/README.md`, Lazy readback).

### Ordered presents

With `0x400`, a process presents without waiting on either socket. It sends
`COMPLETION_ORDER` with its next order serial on its device stream, then
`SWAPCHAIN_PRESENT_ORDERED` on its surface socket: swapchain ID, present serial, boxed
queue and order serial (four u64), then kind 34's image index, queue family, actual
layout, wait count and boxed binary waits. Order serials rise with the stream; a process
uses them only while one device stream carries all its work. The decoder records each
order mark as it passes it. The phone's indexed surface runs an ordered present only
after the process's decoder has passed its mark, so the present follows every
submission and signal the process sent before it, and presents of a surface still run in
serial order. That wait is for decoding only, never for GPU work, and it overlaps
acquisition; stopping the process cancels it and the present is rejected with
`ECANCELED`.

Native presentation keeps up to two indexed frames in flight per surface, each observed
by its own worker, so a frame's copy is queued while the previous one presents; the
legacy present path keeps one. A frame that does not finish keeps its slot, and a device
or queue change waits until no frame is in flight. A process using ordered presents
sends its next present once fewer than two of its frames are unretired.

The process does not wait for PRESENT_RESULT: it is consumed whenever it arrives. A
present that was not queued ends its swapchain, and the next present or acquire on it
returns `VK_ERROR_OUT_OF_DATE_KHR`, or `VK_ERROR_DEVICE_LOST` for actual device loss; a
rejected frame's image counts as released. A frame whose outcome is uncertain never
retires and is not waited for by later presents.

With the completion feed as well, the process acquires its next image ahead of the
application: right after each present it sends an ordinary SWAPCHAIN_ACQUIRE naming one
of its private binary semaphores. When the application acquires, the process returns
that image once its ACQUIRED reply is in, and one queue submission waits for the private
semaphore and signals the application's semaphore and fence. Neither the phone nor the
wire changes for this.

### Shader cache

With `0x2000`, the phone keeps every SPIR-V module a computer creates, so later sessions
name it by hash instead of sending it. The app gives the decoder one directory per paired
computer (`Application Support/CabooseGPU/<pairing>`, excluded from the phone's backup and
removed at sign-out): modules go in `shaders/`, one file per module named by the lowercase
hex BLAKE3-256 of its code, and the persistent `VkPipelineCache` and the Metal pipeline
binaries in `pipeline/`. One computer never sees another's modules or pipelines.

A process asks for the phone's keys once, before its first module of at least 256 bytes,
with `SHADER_INVENTORY` on its device stream, after reading every reply it still owes:

| Command | Opcode | Size | Payload |
| --- | --- | --- | --- |
| SHADER_INVENTORY | `0x4342FE10` | 16 | version u32 = 1, reserved u32 = 0 |

The reply, on the same stream, is a key count u32 (at most 16384), reserved u32 zero, and
the 32-byte keys. From then on `vkCreateShaderModule` sends, in place of the code of a
module the phone holds, a 48-byte token: magic u32 `0x4D534243` ("CBSM"), version u32 1,
the code size u32 (256 bytes to 16 MiB, whole words), reserved u32 zero and the key, with
`codeSize` 48. A SPIR-V module starts with `0x07230203`, so a module is never read as a
token. A process whose commands all share one device stream also names by token a module
it sent as code earlier on that stream, when its inventory listed at least one key: an
executor without a store also answers an empty inventory, and cannot resolve such a token. The key covers the bytes the driver sends, after
its own rewrites of the module. The byte-exact forms are in
`guest/gpu/gfxstream/shader-cache/vectors.json`.

The decoder replaces a token with the stored code, verified against its key, before
creating the module, and keeps the code of every module it creates from code, on disk or,
if the file cannot be written, in memory. Nothing is removed while the app runs, so every
key an inventory listed and every module created from code stays resolvable; the store is
trimmed to 256 MiB and 16384 modules, least recently used first, when the app next opens
it. A token the decoder cannot resolve (a damaged file, or an executor without a store) fails
that module's creation; with guest-assigned handles that is device loss for the process
([Invalid commands](#invalid-commands)). A new executor connection
discards what the process knew, and it asks again.

The decoder seeds that cache into every `VkPipelineCache` an application creates, so the
guest driver keeps an application's own cache empty: it never sends the cache's saved data,
and `vkGetPipelineCacheData` returns the device's empty cache without asking the phone.
Pipelines built from these modules come from the per-computer `VkPipelineCache`, and the
Metal pipeline states MoltenVK makes from them from a Metal binary archive in `pipeline/`
(`provider-patches/moltenvk-pipeline-binary-archive.patch`): each pipeline is looked up in
the archive alone first; a pipeline the archive lacks is compiled as usual and added to it
on a serial queue, which writes the archive after every 16 additions and when a process
finishes. An archive the system cannot load (another OS version or GPU, a damaged file) is
replaced by an empty one. When a process finishes the decoder writes
`CABOOSE_GPU_CACHES` to standard error with the store's size and its resolved,
unresolved and inserted modules, and the archive's hits and misses since launch.

### Upload cache

With `0x8000`, the phone also keeps 4096-byte pieces of mapped memory a computer uploads, by
the BLAKE3-256 of their bytes, so a later process names a piece it uploads again (the same
image at the next launch) instead of sending it. The store is `uploads/` in the computer's
directory beside `shaders/`: packs of a table of 16384 32-byte keys followed by 16384 4096-byte
slots. A slot is written before its key, so an interrupted write leaves an empty slot, and a slot
is checked against its key when it is read. Opening the store reads only the key tables (512 KiB
a pack) into an in-memory index of key prefixes. The budget is 1 GiB, at most 5% of
the free space; opening the store drops whole least recently used packs, and nothing is removed
while the app runs.

A process asks once per executor, before its first cacheable flush and after reading every reply
it owes, with `UPLOAD_INVENTORY` on its device stream:

| Command | Opcode | Size | Payload |
| --- | --- | --- | --- |
| UPLOAD_INVENTORY | `0x4342FE11` | 16 | version u32 = 1, reserved u32 = 0 |

The reply, on the same stream, is a prefix count u32 (at most 262144), an allowance u32 and the
16-byte prefixes (the first 16 bytes of each key) of the pieces the store holds. The allowance is
how many pieces the process may ask the phone to store under this executor (at most 65536, 0
when the phone stores none).

In a multi-range flush packet, a fragment's data is `u64 length` and that many bytes; a piece
replaces it with `u64 length` of bit 63 set and exactly 4096 below it, then `u32 kind`:

| Kind | Follows | The decoder |
| --- | --- | --- |
| 1 | 4096 bytes | Writes them, hashes them and stores the piece (a duplicate key is kept once) |
| 2 | a 16-byte key prefix | Writes the stored piece |

Any other kind or length, or a prefix the store does not hold or holds for two keys, fails the
flush, which is device loss for the process. The phone hashes every piece it stores; it never
takes a key from the guest. Storing happens after the write, off the decoding thread, through a
pending set of at most 16 MiB from which later pieces already resolve.

The guest cuts pieces from the application's flushed range, not from its changed-block runs:
each whole 4096 bytes, from the range's offset, of a range of at least 16 KiB, all-zero pieces
excepted. A piece the host already holds unchanged costs nothing, as before. A changed piece
whose prefix the process knows goes as kind 2; a changed one of staging memory (bound only to
buffers that are copied from, never to vertex, index, uniform, storage, texel or indirect ones)
as kind 1 while the allowance lasts; both skip the changed-block comparison and leave the bytes
known to the shadow. Everything else is flushed as before. A process knows the prefixes of its inventory, and on each
device stream the pieces it stored on that stream, so a name never reaches the decoder before
its piece; the kind of a piece is decided before it is written, and a stored piece is hashed
again as it is written, so the key known is the one stored. A new executor (after a loss) drops
both and asks again; a resumed one keeps them, its retained records replaying into the same
store. The byte-exact forms are in `guest/gpu/gfxstream/upload-cache/vectors.json`.

## Readiness and retirement

The broker sends SESSION after the WebSocket upgrade. SESSION_READY requires
actual native initialization and exact feature agreement. PROCESS_READY requires
successful native process creation. STREAM_READY reserves the bounded socketpair
and the stream's run, reply-read and input-write workers for that process; it does not
mean decoder TLS admission, command execution or GPU completion. Each stream's DATA waits
in that stream's own input queue for its writer, so a decoder that is busy (a pipeline
compile, a wait in the driver) holds back only its own stream; the serial worker never
writes to a decoder. Queued input keeps its ingress charge until it is in the stream's
socket, so the ingress limit still bounds it. The socketpair holds up to 1 MiB of commands
and 256 KiB of replies where the kernel allows it. A subsequent run failure revokes the lease.
The private hello is consumed at session negotiation; DATA begins with the real
upstream client-flags word and ordered command bytes.

The phone takes a process's PROCESS_OPEN, its streams' STREAM_OPEN and their DATA in the
order the broker sends them, and answers each opening before anything the data after it
asks for. The broker therefore answers a guest's local hello as soon as it has sent the
openings, and relays the guest's data behind them without waiting a round trip for each
answer; replies are relayed only after the stream's STREAM_READY. An opening the phone
never answers fails the session, as it does when the broker waits for it. A surface bind a
process asks for before its PROCESS_READY waits for it.

FIN is a half-close after preceding DATA, not permission to discard reverse
replies. PROCESS_STOP revokes admission and interrupts active native runs.
PROCESS_RETIRED requires every run to return and the real upstream process cleanup
barrier to complete. Presentation resources require their own retirement proof.

When an individual local application crashes or disconnects its stream or surface
sockets, the broker contains the failure to that process and its bound surfaces
without terminating the executor session or disturbing other live processes.
Disconnected streams send FIN, discard undeliverable reverse DATA, and wait for
the phone's reverse FIN; a truncated stream closed by a crashing peer at `FIN` or
`PROCESS_STOP` completes that stream's retirement rather than failing the session.
Disconnected surfaces cancel any pending indexed acquisition
(`SWAPCHAIN_CANCEL_ACQUIRE`), request compositor grant revocation (`RevokeRequest`;
the compositor answers a request for a grant it has already retired by doing nothing,
so a late request is never a control failure),
wait for the crashed process's active command streams to drain before sending
`SURFACE_RETIRE`, and release the compositor grant (`GrantRetired`) only after
receiving the phone's `SURFACE_RETIRED` receipt, followed by `PROCESS_STOP` and
`PROCESS_RETIRED` when the process has no remaining streams or surfaces. If native
surface retirement returns an errno for a disconnected surface, the phone still
detaches the UIKit presentation view and reports `SURFACE_RETIRED` with that
nonnegative errno, quarantining only that surface slot while keeping the executor
and other processes alive.

For orderly app closure, EXECUTOR_DRAIN keeps the connection open while the broker
stops local admission and requests process stops. After actual process retirement,
the broker sends REVOKE. The phone sends REVOKED only after native cleanup, and the
broker then releases the lease and closes the transport. A bounded timeout may
force local cleanup but cannot produce a remote-retirement receipt. On abrupt loss
the phone drops every object of the lost connection; once the broker has ended every
local client of that generation it reports the generation retired to the compositor,
which ends every surface grant the generation held, and then releases the lease. A
reconnect is admitted as a new generation and served by the same broker. The newest
executor connection is the phone's: one that arrives while an earlier connection still
holds the lease (the host may hold a phone's transport for a resume the phone has given
up) ends that connection as an abrupt loss and is admitted once its teardown, bounded at
10 s, has released the lease (`CABOOSE_GPU_BROKER executor generation N superseded by a
new executor`). Reconnect never replays stale
handles or command history. A refused or abnormally ended executor session is logged
as `CABOOSE_GPU_BROKER executor session ended: <reason>`. A TCP executor connection whose
peer vanished without closing it counts as an abrupt loss within about 30 s: the broker
sets keepalive probes (after 10 s idle, every 5 s, 3 of them) and ends a connection whose
data stays unacknowledged for 30 s, so neither the lease nor clients waiting for replies
are held for the kernel's retransmission timeout.

## Memory budget

Before every guest `vkAllocateMemory` the decoder asks the phone's budget, which refuses the
allocation with `VK_ERROR_OUT_OF_DEVICE_MEMORY` when it would take the GPU device past three
quarters of Metal's recommended working set, leave the app less than 384 MiB before the
system ends it (`os_proc_available_memory`), or take what guests hold past an explicit limit
(the Linux executor's `--gpu-memory-limit BYTES`; the phone sets none). For a process with
guest-assigned handles a refused allocation is the loss of its device. Each refusal (the
first 64, then every 64th) is logged as `CABOOSE_GPU_MEMORY_REFUSED` with the request, what
guests hold, the device's figures and the reason (`limit`, `device`, `headroom`). While memory
is short (past 85% of a limit, or under twice the 384 MiB reserve left) presented-picture
capture rings are given up.

## Teardown report

A finished process's teardown never waits without bound. Its streams' decoders get 5 s to
return; one that has not keeps its stream, and the others retire. The decoder gives a
device's queues 1 s to go idle, then releases the semaphores and events nothing of the
process will signal and gives them 2 s more, and gives presentation leases 2 s; whatever is
still in use then (a device, an instance, a completion marker) is handed to a deferred list
whose worker frees it once the GPU is done (`CABOOSE_GPU_TEARDOWN_DEFERRED`, `_FREED`,
`_PENDING` every 30 s), and the teardown goes on. When cleanup has not returned by its
deadline, and every 10 s after, the phone prints where each process stands
(`CABOOSE_GPU_TEARDOWN_STEP`, `CABOOSE_GPU_TEARDOWN_PROCESS`).

## Executor stats

A phone that declares `executor-stats` keeps a few always-on counters in its executor: commands
decoded and the time inside the decoder, bytes read from the computer's streams and the time
waiting for them, the time writing replies, completion watches submitted and completed (their
submit-to-completion time, and the time the GPU had watched work in flight, counted once however
many queues overlap), and the watches waiting now and the most waiting at once. Each is a
relaxed atomic add; nothing is gated by build configuration or the environment.

After the session is ready the broker sends `STATS_REQUEST` (kind 48, session scope, 8 bytes:
interval in milliseconds as u32, then a reserved u32; the broker asks for 1000). The phone then
sends `EXECUTOR_STATS` (kind 47, session scope, 96 bytes: `caboose_gpu_executor_stats`, twelve
u64 totals since its runtime started, the first the record's size) at that interval, except
while suspended, until the session ends. A second request, an interval outside 100 to 60 000 ms,
or stats nobody asked for end the connection. Every 5 s the broker prints what changed:

`CABOOSE_GPU_EXECUTOR_STATS elapsed_ms=… commands=… decode_ms=… read_bytes=… read_wait_ms=…
flush_ms=… submitted=… completed=… completion_mean_us=… gpu_busy_pct=… outstanding=…
outstanding_max=… at=…`

These sit beside the broker's own `CABOOSE_GPU_SURFACE_STATS` (presents per second, gaps and
link bytes per surface; see the broker's README), which need nothing from the phone. Both are
counters only, never handles, payloads or identities. The phone's frame-lab pictures and its
console mirror stay opt-in diagnostics.

## Executor generations

A computer outlives its executors: the phone app closes, relaunches, loses the network or
the phone locks, and a new executor (perhaps another phone) takes its place while the
compositor, Xwayland and the applications keep running. Each executor a process connects to
after losing the previous one is a new **executor generation**, and everything that belongs
to an executor belongs to its generation:

- **Objects.** Every dispatchable Vulkan object a guest process makes (instance, physical
  device, device, queue, command buffer) records the generation it was made under
  (`caboose::completion::connectionGeneration`, driver patch 0077). A call on an object of
  an earlier generation reports `VK_ERROR_DEVICE_LOST` at the encoder's entry and never
  reaches the executor, which does not know its handles; a surface of an earlier
  generation's instance reports `VK_ERROR_SURFACE_LOST_KHR` and never binds. A process
  connects to the new executor with its next `vkCreateInstance`, so an application recovers
  by making a new instance, as Chromium's GPU process, Zink contexts and the compositor do.
  One that cannot recover ends, as a DXVK game does.
- **Results.** A lost device gives the results its specification allows: a call that may
  report the loss reports `VK_ERROR_DEVICE_LOST`; any other (mapping, allocation, enumeration,
  image-format queries, exports) succeeds locally or fails as that command may, and memory
  allocated while lost is local zeroed memory that maps (`bounded-memory/lost_memory.h`).
- **Answers and tables.** What the driver keeps of an executor's answers is either keyed by
  generation (the capability cache's connection identity, the shader and upload cache
  inventories, the completion feed, deferred replies, extension lists) or forgotten through
  one reset hook (`caboose::completion::onNewGeneration`) that runs on the reconnecting
  thread before the first call of the new generation: cached memory types, heaps and budget,
  the instance extension table, the device features the driver emulates around, devices'
  presentation queues, completion watches owed to old queues and host allocations shared
  through dma-bufs. A capability answer read while its executor was leaving is never stored
  under the next one.
- **Connections.** The device stream reconnects with the next instance. A connection that
  reaches another executor's socket than the process last connected to starts a new
  generation even if none of its streams had ended (an idle process learns of the change only
  by connecting), and the generation advances before the loss is cleared, so another thread
  calling on an object of the old generation meanwhile never reaches the new executor. A process's dma-buf
  registrations (`dmabuf/registration.h`) belong to the broker session they were made
  under, which the broker's device socket identifies; the process keeps the registrations of
  its live buffers and sends them again on every new connection of the same session, and
  drops those of an earlier session.
- **Broker.** Each admitted executor is a new `Session`; its processes, streams, surfaces,
  buffer registrations and grants end with it. Ready is reported to the compositor only once
  the session's device and surface sockets exist, so a renderer rebuilt on the report finds
  the executor. The session's buffer binds and retries are cancelled when it ends, so nothing
  of it is answered after its loss. A registration of a buffer another process registered
  first (the compositor importing a client's buffer) registers nothing and ends nothing, and
  a generation admits up to 64 processes.
- **Executor.** A new generation reaches the executor as many processes at once (the
  compositor, the capability warm-up and every application making a new instance). The
  Vulkan loader's tables of instances and drivers are not safe for that, so the executor
  makes and destroys instances and devices and enumerates physical devices (the fork) and
  makes surfaces, surface queries and swapchains (`presentation_driver_lock.h`) under one
  driver lock. It never waits for a presentation while holding the lock.
- **Compositor.** A ready executor supersedes a previous one whose loss or retirement report
  never arrived; a stale loss, retirement or buffer release is ignored instead of restarting
  the broker. It never composes a client's phone-resident buffer (its pixels exist only in
  its own process's phone memory; importing it elsewhere gets memory nobody drew into), so a
  window shows a client buffer only when the broker presents it. An output that goes away is
  disabled before it is destroyed, so an application starting during a display reconnect is
  not ended by a protocol error. Its own process runs with `CABOOSE_GPU_ON_LOSS=quiet`: it
  learns of a loss from its broker, so its lost device answers as a working one (submissions
  are dropped and complete, waits are satisfied, no call reports `VK_ERROR_DEVICE_LOST`) and Zink
  never takes its device-loss paths, whose teardown did not end. A call made after the loss, or
  one whose reply was lost because the executor left during it, gets stand-in outputs: unique
  local handles for what it creates or allocates, supported layouts, plausible sizes; never a
  null handle. The renderer is made again
  on the broker's report, and once a second for up to ten tries when it could not be made.

`apps/ios/GPUStream/gfxstream/linux-executor/check_chaos.py` holds the stack to this: a seat
of its own with the compositor, a long-lived Chromium, Steam's CEF client, and fresh
Chromium, GL and DXVK applications, through random executor kills, network drops, stalls,
viewer reconnects and losses during application startup, with every application required to
present real pictures (not noise, not blank) after each. The release seal runs it.

### Silent success

With `0x800000` (granted with `0x80` and `0x200`), a process's device streams can leave out the
replies of the commands it does not wait for. A device stream switches with one packet, sent on
it after the client-flags word like any command:

| Command | Opcode | Size | Payload |
| --- | --- | --- | --- |
| REPLY_MODE | `0x4342FE06` | 16 | mode u32 = 1 (silent success) or 3 ([one-way start](#one-way-start)), reserved u32 = 0 |

It has no reply, and it holds for that stream until the stream's next REPLY_MODE. The process
sends `REPLY_MODE(1)` once on each device stream, including a stream it connects again after its
executor changed, only while its completion feed runs, and before the first command whose reply
it will not read; with [one-way start](#one-way-start) it switches to `REPLY_MODE(3)` for a
start command and back to `REPLY_MODE(1)` after it. A stream without the switch is answered as
before. The decoder ends the stream of a process without a
feed that sends it (`EPROTO`). The decoder does not see the hello, so the switch is the only
signal.

On a switched stream the decoder writes no reply for the commands in
`apps/ios/GPUStream/gfxstream/silent-success-opcodes.inc` when their result is `VK_SUCCESS`; a
command of that list without a result counts as succeeded. They are the commands the guest
does not wait for: guest-assigned creates and allocations (memory, fences, semaphores, query
pools, buffers, images and views, buffer views, shader modules, pipeline caches, graphics and
compute pipelines, pipeline layouts, samplers, descriptor set layouts and pools, descriptor
sets, framebuffers, render passes, command pools and command buffers), queue submits with
their staged command buffer begins and ends, buffer and image binds, and host event sets and
resets. Only an encoder on a device stream switches; one recording a command buffer into
local staging never sends REPLY_MODE. A command of the list that fails writes no reply
either: the decoder sends one FAULT record on the process's feed, 24 bytes, little-endian:

| Field | Value |
| --- | --- |
| serial u64 | 0 |
| status i32 | `0x7FFF0001` |
| payload bytes u32 | 8 |
| opcode u32 | the failed command |
| result i32 | its result |

A FAULT made before the feed stream attaches is kept for it, as watches are.
A FAULT is the loss of the process's device, as an [invalid command](#invalid-commands) is: the
process prints `CABOOSE_GPU_SILENT_FAULT opcode=… result=…` and `CABOOSE_GPU_EXECUTOR_LOST`, its
calls return `VK_ERROR_DEVICE_LOST`, and an application that recovers creates a new instance.
A feed that ends while a switched stream is still open is the same loss
(`CABOOSE_GPU_SILENT_FEED_ENDED`): the failures of its commands could no longer arrive. A feed
that ends after the process closed its switched streams itself (its device or instance
destroyed, its connections torn down at exit) is its own teardown and loses nothing.

The guest's list is `guest/gpu/gfxstream/bounded-memory/silent_success.h`;
`test_silent_success_list.py` fails when it differs from the decoder's, and every driver build
checks (`driver/check_silent_success.py`) that the encoder defers the reply of each command in
it and of no other. The guest uses silent success only when `0x80`, `0x100`, `0x200`, `0x1000`
and `0x10000` are granted with it, so that every create of the list takes a guest-assigned
handle. Those commands' replies are not queued: they do not count toward the 6 MiB of commands
or 64 KiB of replies a process lets the phone owe, and no drain before a synchronous command
reads them. On a switched stream every allocation takes a guest-assigned handle; one that
would otherwise have waited for its reply (an import, an export, or one past the guest's
allocation budget) is followed by the round trip below before it returns, and a plain one
that would take its heap past the heap's size, counting the process's own allocations alone,
returns `VK_ERROR_OUT_OF_DEVICE_MEMORY` without being sent. A pipeline
create with `VK_PIPELINE_CREATE_FAIL_ON_PIPELINE_COMPILE_REQUIRED_BIT` compiles: the flag is
cleared, since `VK_PIPELINE_COMPILE_REQUIRED` would arrive as a FAULT. Before the presentation
channel names objects or work the stream made, the process reads the reply of one
`vkEnumerateInstanceVersion` sent after its last silent command, so the phone has decoded them.
An allocation or create the phone refuses is then device loss, never a result the application
sees.

### One-way start

With `0x1000000` (granted with `0x80`, `0x200` and `0x800000`) a process may send
`REPLY_MODE(3)` instead of `REPLY_MODE(1)`. Mode 3 is silent success, and it also silences the
commands that start a process's Vulkan, whose handles the process chooses itself
([Guest-assigned handles](#guest-assigned-handles)):

| Command | Opcode | A failure |
| --- | --- | --- |
| `vkCreateInstance` | 20000 | its result |
| `vkEnumeratePhysicalDevices` | 20002 | its result, `VK_INCOMPLETE` included; `VK_ERROR_INITIALIZATION_FAILED` when it found fewer than the process named |
| `vkCreateDevice` | 20011 | its result; `VK_ERROR_INITIALIZATION_FAILED`, without reaching the driver, for queues the physical device does not have |
| `vkGetDeviceQueue` | 20017 | `VK_ERROR_INITIALIZATION_FAILED` when no queue matches |
| `vkGetDeviceQueue2` | 20155 | `VK_ERROR_INITIALIZATION_FAILED` when no queue matches |

On success the decoder writes nothing for them; a failure is a FAULT record with the opcode and
that result, as for silent success. A decoder without one-way start ends a stream that sends
`REPLY_MODE(3)` (`EPROTO`), so a process sends it only with `0x1000000` granted. The process
predicts each answer from an identical call that succeeded earlier in the session (an
instance, a device's queues); a prediction the phone does not bear out
is a FAULT, and the device lost. `apps/ios/GPUStream/gfxstream/silent_replies.h` holds the mode
and the commands; `caboose_gpu_native_one_way_start` checks them against the real decoder
(`apps/ios/GPUStream/gfxstream/README.md`).

The guest driver offers `0x1000000` with everything else it offers, and with it granted names
every instance, physical device, device and queue it makes. Its device stream stays in
`REPLY_MODE(1)`: a start command goes one-way inside `REPLY_MODE(3)` … `REPLY_MODE(1)` around it,
in order on the stream, only when an identical one succeeded earlier in the executor session.
An instance is identical when its flags, application, layers and extensions are (the loader's
own structures aside; any other chained structure is always asked); a device when its
fingerprint is ([Physical capability cache](#physical-capability-cache)) on the session's one
GPU; a queue when its device's fingerprint, flags, family and index are. A list of physical
devices names them but is always asked: the phone keeps the handle it first gave a physical
device, so only its answer says which handles the process may use, and a list sent without it
could leave the process with a physical device the phone does not know (no queue families, no
properties). The first of each is asked
and waited for, and its success is kept in the session's instance scope, so every process after
it in the session starts without those round trips; a new executor connection starts with none.
A process's first start command may come before its feed runs: it waits up to 100 ms for the
feed, then asks the command instead (`guest/gpu/gfxstream/bounded-memory/one_way_start.h`).
`CABOOSE_ONE_WAY_START=0` asks every start command. Once a FAULT has lost the device, the
process's destroys of what it made (the refused instance or device among them) stay in the
process: every command checks for the loss before it is sent, and the FAULT ends the process's
streams, so a thread already waiting for a reply the phone will not send (a list asked on the
refused instance) gets the lost answer instead of waiting. A destroy the process sends
before the FAULT reaches it names an object the phone never made, and the phone ends that
process's streams, which the process sees as the same loss; the executor and every other
process go on.

## Launch timeline

The guest driver writes where a process's start went, always, to standard error
(`guest/gpu/gfxstream/bounded-memory/launch_timeline.h`). Once each, in milliseconds since the
process started: its first instance, device, shader module and pipeline, and its first present
(`CABOOSE_GPU_LAUNCH pid=… process=… event=first_device ms=…`; the process name is the
executable's under Wine). For its first fifteen minutes, every ten seconds in which it made
anything, one line with what those seconds made: shader modules and their bytes, pipelines (a
`vkCreate*Pipelines` call each), presents, and commands and their bytes, with the running
totals of modules, pipelines and presents. Shaders a pipeline carries inline
(`VK_KHR_maintenance5`, as DXVK passes them) count in its command's bytes, not as modules.

The decoder writes the phone's side every ten seconds in which it compiled a pipeline, waited
for one or looked one up in the Metal binary archive
(`apps/ios/GPUStream/gfxstream/pipeline_report.h`): `CABOOSE_GPU_PIPELINES` with the pipelines
its compile lane made and the time the lane's jobs ran, those made in place on a decode thread
and their time, the longest job, how often and for how long a decode thread waited for a
compile it needed (time it decoded nothing else), and the archive's hits and misses. Where the process waited
for the phone in the same time is the read profile's (`CABOOSE_READ_PROFILE=1`), and what it
sent the memory traffic line's.

## Lock order

The guest driver's locks form one hierarchy; a thread holding a lock takes only locks below it:
the encoder's stream lock, then the flush shadow, the tracker (`ResourceTracker::mLock`), the
deferred replies, the completion tracker and the write watch. Lazy readback's fills take none
of them: they read on an auxiliary stream of the process's own. The silent-success switch table
(`bounded-memory/silent_success.h`) is taken under the encoder's lock and takes no other lock,
and the memory traffic counters' allocation table (`bounded-memory/memory_traffic.h`) is taken
under any of them and takes no other lock. Taking the same lock again (the tracker's is
recursive) or another encoder's is allowed. `bounded-memory/lock_order.h` holds the hierarchy and
a checker: with `CABOOSE_LOCK_ORDER=1` every acquisition of those locks is checked and a lock
taken above one already held is reported once with its calling frames
(`CABOOSE_LOCK_ORDER took=… holding=…`); `CABOOSE_LOCK_ORDER=abort` also aborts there. Unset, an
acquisition costs one load.

## Resuming an executor

A phone that declares `executor-resume` keeps its executor across a lost socket. The host
then returns `X-Caboose-GPU-Resume` in the upgrade response: 32 random bytes in unpadded
base64url, bound to the computer, the phone credential and the executor, kept in host memory
for the executor's lifetime. With the feature the broker's first envelope is ACK with value
0, before SESSION. Only with both does the session resume; otherwise neither side sends kind
40 or 41 and a lost socket ends the executor as before.

ACK and RESUME carry sequence 0 and stand outside the directional sequence: they are never
retained, retransmitted or passed to the envelope decoder. Every other envelope keeps its
sequence, which now runs across sockets. In a resumable session each broker-to-phone
WebSocket message is exactly one whole envelope or one CGLZ record, and each phone-to-broker
message is one or more whole envelopes.

Each side acknowledges cumulatively with ACK once 64 KiB has arrived, or 50 ms after the
first unacknowledged envelope. Each side retains every envelope it sent until the peer's ACK
or RESUME covers it, at most 8 MiB and 2048 envelopes (the phone leaves 256 KiB and 64
envelopes of that for its acknowledgements); a full window holds the sender back without
ending the session. An acknowledgement below an earlier one or above the highest sequence
sent ends the session.

When the phone loses its socket (an error, an abnormal close, or no pong and no message for
3 s), it reconnects at once and then every 250 ms for 30 s, each attempt with the same
request plus `X-Caboose-GPU-Resume` and a 3 s upgrade deadline. The host splices a valid
credential onto the executor it holds, ending the old phone socket if it still has one, and
answers an unknown or expired credential with `410 Gone`, which ends the executor at once. When
the broker's side ends without its retirement exchange (the broker ended, as at a display
restart), the host closes the phone's socket with code 4410 ("executor ended") and keeps no
credential for it: the phone ends the executor at once, as after a 410, without reconnecting.
The phone's first message on the new socket is RESUME alone, with the last sequence it
received and a fresh nonce; it sends nothing else until the broker's answer. The broker
answers with RESUME, alone in its message, carrying the last sequence it received and the
same nonce, then retransmits what follows that sequence. The phone ignores every message
before that answer, so nothing in flight across the splice is delivered twice, retransmits
what follows the broker's value, and requires each later envelope to follow the last it
received. Neither the native executor nor the broker sees the gap. After 30 s without a
splice, or a 410, the executor ends as after any lost transport. The phone prints
`CABOOSE_GPU_RESUMED received=… sent=… replayed=…` after each splice.

## Suspending an executor

In a resumable session the phone suspends its executor in place when the app starts to leave
the foreground (`willResignActive`), while iOS still runs its GPU work, and keeps every Vulkan
object, memory allocation and surface through the background. First it closes the native
suspension gate (`caboose_gpu_runtime_suspend`, [the adapter](../apps/ios/GPUStream/gfxstream/README.md#suspension)):
each command already decoding finishes, no decoder starts another, and every queue is
waited idle, so nothing reaches the GPU while the app is away. It then sends
EXECUTOR_SUSPEND and holds every later process-scoped message, in order, without decoding
it. The broker stops reading its guest streams at envelope boundaries, so guest processes
block on their next call that needs the phone, and sends QUIESCE after what it had already
read. The phone answers QUIESCED once every reply its decoders wrote has been handed to the
transport, and sends nothing further until it resumes. Owner surface revocations wait for
the resume too.

In the background the phone closes its socket with code 4001 once the broker has
acknowledged everything it sent, or after 2 s; the host holds a suspended executor for its
extended window, as the relay describes. When the app is active again the phone resumes the
socket ([Resuming an executor](#resuming-an-executor)), opens the gate, sends
EXECUTOR_RESUME with mode 0, and decodes the messages it held. A suspension cancelled before
QUIESCE arrives (a notification or Control Centre pull) decodes at once and sends
EXECUTOR_RESUME right after its QUIESCED, so the broker always sees EXECUTOR_SUSPEND,
QUIESCE, QUIESCED and EXECUTOR_RESUME in that order.

A suspension whose commands do not finish within 1 s keeps its gate closed; those commands
park when they end. A session that is not resumable, or a native runtime without the gate,
drains its executor on backgrounding as before. If iOS ends the app while it is suspended,
the hold expires and the executor is lost as after any lost transport.
A phone that declares `executor-resume` gets the executor's resume credential with its
upgrade response (`X-Caboose-GPU-Resume`): 32 random bytes in unpadded base64url, kept in the
host's memory for the executor's lifetime and never rotated. A later upgrade that presents it
is spliced onto the same executor; an unknown or expired credential, one issued to another
phone, or one presented after the executor ended gets `410 Gone`. A phone without the feature
gets no credential, and a lost socket ends its executor as before.

The host's relay (`apps/host/src/gpu-relay.ts`) parks instead of ending when a resumable
phone side is lost: a socket error, a close other than 1000, a failed send, or 3 s without a
pong or a message. It keeps the broker's side open and still counts the executor as the
computer's one; it goes on reading that side and drops what arrives, so the broker's own
window is the only replay and a broker that ends (a display restart) ends the relay at once.
A fresh executor upgrade, without the credential, from the phone the held executor belongs
to replaces it: the held relay is ended and the new executor admitted. Another phone still
gets `409 Conflict`. It holds it for 30 s, or for 30 min after a phone that closed
with code 4001 (suspended) or that last sent EXECUTOR_SUSPEND without a later EXECUTOR_RESUME
(iOS can suspend the app before its close); neither close is forwarded to the broker. The
relay reads only the kinds of the whole envelopes in the phone's messages for that. A phone close with 1000
keeps the normal-close receipt. A splice that arrives while the old phone socket still looks
open ends that socket. When a hold expires the relay ends the broker's side abruptly, and the
executor is lost as after any lost transport; a host restart ends parked relays too.

The broker (`guest/gpu/gfxstream/caboose-gpu-broker`) negotiates the session as resumable when
the phone declared the feature, and then sends ACK with value 0 as its first envelope. It keeps
every sequenced envelope it wrote, as the exact bytes written (CGLZ records included), until
the phone's ACK or RESUME covers it, and stops writing new ones while 8 MiB or 2048 are
unacknowledged, so local streams wait for credit as they do for a busy phone. It acknowledges
the phone after 64 KiB received or 50 ms after the first unacknowledged envelope. On the phone's
RESUME it writes its own RESUME with the phone's nonce, then everything after the sequence the
phone named, both ahead of anything queued; envelopes from the phone it already received are
skipped. Each splice is logged as `CABOOSE_GPU_BROKER executor resumed: phone had N, sent again
M envelopes`. An ACK or RESUME in a session that is not resumable, or an acknowledgement below
an earlier one or above the highest sequence sent, ends the session.

## Suspending an executor

In a resumable session the broker answers EXECUTOR_SUSPEND by closing a gate in front of every
guest stream read and surface-socket read: reads already past it finish and reach the queue,
then the broker sends QUIESCE, and guest processes block in their next call that needs the
phone. It reopens the gate on EXECUTOR_RESUME (mode 0 in place, 1 from a snapshot), logs
SNAPSHOT_REFUSED's reason, and refuses suspension controls in a session that is not resumable,
a second EXECUTOR_SUSPEND, QUIESCED outside a suspension, or EXECUTOR_RESUME without one.
The broker's own deadlines for the phone's answers (a process or stream opening, a stream's
FIN, a process or surface retiring) count only time the executor is not suspended, and in a
resumable session last at least the host's longest hold, since the phone may be away unseen
while the relay holds its transport. A process or stream the phone has not yet opened is
never given up on alone: the phone would then receive its surfaces and further openings
under identities it does not know. Local
processes keep their streams and bindings throughout, and the compositor's grants stay as they
were, unless the relay's hold expires and the executor is lost. The compositor itself is held
only briefly: its main thread draws and also accepts every client, so a call of its renderer
the gate holds would leave every new application waiting for the phone. Once a suspension
outlasts 3 s (`COMPOSITOR_HOLD_SECONDS`) the broker ends the streams of its parent process,
the compositor, which then sees its device lost quietly, and sends it executor lifecycle record
11 (CGB1, the layout of records 4 to 6); the compositor drops its renderer and draws nothing.
On EXECUTOR_RESUME the broker sends record 12 and the compositor makes its renderer again on
the phone. A compositor that connects later is told only the executor's state (4, 5 or 6).

## Window identity boundary

The optional owner display hello field `gpu_live_epoch` is exactly 16 nonzero
CBOR bytes. It identifies the compositor's private-service instance and is absent
when that service is unavailable. A broker loss revokes its grants and invalidates
the display association. A new epoch does not erase outstanding native work.

A surface bind names a native Wayland surface or an X11 window on the display's
Xwayland: the trailing 32-bit field of the CGLS bind request and of the CGB1 bind
record is the object's namespace, 0 for a `wl_surface` protocol ID and 1 for an X11
window ID; any other value is malformed. A bind either carries a frame or is a probe. A
process that answers its surface queries itself (guest-owned images) binds with a frame
when a present sends the bind or frames wait for it, and otherwise (a query, swapchain
set-up) binds as a probe: its CGLS bind request has 32 bytes, adding flags (1) and a reserved
word (0), and the broker sends it as a version-2 CGB1 bind record of 64 bytes with the same
two words. A 24-byte request and a version-1 record carry a frame, as every bind from a
process without local answers does. The compositor refuses every probe: a window keeps
the picture the compositor presents of it until its application has a frame for it, and
an application that makes a surface on its own window and never presents there (Steam's
CEF browser process) does not take the window's picture away. A frame finding its probe
refused binds again at once, without the retry delay of queries. Only the compositor can bind an actual
client/surface to a current owner window; an application-provided window number or
X11 `_NET_WM_PID` is not authority.

- A Wayland bind matches a toplevel whose own `wl_surface` has that ID and whose
  accepted Wayland peer is the bound process (its held pidfd and the broker's).
- An X11 bind matches a managed X11 toplevel, or an override-redirect window (a menu,
  tooltip or dropdown, which the phone shows as a popup over its parent), that is the
  window or that the window covers: a descendant at the toplevel's origin with its
  size, as Chromium's GPU process draws into, or short of it by less than a logical
  pixel (X11 windows are in display pixels and toplevels are sized in whole logical
  pixels, so a full-screen game's child on a display 911 pixels high at scale 2 is
  one pixel shorter than its 912-pixel toplevel), or larger than it (a game's
  swapchain sized to the screen in a window the phone holds smaller, maximized below
  Laptop's title bar). The X server's own record of
  the client that created the window (X-Resource `LocalClientPID`) must be the bound
  process, the broker's pidfd must identify that live process (PID, start time and
  owner), and the owner must be the compositor's user. The grant is the toplevel's
  window. A bind configures a full-screen window, one the client has not given a
  geometry, or one whose bound child is larger than it, to the display's extent; any
  other window the client placed keeps its geometry, so an application that rebinds
  each time it recreates its swapchain (CEF) is not resized. A popup keeps the place
  and size its application gave it.
  X11 has no client isolation: any client of the seat's Xwayland can create a child
  window inside another's toplevel, so an X11 grant proves only that the bound
  process made the window it presents to on the owner's own display.
- An X11 bind (with a frame) of a window that is not bindable yet, because it is not
  mapped or the compositor has not taken in its map, is held rather than refused when the
  X server records the bound process as the window's maker and the broker's pidfd
  identifies it. Toolkits bind a surface as soon as they make its window (a menu, a
  top-level or a child), before it is shown. The compositor answers a held bind, by the
  rules above, as soon as the window maps, looking again every 100 ms. It refuses it when
  the window is destroyed, the process ends, a newer bind of the same window by the same
  process arrives, or it has been held 4 s, inside the broker's 5 s wait for the answer;
  at most 16 are held, and one more is refused at once. A window whose bind waited out
  the 4 s is not held again (of the last 64 such windows): its later binds are refused at
  once until it is bindable, so a window that never maps costs its process one wait. A
  broker that ends takes its held binds with it, unanswered.
- An inset surface, an X11 descendant of such a toplevel that does not cover it (a
  browser view CEF draws in its own child window) or a subsurface of a Wayland toplevel,
  bound by the process that made it (the same X-Resource and pidfd checks), becomes a
  child window of that toplevel ([display.md](display.md#child-windows)) when the
  display client shows children, and the grant is the child's window. The compositor
  follows the X11 window and its ancestors (structure and substructure notifications)
  and sends the child's geometry, clip and stacking whenever they change; the phone
  places the bound layer there, inside the parent's picture. A display client that
  does not show children leaves such a bind refused.
The app's visible interactive owner view supplies the native layer; thumbnails
cannot acquire it. `LiveGPUOwnerSession` explicitly constructs the owner registry
and linked surface backend; ordinary display and agent sessions do not. The
registry matches the display epoch and window object, and places the layer in the
one visible eligible view showing that window.

Visibility never stalls the guest. While no eligible view shows a bound window
(another tab is in front, the view is hidden, off screen, rebuilt, or reused for
another window) its lease is parked: the presentation view leaves the hierarchy,
but the lease, its binding and its swapchain stay valid and keep accepting
presents. When an eligible view shows the window again, the same layer returns to
it with the latest frame presented. A bind for a window no view currently shows
starts parked at the window's server pixel size.
The executor survives an ordinary display reconnect and seamless display or
owner-view geometry changes (such as device rotation): when the display or
window extent changes to a valid new size, the compositor reconfigures the
bound toplevel window to the new display dimensions and the owner view updates
the active lease extent and fits the presentation view in place while the
application reconfigures its swapchain at the new extent, without revoking the
surface grant or dropping the executor. An application that keeps its own resolution
instead (a full-screen game often does) is scaled by the phone: the presentation layer
fills a full-screen window and otherwise fits the window with the picture's aspect ratio,
centred, with black where it does not reach. A changed display epoch or window object,
or invalid/zero server geometry, requests revocation of only the affected surface
(`SURFACE_REVOKE_REQUEST`). Background or computer
replacement drains the entire executor. The owner AppModel opens the authenticated host
endpoint for every owner computer and updates the registry from its ordinary display.
Agent and thumbnail sessions never create an executor.
Neither a WebSocket send, a queue-submit return nor a local cleanup callback means
an image was displayed.


## Seats

The computer's shared broker serves both displays from one executor. It runs as a service
beside them:

    caboose-gpu-broker --dir $XDG_RUNTIME_DIR/caboose-gpu --listen 0.0.0.0:14602 \
        --token-file /run/caboose/display-token --private-indexed

`--dir` is a private directory (mode 0700) with one subdirectory per seat, `owner` and
`agent`, each also 0700, each holding the seat's `control.sock` (its compositor's channel, a
Unix sequenced-packet socket of mode 0600) and, while an executor serves, its `gpu.sock` and
`surface.sock`. The phone's executor connects to `--listen` with `GET /gpu` and the same
per-wake token, `X-Caboose-GPU-*` headers and resume semantics as through a display.
`usage.json` is written to `--dir` itself.

A client's seat is the socket it reached, and nothing crosses seats:

- A process belongs to the seat whose `gpu.sock` its first stream reached; a stream of it on
  the other seat's socket is refused (`CABOOSE_GPU_BROKER refused a cross-seat stream`), and
  so is a surface connection on the other seat's `surface.sock`.
- A bind is asked of the process's own seat's compositor, and only that compositor's answer
  is taken. Its grant's epoch is that compositor's: revokes, retirements and releases of the
  grant go to it alone, and a revoke from the other seat's compositor is refused.
- A seat's compositor presents only buffers of its own seat's processes; window IDs are each
  compositor's own.
- A seat's compositor going retires that seat's surfaces alone; the executor and the other
  seat go on. Executor lifecycle records (4, 5, 6, 11, 12) go to every seat's compositor.

The phone routes each surface to its seat's display session from the seat in
`SURFACE_BIND` ([Surface records](#surface-records)), sent when it declares the transport
feature `seat-routing`. A phone that does not declare it is shown the owner seat alone: an
agent-seat bind is refused before its compositor is asked. The phone (LiveGPUSeatSurfaces)
presents an owner-seat surface in the owner's display session and an agent-seat surface in the
agent seat's display session, the Watch view, through the one executor. While no agent-seat
session is open it answers an agent-seat bind `ENOENT` and drops it, so a window of one seat is
never shown in the other's display; a surface bound while the session was open ends with that
session. The Linux executor shows one display, the owner's, and answers every agent-seat bind
the same way.

A compositor joins the shared broker with `--private-gpu-broker DIR/SEAT/control.sock` and its
seat's `gpu.sock` and `surface.sock`, and starts no broker of its own. Until the broker is there,
and whenever no executor serves, it renders on the computer's own device, as without a phone:
the agent seat's screenshots and computer use never depend on the phone. The agent seat's
applications always draw on the computer; only its compositor's picture uses the broker. The
agent seat may take only `DIR/agent`, and the owner seat never takes it.

A container computer starts the broker and passes each display its seat's options through
`caboose-session`. A virtual machine computer does it with systemd, from files the GPU stack
installs (`guest/gpu/vm`, placed by `install-live.py` with the rest of the stack):

- `caboose-gpu-broker.service` runs the broker as `caboose` with the options above. It runs only
  where the stack is installed (`/usr/local/lib/caboose-gpu-live/icd.json`), and both display
  units want it and start after it.
- Each display unit appends `caboose-gpu-seat-args SEAT`, which prints that seat's
  `--private-gpu-*` options, or nothing without the stack.
- `vgem` is loaded at boot (`/etc/modules-load.d/caboose-gpu.conf`). A udev rule gives its
  card and render nodes and `/dev/userfaultfd` to the `caboose` group, mode 0660.

A virtual machine has no server GPU: the phone is its only GPU, and `CABOOSE_GPU` is unset. The
host relays the phone's `GET /gpu` to port 14602 at the machine's address, as it does for a
container.

## Surface records

Every surface payload starts with the same 40-byte identity: 16 nonzero compositor
epoch bytes, 16 nonzero grant bytes, and a nonzero little-endian uint64 surface
generation. These fields are distinct from the envelope’s executor generation.
The authenticated process-scoped envelope supplies the process identity. The
compositor derives grants from the native Wayland peer and surface, not a claimed
window number. A revoke being sent does not retire a grant: the compositor retains
its identity until the matching native retirement receipt and send completion have
both arrived, in either event-loop order.

A 16-byte status is `native_errno` (int32), `has_vk_result` (uint32), `vk_result`
(int32), and reserved uint32 zero. Native errors are nonnegative errno values.
`has_vk_result` is zero or one; an absent Vulkan result requires `vk_result=0`.
An errno-only failure never becomes a fictional Vulkan error. Bound/retired success
is errno zero and either no Vulkan result or actual `VK_SUCCESS`. Capability
success requires an actual `VK_SUCCESS`; a partial `VK_INCOMPLETE` list is rejected.

The remaining fields follow the common identity, without padding:

| Record | Fields |
| --- | --- |
| BIND | Nonzero window uint64, boxed instance uint64, width and height uint32; for a phone that declared `seat-routing`, then the seat uint32 (0 owner, 1 agent) and a reserved uint32 zero |
| BOUND | Status |
| QUERY | Nonzero request ID uint64 and boxed physical-device uint64 |
| CAPS | Request ID uint64, status, then capability data only on actual success |
| PRESENT | Serial, boxed device, queue and image (four uint64); format, width, height, actual layout, queue family and wait count (six uint32); boxed binary waits uint64 |
| PRESENT_RESULT | Nonzero serial uint64, status, disposition uint32, event uint32 |
| SOURCE_RELEASED | Nonzero serial uint64 |
| RETIRE | No further fields |
| RETIRED | Status |

BIND width and height may both be zero to request the real initial extent from
the trusted visible owner layer, before the game has a swapchain image. The
actual layer bounds and drawable use the authenticated window metadata’s server
pixel size at contents scale one; a sublayer transform fits the visible view independently. UIKit owns the
container view, not the Metal layer’s pixel coordinate space. Phone screen scale
does not multiply the drawable size. A mixed
zero pair is invalid. A positive pair asserts equality with the actual owner
extent; it cannot set UIKit geometry. Missing, ambiguous or unlaid-out ownership
can wait up to three seconds for real display metadata and view layout to arrive
on the separate channel. A known outstanding window resize must match server
metadata before initial attachment. State changes retry resolution; there is no polling or
synthetic geometry. Expiry returns `EAGAIN`, and executor cancellation returns
`ECANCELED`. Known wrong epochs and ambiguous owners reject immediately. Only
the consumer worker waits; main continues processing display and layout events.
The broker preserves this pair;
it pins the first authenticated compositor BIND epoch to the executor and rejects
subsequent mismatches. The fixed-extent query reports the attached
provider's actual extent. On the variable-extent indexed path, a valid server
pixel-size or owner-view layout change updates the active lease extent and fits
the presentation layer in place so the application can recreate its swapchain at
the new size without revoking the grant.

The native indexed interface also exposes an explicit variable-buffer-extent
query. It retains actual provider min/max limits and the supported format/mode
intersection, and reports `UINT32_MAX` for both current-extent components. The
raw query remains available for the actual attached surface. First opt-in requires
no live swapchain, acquisition, frame or callback worker; later capability queries
do not change an existing swapchain or its configured extent.

Before CREATE on that path, `caboose_gpu_surface_configure_extent` runs on main
with the full bound identity and the exact retained owner layer. It rejects a
live or quarantined swapchain and uses nonblocking locks. A valid extent within
the queried limits changes the dedicated layer's actual pixel bounds,
contents scale and drawable size, preserving its placement transform. Failed
validation leaves the layer unchanged; uncertain mutation fences CREATE until
retirement and detachment. Successful readback records buffer dimensions
separately from authenticated display geometry. The worker then validates the
decoder device against the queried physical device and re-queries real provider
capabilities: its current extent must exactly equal the requested size before
creating the real swapchain. This does not resize an in-use swapchain or implement
old-swapchain replacement. Owner layout must retain the configured buffer extent;
fitting the view does not modify it.

The separately enabled memory-audit build records bounded layer-extent metadata
when the runtime audit opt-in is active. `CABOOSE_GPU_LAYER_EXTENT` stages are
0 before mutation, 1 after bounds, 2 after contents scale, 3 after drawable size,
4 after transaction commit and 5 readback. Event 0 is a snapshot, 1 an exception,
2 a readback mismatch and 3 verified equality. Exception categories are 1 invalid
argument, 2 range, 3 internal inconsistency and 4 other; no exception text is
recorded. The five finite-mask bits describe bounds width/height, contents scale
and drawable width/height. A cleared bit reports unavailable/nonfinite, with a
zero placeholder. Sampling exceptions have their own category. The process emits
at most 64 rows and one overflow marker; the ordinary build emits none. These
observations do not change the configuration or retirement result.

Capability success contains the thirteen uint32 members of
`VkSurfaceCapabilitiesKHR` in specification order, followed by three uint32 counts
for formats, present modes and queue entries. Each count is at most 4096. Format
entries are `(format, colorSpace)` uint32 pairs; modes are uint32; queue entries
are `(family, flags, count, supported)` uint32 tuples. Families are unique, queue
counts are positive and supported is zero or one. These are provider properties;
validation does not turn them into advertised support for an unimplemented path.
Failure ends after the 64-byte identity/request/status prefix. Both success and
failure reject trailing bytes.

PRESENT requires nonzero serial/object handles/format/extents, actual `GENERAL`
layout (1), and at most 64 distinct nonzero binary waits. An image whose extent
differs from the bound surface's is placed in it: a lengthened image (the surface's extent
lengthened along one axis) shows its top-left part, and any other size is scaled to fit
the surface with its aspect ratio, centred; surface pixels it does not cover are black. Decoder ownership and
synchronization checks remain necessary after structural parsing. Disposition is
0 rejected, 1 queued, or 2 uncertain. Event is 0 submission, 1 device lost, or 2
failed-unretired. Device lost requires an actual `VK_ERROR_DEVICE_LOST` (-4);
network errors cannot produce it. Actual positive driver status such as
`VK_SUBOPTIMAL_KHR` remains distinct from the disposition.

SOURCE_RELEASED refers only to completed GPU source reads, not displayed-vsync.
SURFACE_RETIRED success requires GPU/presentation-resource retirement followed by
main-thread layer detachment. Process cleanup must follow that detachment because
the native surface retains a decoder-instance lease. Unknown completion keeps the
reservation and forbids replacement.


## App surface lifecycle

The serial Swift consumer bounds retained surfaces to 32 per executor. It keeps
callbacks behind the corresponding submission receipt, including callbacks made
before native `present` returns. A source-release receipt does not dispose of the
callback: later actual device loss remains reportable. A new accepted or uncertain
native submission joins the prior frame worker; a rejected submission does not.
The indexed Swift adapter retains each accepted serial through its final
PRESENT_RETIRED callback. It then removes the frame record while keeping the
monotonic serial high-water mark. Rejected submissions keep their acquired image
and original wait set available to the caller.

Owner invalidation enters the bounded serial consumer queue and emits kind
35 once for the complete retained grant. When a lease is invalidated, parked,
revoked, or retired, the owner view immediately removes the GPU presentation view
from its superview so the underlying window picture and video path remain visible
without a frozen GPU overlay, while the lease retains its strong reference to the
`CAMetalLayer`-backed view until native surface retirement and detachment finish.
An invalidated lease's layer never returns; a parked one returns to the next
eligible view showing its window. It preserves the process and callback
context until the compositor requests retirement and native cleanup succeeds.
Late local invalidations after retirement are ignored; foreign peer records still
reject. Already-in-transit query or present requests receive a local stale-owner
error while retirement is pending. No successful retirement is inferred from the
request being sent.

App backgrounding suspends a resumable executor in place
([Suspending an executor](#suspending-an-executor)). Any other executor is drained with
bounded UIKit background time; expiration aborts local transport. iOS runs no GPU work in
the background, so such an executor always leaves then, even while the display
connection stays open for sound. The host relay pings the phone every second and ends the relay after 3 s of
silence, so a phone that leaves without closing ends its executor within seconds.
When the executor's streams end, every guest process using it sees
`VK_ERROR_DEVICE_LOST` at once, with no waits and no aborts, and recreates its
instance. With no executor the Caboose ICD fails `vkCreateInstance` and the loader
offers lavapipe. When the phone returns, the executor switch layer
(`guest/gpu/executor-switch`) makes those lavapipe devices report device loss, and
the applications move back onto the phone. Returning to the foreground starts a new
executor. An application launched with `CABOOSE_GPU_ON_LOSS=pause` instead
waits: every call that would report the loss blocks until the broker has a new
executor, then reports `VK_ERROR_DEVICE_LOST`, and the application recreates its device
on the returned phone. That includes a `VK_ERROR_DEVICE_LOST` the phone returns while its
app closes, before the executor's streams end, and a device stream that ends before the
broker has removed the executor's socket: either is held for up to 10 s for the executor
to leave, and taken as a loss of the device alone if it stays. Its devices cannot be
resumed as they were, because their objects lived on the executor that left, so an
application without device-loss recovery, such as a game under DXVK, ends when the phone
returns rather than when it leaves. Computer switches and display takeover
also drain the owner. Ordinary display reconnects keep the same executor. The
app releases its process-wide owner reservation once the executor has ended; the
server fences the old executor (the host relay ends only after both of its sides close,
and the broker revokes the old lease). While the app is in the foreground, an executor
that ends, including after a lost transport, is started again after 1 s, doubling to
30 s, reset by one that ran a minute. That includes an executor whose native cleanup
failed, as after a lost device, and one whose cleanup has not returned 10 s after it
ended (a decoder still blocked in the driver), which counts as failed: the app keeps it,
with whatever native state it still holds, for its lifetime, and a new executor with new
processes and devices takes over. A socket that hears neither a pong nor any message for
10 s ends its executor (3 s, and a resume, when the session is resumable), so a connection
that died silently cannot hold the phone's GPU. A process stop's native retirement runs apart from the
executor's serial worker, so a process whose decoder does not return holds only its own
`PROCESS_RETIRED`; when one has not returned 5 s after its stop, the phone prints
`CABOOSE_GPU_STUCK` with each of its streams' last opcode and stage (1 decoding, 2 writing
replies, 3 reading input, 4 parked).
A guest answers fence and timeline status from the completion feed, so a completion marker
that never completes (its queue waits on a semaphore nobody signals) leaves it spinning with
nothing on the wire. Once a second the phone checks every process; when the oldest marker
has waited 3 s it prints `CABOOSE_GPU_QUEUE_STALL` (outstanding markers, the oldest one's
serial, queue and age, the last completion and the last record sent, whether the feed stream
is attached, and each stream's opcode and stage), followed by one `CABOOSE_GPU_QUEUE` line per
queue: how many submissions it made and how many gfxstream deferred or still holds deferred,
and its last four submissions with their age, fence status, waits (`t<wanted>/now<current>`
for a timeline semaphore, `b/signaled|unsignaled` for a binary one) and signals, semaphores
and fences by their guest handles. While the stall lasts the report repeats every 30 s;
`CABOOSE_GPU_QUEUE_RECOVERED` follows when the marker completes.

When a submission first finds its device lost (Metal failed one of its command buffers, as
with "Invalid Resource": a command buffer used a buffer, image or memory released before
the GPU ran it), the phone prints `CABOOSE_GPU_DEVICE_LOST` with the device and queue, the
same `CABOOSE_GPU_QUEUE` lines, each submission also listing its command buffers by guest
handle (`cbs=`), and `CABOOSE_GPU_RELEASES`: the last 64 buffers, images and memory whose
host objects were released, newest first, as `kind:handle:bytes@age`. MoltenVK asks Metal
for each command buffer's encoder status, so its error lines name the faulting encoder
(`Faulted`) and its kind of work. A lost device ends only its guest process; the phone's
own window pictures never wait for a GPU that has stopped completing work (they are skipped
and `CABOOSE_METAL_STALLED` is printed until it recovers). Over a window whose GPU is lost (a
present reported its device lost) or not responding (a present has waited 2 s for the GPU
to release its source), one line says so, "GPU lost" or "GPU not responding", until it
recovers, with `CABOOSE_GPU_WINDOW_HEALTH window=… state=…` on each change.
The health tracker records a present before calling native submission, so a completion
that arrives before the call returns clears the wait. Rejected submissions remove their
wait; uncertain submissions retain it until source release or device loss.
Each end is printed on standard output as `CABOOSE_GPU_OWNER_ENDED cause=… cleanup=…
retirement_confirmed=0|1`.

A present the phone cannot show is dropped, never waited for on the GPU: MoltenVK's
acquire names an image even when none is free and signals it only when the presentation
engine returns one, which for a layer that is not on screen may be never, and a copy
waiting on that signal would stall until Metal times it out and loses the device. The
phone waits for the acquire's fence on the CPU instead (not at all in mailbox, at most
50 ms in FIFO), reports a present whose image has not arrived as queued and released, and
gives the acquired image to the next present once it has. The host relay logs why it ended any relay early (phone silence, a full
queue, a socket error or an abnormal close), and each side may queue up to 2048 messages
or 8 MiB before a peer that keeps sending past that is ended. The phone stops reading its
socket while its decoder has half of that queued (several applications connecting at once)
and reads again below a quarter; the relay meanwhile holds the guest back, so a slow decoder
never ends the executor.

Native surface preparation, query, present and retirement run off main. Only
layer attachment and detachment are asynchronously dispatched to main; main never
waits for the decoder worker. Failed bind cleanup or retirement keeps its surface
and layer reserved and prevents process finish from bypassing the instance lease.
The controller's tests use injected native boundaries; the package and unsigned
app link checks do not establish physical presentation or game compatibility.

## Presented-picture capture

Frame lab (`CABOOSE_FRAMELAB=1`, `FrameLabPictures`) reads what a live GPU window presents;
without it nothing is captured. With a capture callback set (`caboose_gpu_surface_set_capture`),
each present's copy submission also copies the guest source into one of three device-local
capture images on the presenting device. This happens only when a capture image is free,
and it adds no wait. The images are created with `VK_EXT_metal_objects` export, and the
decoder enables that extension on guest devices where the provider offers it (patch
`0040-guest-device-metal-objects`). A device that cannot export Metal objects presents
without captures.

Once the copy fence has actually signaled, the frame worker passes the present serial, a
token and the image's `MTLTexture` to the callback. The Swift surface hands the texture to
frame lab, which copies it when the window is due, and then releases the token
(`caboose_gpu_surface_release_capture`). Until that
release, the slot is not written again. Tokens carry the ring's generation: a resized or
reformatted picture gets a new ring once no copy writes the old one, and releases for the
old ring are ignored. A copy whose fence outcome is unknown quarantines its slot. Retire
stops captures and destroys the ring with the presenting device's other resources. The
capture never reaches the guest, never changes what is presented, and is not a display
or vsync receipt. `tests/presentation_capture_state_test.cpp` checks slot ownership.

## Indexed swapchain wire

The codec and linked Swift/native adapter cover kinds 25–36, with independent
records in `live-swapchain-vectors.json`. The app adapter requires live hello
version 4, mask `0x70`, and the strongly linked indexed runtime. It rejects the
acquire-at-present behavior of kind 20 and earlier hello versions. The private
Mesa path remains incomplete, and default app session creation does not activate
this adapter. Diagnostic version 2 remains separate.

Each retained surface serializes native creation, mapping, querying, submission
and retirement on an off-main worker. Acquire polling and signal observation use
independent workers so a decoder reset waiting for signal retirement cannot block
the observer needed to release it. The executor bounds these outstanding requests
to 64. Cancellation races preserve a real acquired index; local deadlines remain
distinct from provider results. A present waits for the actual acquire signal
observation and the prior frame retirement before consuming its original waits.
Cleanup cancels pending polls and waits for safe request and frame retirement;
unknown outcomes retain native resources and prevent replacement.

All records retain the common 40-byte surface identity and process envelope
scope. Field sizes below exclude that identity. All integers are little-endian.
Request IDs and present serials are nonzero, monotonic per surface and never
reused. Native-created swapchain IDs are nonzero, strictly increasing and never
reused within a surface; exhaustion fails rather than wrapping.
The native state checks identities, actual image counts and operation ordering;
structural parsing alone does not prove them.

| Kind | Name | Fields after common identity |
| --- | --- | --- |
| 25 | SWAPCHAIN_CREATE | request ID, boxed device, old swapchain ID (3 u64); 14 u32 creation fields; queue-family array |
| 26 | SWAPCHAIN_CREATED | request ID, actual swapchain ID (2 u64); status; actual image count, reserved zero (2 u32) |
| 27 | SWAPCHAIN_MAP | swapchain ID (u64); image count, flags (2 u32); ordered boxed source images (u64 each) |
| 28 | SWAPCHAIN_MAPPED | swapchain ID (u64); status |
| 29 | SWAPCHAIN_ACQUIRE | swapchain ID, request ID, boxed binary semaphore, boxed fence, timeout nanoseconds (5 u64); device mask, reserved zero (2 u32) |
| 30 | SWAPCHAIN_ACQUIRED | swapchain ID, request ID (2 u64); status; has-index, index, local reason, reserved zero (4 u32) |
| 31 | SWAPCHAIN_CANCEL_ACQUIRE | swapchain ID, acquire request ID (2 u64) |
| 32 | SWAPCHAIN_RETIRE | swapchain ID (u64) |
| 33 | SWAPCHAIN_RETIRED | swapchain ID (u64); status |
| 34 | SWAPCHAIN_PRESENT | swapchain ID, serial, boxed queue (3 u64); image index, queue family, actual layout, wait count (4 u32); boxed binary waits (u64 each) |
| 35 | SURFACE_REVOKE_REQUEST | no additional fields |
| 36 | PRESENT_RETIRED | swapchain ID, present serial (2 u64) |

The creation fields, in order, are flags, minimum image count, format, color
space, width, height, array layers, usage, pre-transform, composite alpha,
present mode, clipped, sharing mode, and queue-family count. Exclusive sharing
has no transmitted family list; concurrent sharing has 2–64 distinct families.
The guest rejects unsupported `pNext` rather than dropping it. The native path
honors every accepted parameter or returns an explicit error. Creation has no
queue argument. A nonzero old swapchain names an existing object in the same
surface; it does not authorize early destruction or identity reuse.

Composite alpha is OPAQUE or PRE_MULTIPLIED: the surface capabilities offer exactly those
two (MoltenVK's POST_MULTIPLIED layer is what Core Animation composites as premultiplied,
so it is offered as PRE_MULTIPLIED and created as POST_MULTIPLIED). A premultiplied
swapchain, such as an ARGB menu or tooltip, presents into a non-opaque layer, and the view
under it draws none of the window's own picture, so what is behind the window shows
through its transparent pixels. An opaque swapchain's layer sits on black.

With the `guest-query-pools` capability (hello feature `0x1000`, which requires `0x80`)
the guest also assigns query pool handles (gfxstream fork commit 0041).

MAP flags are 0, or with the `guest-images` capability (hello feature `0x800`) 1 for
guest-owned images or 3 for guest-owned images with mailbox. With guest-owned images the
guest maps its own pool of 1 to 8 images instead of the provider's count. There is no
SWAPCHAIN_ACQUIRE: the guest hands an image to the application once its previous copy
was released, and signals the application's semaphore and fence itself. Each present
names a guest image, and native acquires a provider image inside the present, waiting up
to 1 s, or not at all with mailbox. A present that finds no provider image is dropped: it
reports QUEUED, then releases its source and retires. Up to 8 frames may be in flight.

Creation success carries actual `VK_SUCCESS`, the native ID and the provider's
complete image count (1–256). Failure carries no ID or image count. MAP supplies
exactly that many unique decoder-owned images, with index order matching the
provider. Mapping validates and retains image and backing-memory ownership
atomically. It cannot invent a count from the requested minimum.

ACQUIRE uses the original same-device binary semaphore and/or fence; at least
one is nonzero. The initial device mask is exactly 1. Only actual provider
`VK_SUCCESS` or `VK_SUBOPTIMAL_KHR` can return an index, and the native state must
check it against the created count. Actual timeout-zero polling produces real
`VK_NOT_READY` without an index. Waiting uses a paced monotonic deadline outside
decoder, network and global locks. An unsuccessful local deadline or cancellation
is distinct from provider results: local reason is none (0), deadline (1),
cancelled (2), or other local failure (3), with positive native errno, absent
VkResult and no index for nonzero reasons. This avoids interpreting an Apple errno
number as a Linux errno. The guest maps a confirmed finite local expiry to its
own `VK_TIMEOUT`; it does not relabel it as a provider result.

There is at most one outstanding acquire operation per swapchain. CANCEL
serializes with provider polling and produces the single terminal ACQUIRED reply.
If real acquisition won the race, that reply preserves its index and signals;
cancellation cannot discard them. Cancellation of the latest already completed
request is a no-op, not a second terminal reply. Stale or foreign cancellation
fails. Executor revocation stops polling, but an acquired image and pending
signals remain owned until safely retired. A transport timeout is not proof of
cancellation and cannot allow a retry of an uncertain acquire.

Indexed PRESENT names an acquired mapped image and the application's actual
queue, uses actual `GENERAL` layout, and consumes at most 64 distinct original
binary waits exactly once. Kind 21 and 22 report its surface-wide serial. Native
acquisition and source-copy completion are independent conditions for source
reuse. The native path retains acquire-signal, copy and maintenance1 present
fence records independently, including across reacquisition. Retirement releases
unused acquired images only with the real enabled maintenance extension and
proof their operations are safe (establishing device idle under the host device
mutex when the guest process exited or the surface was revoked before an explicit
idle call); unknown completion quarantines the resources.

PRESENT_RETIRED is a final per-frame receipt after the actual copy and maintenance1
present fences succeed, frame resources are destroyed and the native frame record
is removed. It is not display timing or a new acquisition. Native callback event
4 is the last callback for that serial; the context remains valid until that
callback returns. The adapter serializes any early callback after the submission
result and source release before sending kind 36. The broker and guest can then
remove the matching active record; a monotonic serial high-water mark rejects
replay without retaining an unbounded history. A rejected unsubmitted frame is
removed after its rejection. Device loss or uncertain retirement cannot produce
kind 36, and source release alone cannot discard a possible later failure event.

Kind 35 travels from the authenticated phone to the broker for an existing
surface. The broker notifies its owning local WSI socket with CGLS kind 35 and
requests compositor revocation through CGB kind 8. Compositor kind 3 precedes
native SURFACE_RETIRE; only successful SURFACE_RETIRED permits CGB kind 7 and a
fresh grant. This revokes one surface without retiring its process. Background
or computer replacement still drains the executor. CGLS requests for kinds
25, 27, 29, 31, 32 and 34 omit the common identity; the authenticated broker adds
it. Replies retain the full native payload. The CGLS parser does not activate
these operations or imply that a native implementation exists.

The opt-in memory-audit package records at most 64 decoder calls taking 50 ms or longer per runtime process. Each record contains a local stream ordinal, opcode and elapsed time; the pinned command-buffer host-sync call also includes its two numeric ordering fields. It also records up to 64 stream totals and 128 two-second samples per runtime process, counting decode time (including mapped-memory flushes), socket read wait and bytes, and reply flush time. Counters saturate instead of wrapping. Stream wait includes time when the guest has no work and does not identify a transport fault by itself. Handles, addresses and command contents are excluded. Execution and timeout behavior are unchanged.

## Applications

The owner's display started with the private GPU sockets
(`--private-gpu-stream-socket`, `--private-gpu-surface-socket`) routes its applications to
the phone's GPU through their launch environment, when the driver is installed: `python3
guest/gpu/install-live.py --driver libvulkan_gfxstream.so` puts it and its loader manifest
in `/usr/local/lib/caboose-gpu-live`, a directory no Vulkan loader searches by itself. No
application is configured individually; each toolkit's own GPU path reaches the driver.

| Applications | Path to the phone's GPU |
| --- | --- |
| Vulkan, Wayland or X11 | `VK_ADD_DRIVER_FILES` adds the driver to the computer's own; the routing layer (`guest/gpu/routing-layer`, enabled by `CABOOSE_GPU_ROUTING=1` in place of Mesa's device-select layer) lists the phone's GPU first and CPU renderers such as lavapipe last. `CABOOSE_GFXSTREAM_SOCKET` and `CABOOSE_GFXSTREAM_SURFACE_SOCKET` name the broker's sockets. |
| GTK 4 | `GSK_RENDERER=vulkan`. |
| Qt 6 Quick | `QSG_RHI_BACKEND=vulkan`. |
| Chromium-based (Chromium, Electron, CEF) | Nothing of their own: they are X11 clients by default and draw with ANGLE on OpenGL, which reaches the driver through Zink, as every OpenGL application does. Their GPU process keeps Chromium's sandbox; the driver's broker connection works inside it. |

Once a second, while it changes, the broker writes each local process's GPU use beside its
local socket as `usage.json` (mode 0600): `{ version: 1, processes: [{ pid, start,
streams, surfaces, toPhoneBytes, fromPhoneBytes }] }`, `start` the process's start time in
clock ticks (`/proc/<pid>/stat` field 22) and the byte counts cumulative over the current
session. Counters only, no payloads, handles or names; the task manager's app scopes
([architecture.md](architecture.md#guest-services)) sum them per app. The file is removed
when the broker stops.

The task manager also reads `placement/` in the same directory: one file per process, named
by its pid as the process sees it (a Flatpak sandbox's own pid namespace), holding
`<placement> <start>`. It matches a file to its process by pid and start time, else by start
time alone, and ignores files that match nothing.

The broker listens on its local socket only while a phone's executor is ready. With no
phone the driver fails its Vulkan instance and the loader continues with the computer's
drivers, and the routing layer presents lavapipe as a virtual GPU named `Caboose GPU (no
phone attached)`: applications that pick their rendering path once at launch take their GPU
paths on it, so a computer started or relaunched without the phone draws the same way it
will on the phone.
Those applications draw on the computer and reach the phone as pictures, like every
application that draws on the CPU. With `CABOOSE_GPU_EXECUTOR_SWITCH=1` in the launch
environment, the executor-switch layer (`install-live.py --executor-switch`) makes every
process's lavapipe devices lose themselves once a phone's executor is ready, and the
processes move to the phone. A process launched with `CABOOSE_GPU_ON_LOSS=pause` keeps its
lavapipe device until it is relaunched and is listed in the running-apps API with
`gpuPlacement: "cpu-until-relaunch"`, so the phone can offer to relaunch it on its GPU.
No application is treated differently from another: the CPU implementation is only the
fallback while no phone is attached.

When the phone goes away, the driver follows the process's `CABOOSE_GPU_ON_LOSS`:
`pause` holds the application until the phone returns; any other value, the launch
environment's `auto` included, reports device loss at once, and an application that recovers
keeps running on the computer. An executor that suspends while the phone app is in the
background (hello feature `0x4000`) is not lost, so neither applies then.

OpenGL reaches the phone through Zink, Mesa's OpenGL on Vulkan: `LIBGL_KOPPER_DRI2=1` for
GLX, which tries Zink before any software renderer, and `GALLIUM_DRIVER=zink` for EGL's
software path (Chromium's and CEF's ANGLE among its users), which otherwise prefers Mesa
D3D12 (WSL's `/dev/dxg`) and llvmpipe. With no phone attached Zink renders on the CPU
device the routing layer presents as a GPU, so OpenGL always has a renderer, and an
application that recovers from device loss moves to the phone when it attaches. Zink presents through the
driver's X11 windows (Kopper); without a DRM render node it cannot present through
Wayland, so toolkits that draw with OpenGL run as X11 clients on this seat:
`QT_QPA_PLATFORM=xcb;wayland` (Qt 5 Quick) and `SDL_VIDEODRIVER=x11,wayland`. A Wayland
client that draws with OpenGL gets EGL's software platform: Zink renders, and each frame
reaches the compositor as shared memory. Mesa reports that renderer as unaccelerated, so an
application that declines unaccelerated OpenGL draws with its own CPU renderer. The driver offers the logic operations and
custom border colours Zink needs for desktop OpenGL where the phone lacks them
(`gfxstream/feature-emulation`). The phone has no geometry shaders or transform feedback,
for which Zink would offer only OpenGL 2.1 and OpenGL ES 2.0: `MESA_GL_VERSION_OVERRIDE=4.5COMPAT`,
`MESA_GLSL_VERSION_OVERRIDE=450` and `MESA_GLES_VERSION_OVERRIDE=3.2` offer what the computer's
renderer offers without a phone, and a shader that uses either feature fails to compile or draw. Zink settles its descriptor mode once per process, on the first
device it opens: the CPU device has descriptor buffers and the phone's GPU has none, so a
process that started without a phone would fail every later renderer on it.
`ZINK_DESCRIPTORS=lazy`, set for applications and for caboose-display itself, keeps one mode
on both.

32-bit applications take the same paths. The driver and both layers are also built for
i386 (`gfxstream/driver/build.sh` writes `i386/libvulkan_gfxstream.so`; the layers build
with `make CXX=i686-linux-gnu-g++`), and `install-live.py`, given those builds too, puts
them in `/usr/local/lib/caboose-gpu-live/i386` with their own manifests; the launch
environment names both drivers in `VK_ADD_DRIVER_FILES`, and each process's loader passes
over the one of the other architecture. The i386 layers are named
`VK_LAYER_CABOOSE_gpu_routing_32` and `VK_LAYER_CABOOSE_executor_switch_32`: the Vulkan
loader keeps one layer of a name, whatever its library's architecture. Without the i386
routing layer a 32-bit process would see lavapipe as a CPU device, which Zink refuses,
and with `GALLIUM_DRIVER=zink` have no OpenGL renderer at all.

Flatpak applications take the same paths inside their sandbox. `install-live.py
--driver` also installs the driver as the unmaintained `org.freedesktop.Platform.GL.host`
extension (version 1.4, which Flatpak enables for every runtime built on the Freedesktop
runtime), whose Vulkan manifest the sandbox's loader finds among its runtime's drivers,
and the i386 builds as `org.freedesktop.Platform.GL32.host`, for the runtime's 32-bit
compatibility libraries,
and adds `xdg-run/caboose-gpu`, the broker's socket directory, to the system-wide Flatpak
override. Mesa in the sandbox opens the render node with Zink as Mesa on the computer does
([gpu-buffers.md](gpu-buffers.md#opengl-on-the-render-node)). `install-live.py --gbm` puts the
vgem GBM backend in each extension's `lib/gbm` and sets `GBM_BACKENDS_PATH` in that override,
so GBM in the sandbox allocates and exports buffers as on the computer
([gpu-buffers.md](gpu-buffers.md)). The launch environment's variables pass into the sandbox unchanged;
`PRESSURE_VESSEL_FILESYSTEMS_RW` names the socket directory to Steam's container runtime,
which shares no other part of the runtime directory with games.

`guest/gpu/check-apps.sh` checks each path in a disposable container
([guest/gpu](../guest/gpu/README.md#application-routing-check)).
