# Live GPU transport

The live GPU source is separate from the GFXReconstruct capture protocol in
[gpu-stream.md](gpu-stream.md). Its bounded codec is implemented in
`guest/gpu/broker/live_protocol.py`, with byte-exact vectors in `live-vectors.json`.
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
cannot acquire it. The surface and presentation control path is incomplete and
is not advertised by the envelope codec. Neither a WebSocket send, a queue-submit
return nor a local cleanup callback means an image was displayed.
