# Live GPU transport

The live GPU source is separate from the GFXReconstruct capture protocol in
[gpu-stream.md](gpu-stream.md). Its bounded codec is implemented in
`guest/gpu/broker/live_protocol.py` and CabooseKit’s `LiveGPUEnvelope`, with byte-exact
vectors in `live-vectors.json` and `live-surface-vectors.json`.
It does not activate a general Vulkan driver or provide window presentation.

## Connection and authority

The host route is `/v1/gpu`, without query parameters, using the exact WebSocket
subprotocol `caboose.gpu.live.v1`. It relays to the owner's display service `/gpu`
on its existing port. There is no agent-seat GPU route. WebSocket messages are
binary, uncompressed, at most 256 KiB, with at most 1 MiB and 64 pending messages
in each direction. Vulkan replies use this connection independently of media.

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
| 37 | TRANSPORT_CONFIG | Session | Algorithm u32 = 1, maximum decoded record u32 = 65600 |
| 38 | TRANSPORT_READY | Session | Exact matching configuration |
| 39 | SWAPCHAIN_PRESENT_ORDERED | Process | Kind 34's fields plus a device-stream order mark |

Kinds 14 and 15 are reserved and rejected.

Session scope has zero process and stream IDs. Process scope has a nonzero
process and zero stream ID; stream scope has both nonzero. Process and stream IDs
are monotonic and never reused within a generation. The initial admission limits
are 16 active processes and 64 active streams; retirement releases capacity without
resetting identity counters.

### Optional bounded command compression

With `CABOOSE_PRIVATE_GPU_DEFLATE=1`, the indexed v4 broker sends TRANSPORT_CONFIG
after SESSION_READY and waits for the exact TRANSPORT_READY before publishing
local sockets or reporting compositor readiness. Duplicate, unsolicited or late
negotiation terminates the session. The Vulkan hello and native runtime mode do
not change. The opt-in is invalid for older modes; without it, transport stays raw.

After this exchange, each broker-to-phone WebSocket message contains exactly one
whole CGLV envelope or one CGLZ record. CGLZ uses a 16-byte little-endian header:
`magic[4]="CGLZ", version:u16=1, algorithm:u16=1, decodedBytes:u32,
compressedBytes:u32`, followed by one independent raw RFC 1951 DEFLATE stream.
There is no shared dictionary. `decodedBytes` is 65 through 65600,
`compressedBytes` exactly matches the remaining message, and the whole compressed
record must be smaller than its decoded bytes. The decoded bytes must be exactly
one CGLV DATA envelope with 1 through 65536 payload bytes. Its original identity,
scope and sequence pass through the existing decoder unchanged. Control messages,
concatenated envelopes, truncated streams, extra bytes after DEFLATE end-of-stream,
and output-length mismatches are rejected. Ordinary DATA is used when compression
does not reduce size. Phone replies remain raw, and WebSocket extensions remain
forbidden on both hops.

Phone-to-broker replies can concatenate a ready FIFO prefix of raw CGLV envelopes
into one WebSocket message, preserving envelope sequences and stream order. The
first available reply sends immediately; batching adds no timer. A batch contains
at most 64 admitted records and 256 KiB. The outbound 1 MiB budget retains all
original byte/count permits and reserves the concatenation buffer before allocation,
keeping both charges until send completion. Insufficient scratch capacity sends
the first record alone. Closing discards pending records but retains in-flight
charges until their completion callback. These are logical retained-byte limits,
not physical allocator or RSS limits.

The broker charges the original uncompressed WebSocket frame until its send
completes. Before queuing compressed work, the phone reserves the wire size plus
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

## Phone capabilities and local features

The phone app names the capabilities of its native decoder in the
`X-Caboose-GPU-Features` request header, a comma-separated list. The host forwards
only known names, lowercased and sorted: `guest-handles`, `guest-handle-arrays`,
`completion-feed` and `ordered-present`. The broker reads them from the authenticated
upgrade request.

A local process on the indexed v4 path may offer optional features in its 48-byte
hello by setting bits above the required mask `0x70`: `0x80` (guest-assigned handles),
`0x100` (guest-assigned descriptor sets and command buffers; requires `0x80`) and
`0x200` (completion feed) and `0x400` (ordered presents). The broker replies with the
required mask plus the offered bits whose capability the phone declared (`guest-handles`,
`guest-handle-arrays`, `completion-feed`, `ordered-present` respectively); it drops
`0x100` when it does not grant `0x80`. An
offer with unknown bits, `0x100` without `0x80`, or any other difference from the v4
hello closes the local connection. A process falls back to offering fewer features.

