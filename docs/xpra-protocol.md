# Xpra seamless protocol research

This document is under verification against Xpra 6.5.5; it is not yet a complete
client contract. Source references below are pinned to the 6.5.5 release. The guest image builder
pins `xpra 6.5.5-r0-1` and configures `XPRA_BACKWARDS_COMPATIBLE=0` with Xpra’s
file authenticator. The complete image and host lifecycle still require a
successful end-to-end test.

## Transport and framing

Use a WebSocket binary stream, with subprotocol `binary`. WebSocket message
boundaries are not Xpra packet boundaries: buffer bytes across messages and parse
repeatedly. Each Xpra frame starts with `50 flags compression index size`, where
`50` is ASCII `P`, each of the next three fields is one byte, and `size` is a
32-bit unsigned big-endian payload byte count. Reject malformed headers, excessive
lengths, unsupported flags and incomplete packets on close.

For an encoded main packet, flags include `0x10` (rencodeplus), optionally
`0x08` (flush), and `0x02` indicates Xpra packet encryption. Compression byte 0
means no network compression; nonzero has the level in the low nibble and the
algorithm in the high bits: `0x10` LZ4, `0x40` Brotli. Picture encoding and
pixel compression are separate from this network compression. Advertise
`encoders: ["rencodeplus"]`, `compressors: []` and no legacy `lz4`/`brotli`
capabilities to disable network compression; also omit `encoding.rgb_lz4` to
avoid separately compressed raw RGB. Verify server behavior before assuming
this applies to a different Xpra release.

