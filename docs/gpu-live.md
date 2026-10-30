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

One pending or active executor is admitted per computer. Closing both relay
sockets releases the host transport reservation; it does not prove native
resource retirement. Guest admission remains fenced until the old generation's
native cleanup is complete. Local applications are bound through kernel Unix
peer credentials, a retained peer pidfd and process start time, not a claimed
PID. Those credentials identify the socket creator; transferring the descriptor
does not authenticate a new writer.

## Envelope

All integers are little-endian. UUID bytes are in standard UUID byte order.
WebSocket message boundaries have no framing meaning. A receiver retains at most
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

Kinds 14 and 15 are reserved and rejected.

Session scope has zero process and stream IDs. Process scope has a nonzero
process and zero stream ID; stream scope has both nonzero. Process and stream IDs
are monotonic and never reused within a generation. The initial admission limits
are 16 active processes and 64 active streams; retirement releases capacity without
resetting identity counters.

The live hello is ASCII `CBGLREF1`, little-endian version 3, mask `0x30`, and the
32-byte source tuple fingerprint
`20d3bb2e30337cabf0febb006ed102ab25ccf6d9ddbfaf624c7e68f9040969c0`.
Bit 4 requires actual `VulkanNullOptionalStrings`; bit 5 requires the explicit
private virtual-WSI mode. The other bits remain zero. The source fingerprint pins
the base sources, not general schema compatibility or hostile-input safety.
The separate version-2 diagnostic does not negotiate virtual WSI and is rejected
by this live contract. The versioned native start symbol prevents a retained
non-WSI framework from claiming this mode.

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

The first presentation implementation is restricted to native Wayland surfaces.
Only the compositor can bind an actual client/surface to a current owner window;
an application-provided window number or X11 `_NET_WM_PID` is not authority.
The app's visible interactive owner view supplies the native layer; thumbnails
cannot acquire it. `LiveGPUOwnerSession` explicitly constructs the owner registry
and linked surface backend; ordinary display and agent sessions do not. The
registry matches the display epoch, window object and one visible eligible view.
The executor survives an ordinary display reconnect; losing its owner, changing
extent or moving to the background revokes admission. This path is not enabled
by the app's default session creation, and its native presentation runtime remains
unvalidated.
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
the trusted visible owner layer, before the game has a swapchain image. A mixed
zero pair is invalid. A positive pair asserts equality with the actual owner
extent; it cannot set UIKit geometry. Missing, ambiguous or unlaid-out ownership
can wait up to three seconds for real display metadata and view layout to arrive
on the separate channel. State changes retry resolution; there is no polling or
synthetic geometry. Expiry returns `EAGAIN`, and executor cancellation returns
`ECANCELED`. Known wrong epochs and ambiguous owners reject immediately. Only
the consumer worker waits; main continues processing display and layout events.
The broker preserves this pair;
it pins the first authenticated compositor BIND epoch to the executor and rejects
subsequent mismatches. CAPS reports the attached
provider's actual extent. A resize revokes the generation and requires retirement
and detachment before replacement.

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
The Swift adapter retains at most the prior and attempted serial during that call.

Native surface preparation, query, present and retirement run off main. Only
layer attachment and detachment are asynchronously dispatched to main; main never
waits for the decoder worker. Failed bind cleanup or retirement keeps its surface
and layer reserved and prevents process finish from bypassing the instance lease.
The controller's tests use injected native boundaries; the package and unsigned
app link checks do not establish physical presentation or game compatibility.