### Guest-assigned handles

With `0x80`, a create command carries an output handle the process chose, with `0xCA`
in its top byte, a 24-bit per-process tag and a 32-bit counter. The decoder registers
the object under that value instead of minting one, so the process continues without
waiting for the reply; it reads the reply later and treats a refused or renamed handle
as device loss. This covers device memory, fences, semaphores, buffers, images and
views, samplers, shader modules, pipeline caches and layouts, descriptor set layouts
and pools, command pools, render passes, framebuffers and pipelines. With `0x100` it
also covers descriptor sets and command buffers: the decoder registers the i-th created
object under the i-th guest handle. A descriptor set allocation whose handles the guest
assigned never fails for lack of pool space: when the application's pool reports
`VK_ERROR_OUT_OF_POOL_MEMORY` or `VK_ERROR_FRAGMENTED_POOL`, the decoder allocates the
sets from an overflow pool it creates with the same flags and sizes. Overflow pools are
reset and destroyed with their application pool, and their sets are freed back to them.

### Completion feed

With `0x200`, the process opens one more local stream with the same hello. After the
client-flags word it sends a single `COMPLETION_FEED` command and nothing else. Both
completion commands use the ordinary 8-byte packet header, little-endian:

| Command | Opcode | Size | Payload |
| --- | --- | --- | --- |
| COMPLETION_FEED | `0x4342FE01` | 16 | version u32 = 1, reserved u32 = 0 |
| COMPLETION_WATCH | `0x4342FE02` | 24 | boxed queue u64, serial u64 (both nonzero) |
| COMPLETION_ORDER | `0x4342FE03` | 16 | order serial u64 (nonzero) |

After each queue submission that signals a fence or timeline semaphore, the process
sends `COMPLETION_WATCH` with a new serial on the same device stream; neither command
has a reply on its own stream. The decoder serves both commands itself. For a watch it
submits, under the queue's lock, an empty batch whose new fence signals once all work
submitted to that queue before it has completed, holding the queue's instance and
device alive until a watcher thread has waited for and destroyed that fence. Queues of
another process and virtually shared queues are not watched. On the feed stream the
phone writes one 16-byte record per watch: serial u64, status i32 and reserved u32
zero. Status 0 means the work completed, `-4` the device was lost, and `1` the queue
cannot be watched. Records may arrive in any order. Watches made before the feed stream
attaches are kept for it. Further bytes from the process on the feed stream are a
protocol error; its end, or process stop, ends the feed. Watches still outstanding are
waited for, and their records discarded.

The process then knows the state of every fence and timeline semaphore whose signal
operations it has seen. `vkGetFenceStatus`, `vkWaitForFences`,
`vkGetSemaphoreCounterValue` and `vkWaitSemaphores` resolve locally, waiting for feed
records without holding the device stream. A fence or semaphore whose payload is
imported or exportable, a fence signaled by the presentation engine's acquire, sparse
binding signals and unwatched queues are asked about on the device stream as before.
A reported timeline value can trail the device's actual value, as a status query on any
device can; it never exceeds it.

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

## Readiness and retirement

The broker sends SESSION after the WebSocket upgrade. SESSION_READY requires
actual native initialization and exact feature agreement. PROCESS_READY requires
successful native process creation. STREAM_READY reserves the bounded socketpair
and run/read workers for that process; it does not mean decoder TLS admission,
command execution or GPU completion. A subsequent run failure revokes the lease.
The private hello is consumed at session negotiation; DATA begins with the real
upstream client-flags word and ordered command bytes.

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
(`SWAPCHAIN_CANCEL_ACQUIRE`), request compositor grant revocation (`RevokeRequest`),
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
force local cleanup but cannot produce a remote-retirement receipt. Abrupt loss
leaves the guest generation unavailable until actual old-executor retirement or a
verified backend restart; reconnect never replays stale handles or command history.

## Window identity boundary

The optional owner display hello field `gpu_live_epoch` is exactly 16 nonzero
CBOR bytes. It identifies the compositor's private-service instance and is absent
when that service is unavailable. A broker loss revokes its grants and invalidates
the display association. A new epoch does not erase outstanding native work.