Index 0 is the rencodeplus-encoded main packet, a list whose first member is a
packet name. An index greater than 0 is a raw chunk: receive and decompress it
according to its header, retain it, then when the following main packet arrives
replace the zero-based list member at that index with those bytes. Multiple
chunks can precede the same main packet. Do not interpret chunks as rencodeplus.
Do not advertise aliases unless integer packet names are implemented. See
[upstream framing](https://github.com/Xpra-org/xpra/blob/v6.5.5/docs/Network/Protocol.md)
and [header implementation](https://github.com/Xpra-org/xpra/blob/v6.5.5/xpra/net/protocol/header.py).

## rencodeplus

All hex below is bytes, not ASCII hex. Integers are signed two's complement;
multibyte integers and IEEE 754 floats are big-endian. Lengths count UTF-8 bytes,
not characters. Containers recursively contain encoded values.

| Code | Meaning | Example |
| --- | --- | --- |
| `00`–`2b` | Integer 0–43 in code | `2b` = 43 |
| `46`–`65` | Integer -1–-32, value `-(code - 0x46 + 1)` | `46` = -1 |
| `3e`, `3f`, `40`, `41` | Signed integer in next 1, 2, 4, 8 bytes | `3e 80` = -128; `3f 00 80` = 128; `40 00 01 00 00` = 65536; `41 00 00 00 01 00 00 00 00` = 4294967296 |
| `3d` | ASCII decimal arbitrary integer followed by `7f`, fewer than 64 decimal characters | `3d 39 32 32 33 33 37 32 30 33 36 38 35 34 37 37 35 38 30 38 7f` = 9223372036854775808 |
| `42`, `2c` | IEEE float32 / float64 | `42 3f 80 00 00` = 1; `2c 3f f0 00 00 00 00 00 00` = 1 |
| `43`, `44`, `45` | true, false, none | `43` = true |
| `80`–`bf` | UTF-8 string with length `code - 0x80` | `82 68 69` = "hi" |
| ASCII `length:` | UTF-8 string with decimal byte length | `32 3a c3 a9` = "é" |
| ASCII `length/` | byte array with decimal byte length | `32 2f 00 ff` = two bytes |
| `c0`–`ff` | list of `code - 0xc0` values | `c2 01 43` = [1, true] |
| `3b` … `7f` | terminated list | `3b 01 43 7f` = [1, true] |
| `66`–`7e` | dictionary of `code - 0x66` key/value pairs | `67 81 61 01` = {"a": 1} |
| `3c` … `7f` | terminated dictionary, alternating keys and values | `3c 81 61 01 7f` = {"a": 1} |

The reference encoder uses fixed strings for fewer than 64 UTF-8 bytes, fixed
lists for fewer than 64 items and fixed dicts for fewer than 25 entries; bytes
always use `length/`. It chooses the smallest signed integer width and uses
float64 for encoding, although float32 is decoded. Termination markers belong
only to variable-length containers and decimal integers, never to fixed-length
containers. Place limits on depth, sizes, integer length and allocation, and
reject invalid UTF-8, invalid decimal lengths, truncated values, trailing data and
unmatched dictionary keys. [Reference implementation](https://github.com/Xpra-org/xpra/blob/v6.5.5/xpra/net/rencodeplus/rencodeplus.pyx).

## Hello and authentication

Each endpoint sends `["hello", capabilities]`. In 6.5.5 the reference client
advertises `encoders` and `compressors` at top level, window capabilities under
`window`, and encoding details under `encoding`. Backward compatibility also
uses `windows` and `encodings`. `encoding.core` is the list of actual wire
encodings; `encoding.options` uses `rgb` for the two wire formats `rgb24` and
`rgb32`. `encoding.full_csc_modes` maps video encoding names to supported
colorspaces. `encoding.video_b_frames: []` is essential to avoid advertising
B-frame decoding; 6.5.5 only enables B-frames when `h264` appears there and
other server-side conditions hold. `encoding.rgb_formats` must list only formats
the client can actually paint. The reference client includes `display` and
legacy top-level screen capabilities, and `keymap` plus `keyboard: true` for
keyboard input. Exact interoperability and minimum capability values are not yet
verified, so do not use this as a complete hello template.

The guest-image work configures the file authenticator on the WebSocket listener,
with the per-boot token in `/run/caboose/xpra-token` owned by `caboose` and mode
`0600`. The file authenticator reads the entire UTF-8 file, including any newline.
The initial hello must include a username matching the server user (the test
server rejected missing and mismatched usernames). For the Xpra 6.5.5 HMAC
password authenticator, the reference client advertises `digest` and `salt-digest`, sends an initial hello containing
`challenge: true`, and receives `["challenge", serverSalt, cipherCaps,
digestName, saltDigestName, ...]`. For example, advertise only `hmac+sha256` in
both lists. Generate a cryptographically random 32-byte client salt. The combined
salt is the **lowercase ASCII hex** representation of
`HMAC-SHA256(key=clientSalt, message=serverSalt)`. The response is the lowercase
ASCII hex representation of `HMAC-SHA256(key=UTF8(password), message=combinedSalt)`.
Send another hello with the full capabilities plus byte arrays
`challenge_client_salt` and `challenge_response`; the standard client also sends
random `challenge_padding`. This exchange requires an authenticated WSS transport
and must not use XOR or DES challenges. It does not establish or replace TLS.
A live 6.5.5 file-auth test selected `hmac+sha256` for both digests and
accepted this calculation with the matching server username; the guest token
lifecycle still needs an end-to-end check. Sources: [challenge client](https://github.com/Xpra-org/xpra/blob/v6.5.5/xpra/client/base/challenge.py),
[digest](https://github.com/Xpra-org/xpra/blob/v6.5.5/xpra/net/digest.py),
[server auth](https://github.com/Xpra-org/xpra/blob/v6.5.5/xpra/auth/sys_auth_base.py).

## Packet names in 6.5.5 (source inventory; not all exercised)

The upstream default server has `XPRA_BACKWARDS_COMPATIBLE` enabled; the updated
Caboose guest service disables it. The table describes the upstream default. The outgoing names
below are the default spellings. Client-to-server names are the names accepted
by that configuration; pairs are alternatives only where the server registers a
legacy alias or a separate legacy parser. A dash means the operation is not
sent in that direction. Subsystem configuration and hello capabilities determine
whether an otherwise registered packet is usable.

| Server sends | Server accepts |
| --- | --- |
| `hello`, `challenge` | `hello` |
| `new-window`, `new-override-redirect` | — |
| `window-metadata`, `lost-window`, `window-icon`, `window-move-resize`, `window-resized`, `raise-window`, `bell` | — |
| `draw` | `damage-sequence` / `window-draw-ack` |
| — | `map-window` / `window-map`, `configure-window` / `window-configure`, `close-window` / `window-close`, `focus` / `window-focus`, `buffer-refresh` / `window-refresh` |
| — | `pointer-position`, `pointer` / `pointer-motion`, `button-action`, `pointer-button`, `wheel-motion` / `pointer-wheel` |
| — | `key-action`, `keyboard-event`, `keyboard-config`, `keymap-changed`, `layout-changed` |
| `clipboard-token`, `clipboard-request`, `clipboard-contents`, `clipboard-contents-none` | same four clipboard names |
| `ping`, `ping_echo` | `ping`, `ping_echo` |
| `notify_show`, `notify_close` | `notification-close`, `notification-action`, `notification-status`, `set-notify` |
| `cursor` (or `cursor-data` / `cursor-default` when client explicitly disables cursor backwards compatibility) | `set-cursors` / `cursor-set` |
| `startup-complete`, `disconnect`, `desktop_size` | `disconnect` / `connection-close`, `desktop_size`, `configure-display` / `display-configure`, `suspend`, `resume` |

`wants: ["packet-types"]` requests the server's list of accepted packet names;
it does not switch the server's outgoing names. In this release outgoing window
names are chosen by the server's process-wide `XPRA_BACKWARDS_COMPATIBLE`, not
by client `protocol-version`. The server source checks the `version` string,
and does not read a client `protocol-version`; do not assume that this remains
true in future versions. Cursor output is separately negotiated. See
[packet types](https://github.com/Xpra-org/xpra/blob/v6.5.5/xpra/net/packet_type.py),
[window handlers](https://github.com/Xpra-org/xpra/blob/v6.5.5/xpra/server/subsystem/window.py),
[pointer handlers](https://github.com/Xpra-org/xpra/blob/v6.5.5/xpra/server/subsystem/pointer.py),
[keyboard handlers](https://github.com/Xpra-org/xpra/blob/v6.5.5/xpra/server/subsystem/keyboard.py),
and [server hello](https://github.com/Xpra-org/xpra/blob/v6.5.5/xpra/server/core.py).

Packet arguments exclude the packet-name string. `damage-sequence` and
`window-draw-ack` take `(packetSequence, windowID, width, height, decodeTimeMicroseconds,
message?)`; the client must acknowledge each draw after decode/paint, including
failed decodes, because server congestion and latency statistics depend on it.
`pointer-motion` / `pointer` take `(deviceID, sequence, windowID, [x,y,...],
properties)`; `pointer-button` takes `(deviceID, sequence, windowID, button,
pressed, [x,y,...], properties)`. `pointer-position` takes `(windowID,
[x,y,...], modifiers, buttons?, deviceID?)`; `button-action` takes `(windowID,
button, pressed, pointer, modifiers, buttons?, deviceID?)`. `pointer-wheel` /
`wheel-motion` take `(windowID, button, distance, pointer, modifiers, buttons?)`;
distance is in thousandths of a wheel step, and the server's precise wheel
support must be negotiated.

`keyboard-event` takes `(windowID, keyName, pressed, properties)`, with
`modifiers` (string array), `keyval` (integer), `string` (string), `keycode`
(integer), and `group` (integer) properties. Legacy `key-action` takes
`(windowID, keyName, pressed, modifiers, keyval, string, keycode, group)`.
`ping` takes `(monotonicMilliseconds, wallClockMilliseconds?, sourceID?)`;
`ping_echo` takes `(echoedMilliseconds, load1, load5, load15, latency, sourceID?)`.
These argument layouts are from 6.5.5 source and need the broader live exercise
before they can be treated as a verified implementation contract.


A live 6.5.5 default-mode server accepted an uncompressed rencodeplus hello
containing `version: "6.5.5"`, `protocol-version: [7, 0]`,
`encoders: ["rencodeplus"]`, `compressors: []`, `rencodeplus: true`,
`compression_level: 0`, `windows: true`, `window: {enabled: true}`, PNG/RGB
encoding capabilities, screen size and DPI, `keyboard: false`, and
`wants: ["packet-types"]`. This checks connection and name enumeration, not the
full H.264, input or clipboard hello. A server started with
`XPRA_BACKWARDS_COMPATIBLE=0` was separately observed to send `window-create`
and, after `window-map`, `window-draw`; its other modern spellings are not yet
observed in this test.

### More input and clipboard arguments

Modern `window-configure` takes `(windowID, config)` where `config` can contain
`geometry: [x,y,w,h]`, `resize-counter`, `state`, `properties` and `pointer`.
Legacy `configure-window` has a separate parser and takes `(windowID, x, y,
width, height, properties?, resizeCounter?, state?, skipGeometry?, pointerWindowID?,
pointerPosition?, modifiers?)`. `window-map` / `map-window` take `(windowID, x,
y, width, height, properties?, state?)`; `window-close` / `close-window` take
`(windowID)` and `window-focus` / `focus` take `(windowID, modifiers?)`.
`window-refresh` / `buffer-refresh` take `(windowID, unused, quality, options?,
clientProperties?)`; provide both dictionaries when supplying either. The
`refresh-now` option defaults to true.

`clipboard-token` takes `(selection, targets?, target?, dataType?, format?,
wireEncoding?, data?, claim?, greedy?, synchronous?)`. The inline target data
is a group: target, data type, format (8, 16, or 32), wire encoding and data.
For 8-bit text, wire encoding `bytes` carries bytes. A token with only a
selection claims it by default. `clipboard-request` takes `(requestID,
selection, target)`, `clipboard-contents` takes `(requestID, selection,
dataType, format, wireEncoding, data, truncated?)`, and
`clipboard-contents-none` takes `(requestID, selection)`. These layouts are
from [clipboard source](https://github.com/Xpra-org/xpra/blob/v6.5.5/xpra/clipboard/core.py);
a live stock client sent a selection-only token and answered a server
UTF8_STRING request with 8-bit `bytes` contents. Other clipboard targets and the
reverse direction need further checks.


With compatibility disabled, do not assume the legacy input aliases are
registered. The modern names are `window-create` (including override-redirect
windows, whose metadata identifies them), `window-destroy`, `window-raise`,
`window-draw`, `window-bell`, `window-metadata`, `window-icon`,
`window-move-resize`, `window-resized`, `notification-show`,
`notification-close`, `cursor-data`, `cursor-default`, `connection-close`,
and `startup-complete`. Of these, `window-create`, `window-draw`, and
`startup-complete` have been observed in the modern-mode test; the remaining
names come from source. The modern server registers modern client packet names,
clipboard names, `ping`, `ping_echo`, `suspend` and `resume`; the guest should
pin and retest its package before this table is considered stable.

### Updated guest service: modern name inventory

This table applies when the updated guest unit actually runs with
`XPRA_BACKWARDS_COMPATIBLE=0`. A dash means that operation is not a packet in
that direction. Outgoing names not identified as observed above remain
source-derived; the exact installed service and each feature still require live
checks.

| Server sends | Server accepts |
| --- | --- |
| `hello`, `challenge` | `hello` |
| `window-create` (normal and override-redirect), `window-metadata`, `window-destroy`, `window-icon`, `window-move-resize`, `window-resized`, `window-raise`, `window-bell` | — |
| `window-draw` | `window-draw-ack` |
| — | `window-map`, `window-configure`, `window-close`, `window-focus`, `window-refresh` |
| — | `pointer-motion`, `pointer-button`, `pointer-wheel`, `keyboard-event` |
| `clipboard-token`, `clipboard-request`, `clipboard-contents`, `clipboard-contents-none` | same four names |
| `ping`, `ping_echo` | `ping`, `ping_echo` |
| `notification-show`, `notification-close` | `notification-close`, `notification-action`, `notification-status` |
| `cursor-data`, `cursor-default` | `cursor-set` |
| `startup-complete`, `connection-close` | `connection-close`, `display-configure`, `suspend`, `resume` |

The enabled display subsystem and negotiated capabilities determine whether a
server sends display updates; `desktop_size` is a compatibility packet, not an
assumed modern equivalent. Query the server's `packet-types` and verify the
features actually enabled on the guest.

## Draw observations and remaining video work

The default-mode `draw` and modern-mode `window-draw` have the same shape:
`(windowID, x, y, width, height, coding, data, sequence, rowstride, options)`.
Coordinates and dimensions describe a damaged rectangle, not necessarily the
whole window. The capture includes `png`, `webp` and `rgb24`: PNG/WebP data are
complete encoded images; for RGB, use `rowstride` and the `rgb_format` option
rather than assuming three tightly packed channels from the name. The observed
`rgb24` draw used `rgb_format: "BGRX"` and a padded stride. Paint the rectangle
at `(x,y)` in the per-window backing store and acknowledge its sequence after
processing. The server can replace the data field with a preceding raw chunk.
See [draw construction](https://github.com/Xpra-org/xpra/blob/v6.5.5/xpra/server/window/compress.py)
and the [reference draw handler](https://github.com/Xpra-org/xpra/blob/v6.5.5/xpra/client/subsystem/window/draw.py).

### H.264 evidence and VideoToolbox mapping

The `video-session.json` capture uses the real 6.5.5 x264 server and its first
`h264` draw has `frame: 0`, `pts: 0`, `type: "IDR"`, `profile: "high"`,
`csc: "YUV420P"` and `full-range: true`. Its bytes use Annex-B start codes;
NAL types in order are SPS (7), PPS (8), SEI (6), and IDR slices (5). Later
server logs show increasing `frame` and `pts`. This is one tested x264 session,
not proof that every Xpra video encoder or stream restart has identical behavior.
Do not advertise B-frame decoding: set `encoding.video_b_frames: []`. In this
release the server enables B-frames only when the encoding is listed there
and the server's other B-frame conditions are satisfied.

For a VideoToolbox implementation, split Annex-B NAL units at three- or
four-byte start codes; collect SPS and PPS without their start codes. Create a
format description from the parameter sets with a four-byte NAL length field,
then build AVC samples by replacing each start code with the corresponding
four-byte big-endian NAL length. Feed complete access units in stream order and
track a separate decoder per window/video stream. Reconfigure on a new stream
or changed parameter sets, and do not decode dependent frames after a missing
frame until recovery. Apple's [Core Media parameter-set API](https://developer.apple.com/documentation/coremedia/cmvideoformatdescriptioncreatefromh264parametersets%28allocator%3Aparametersetcount%3Aparametersetpointers%3Aparametersetsizes%3Analunitheaderlength%3Aformatdescriptionout%3A%29)
documents the parameter-set and AVC length-field requirements. This mapping is
an implementation approach, not yet verified on an iPhone; stream reset,
frame ordering across changes, timestamp semantics and B-frame behavior still
need device and server tests. The complete hello, metadata, remaining packet
layouts and guest end-to-end checks are also outstanding.