A surface bind names a native Wayland surface or an X11 window on the display's
Xwayland: the trailing 32-bit field of the CGLS bind request and of the CGB1 bind
record is the object's namespace, 0 for a `wl_surface` protocol ID and 1 for an X11
window ID; any other value is malformed. Only the compositor can bind an actual
client/surface to a current owner window; an application-provided window number or
X11 `_NET_WM_PID` is not authority.

- A Wayland bind matches a toplevel whose own `wl_surface` has that ID and whose
  accepted Wayland peer is the bound process (its held pidfd and the broker's).
- An X11 bind matches a managed, non-override-redirect X11 toplevel that is the
  window or that the window covers exactly (a descendant at the toplevel's origin
  with its size, as Chromium's GPU process draws into). The X server's own record of
  the client that created the window (X-Resource `LocalClientPID`) must be the bound
  process, the broker's pidfd must identify that live process (PID, start time and
  owner), and the owner must be the compositor's user. The grant is the toplevel's
  window, which is configured to the display's extent like a Wayland toplevel.
  X11 has no client isolation: any client of the seat's Xwayland can create a child
  window inside another's toplevel, so an X11 grant proves only that the bound
  process made the window it presents to on the owner's own display.
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
surface grant or dropping the executor. A changed display epoch or window object,
or invalid/zero server geometry, requests revocation of only the affected surface
(`SURFACE_REVOKE_REQUEST`). Background or computer
replacement drains the entire executor. This path is not enabled
by default. Debug builds opt in with `CABOOSE_PRIVATE_GPU_INDEXED=1`; the owner
AppModel then opens the existing authenticated host endpoint and updates the
registry from its ordinary display. Agent and thumbnail sessions never create an
executor. Native presentation runtime remains unvalidated.
Neither a WebSocket send, a queue-submit return nor a local cleanup callback means
an image was displayed.


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
| BIND | Nonzero window uint64, boxed instance uint64, width and height uint32 |
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
layout (1), and at most 64 distinct nonzero binary waits. Decoder ownership and
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

App backgrounding requests bounded UIKit background time for graceful executor
drain; expiration aborts local transport. iOS runs no GPU work in the background, so
the executor always leaves then, even while the display connection stays open for
sound. The host relay pings the phone every second and ends the relay after 3 s of
silence, so a phone that leaves without closing ends its executor within seconds.
When the executor's streams end, every guest process using it sees
`VK_ERROR_DEVICE_LOST` at once, with no waits and no aborts, and recreates its
instance. With no executor the Caboose ICD fails `vkCreateInstance` and the loader
offers lavapipe. When the phone returns, the executor switch layer
(`guest/gpu/executor-switch`) makes those lavapipe devices report device loss, and
the applications move back onto the phone. Returning to the foreground starts a new
executor. Computer switches and display takeover
also drain the owner. Ordinary display reconnects keep the same executor. The
app releases its process-wide owner reservation only after native cleanup, its
REVOKED receipt, and a normal broker WebSocket close. Local abort, transport loss
or failed cleanup retains the reservation and never triggers automatic retry.

Native surface preparation, query, present and retirement run off main. Only
layer attachment and detachment are asynchronously dispatched to main; main never
waits for the decoder worker. Failed bind cleanup or retirement keeps its surface
and layer reserved and prevents process finish from bypassing the instance lease.
The controller's tests use injected native boundaries; the package and unsigned
app link checks do not establish physical presentation or game compatibility.

## Presented-picture capture

The owner view's [phone-owned scrolling](display.md#phone-owned-scrolling) reads what a
live GPU window presents. With a capture callback set (`caboose_gpu_surface_set_capture`),
each present's copy submission also copies the guest source into one of three device-local
capture images on the presenting device. This happens only when a capture image is free,
and it adds no wait. The images are created with `VK_EXT_metal_objects` export, and the
decoder enables that extension on guest devices where the provider offers it (patch
`0040-guest-device-metal-objects`). A device that cannot export Metal objects presents
without captures.

Once the copy fence has actually signaled, the frame worker passes the present serial, a
token and the image's `MTLTexture` to the callback. The Swift surface hands the texture to
its owner view on main. The view's scroll controller copies it into its own history
texture and then releases the token (`caboose_gpu_surface_release_capture`). Until that
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
| 27 | SWAPCHAIN_MAP | swapchain ID (u64); image count, reserved zero (2 u32); ordered boxed source images (u64 each) |
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
