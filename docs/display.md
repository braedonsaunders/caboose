# Caboose Display

Caboose Display is the computer's display server: a headless Wayland compositor, with
Xwayland for X11 applications, that streams every window as its own encoded video for the
phone or TV to show as a native surface. The code is in [guest/display](../guest/display);
its README covers building, running and testing it. This document is the design and the
wire contract, the Caboose Display Protocol.

## Design

```
 apps (Wayland, and X11 through Xwayland)
   │ wl_shm and linear dmabuf buffers, surface damage, frame callbacks
   ▼
 caboose-display   (headless Wayland compositor, Rust + Smithay, inside the computer)
   ├ one stream per toplevel, dialog, popup and X11 window
   ├ an encoder per stream: libx264, libx265, or NVENC (h264/hevc/av1_nvenc)
   ├ changed-block detection, lossless tiles for small changes, sharpening of quiet areas
   ├ video: codec passthrough (the VA-API driver) and detected motion, as their own streams
   ├ pacing: frame callbacks released on the client's vsync, at most two frames in flight
   ├ input: pointer, wl_touch, keyboard by keysym, text-input-v3
   └ sound: a private PulseAudio, sent as Opus on the pictures' clock
   │ Caboose Display Protocol (below), relayed byte for byte by caboose-host
   ▼
 CabooseKit (iOS): VideoToolbox HEVC / AV1 / H.264 → Metal, one surface per window
```

- **The compositor composites nothing across windows.** It is a window and buffer broker.
  Each window's surface tree is rendered alone, cropped to its window geometry, and
  encoded as its own stream. The phone and the TV are the compositors, which is how each
  window stays a native surface with its own title, icon, size hints and parent.
- **Nothing runs while nothing changes.** Only damaged 16×16 blocks are compared, only
  blocks whose pixels really changed are converted, and the encoder is told which
  macroblocks changed. A window that is one surface with one wl_shm buffer is read in
  place without composition. With no client connected the server does no per-window work.
- **The client paces the applications.** Frame callbacks are released on the client's
  display refresh and only while fewer than two frames are unacknowledged, so
  applications draw at the rate the link and the screen can show.
- **Text stays sharp and cheap.** Small changes (typing, a caret) go as lossless PNG tiles
  instead of pictures. Areas that have been quiet for 300 ms are coded once more at a low
  QP and then cost nothing until they change.

The renderer is pixman, on the CPU. Applications render themselves (with Mesa's D3D12
driver on WSL2 hosts, for example), and their buffers reach the encoder through system
memory.

## Hosts and encoders

caboose-display probes its encoders at start-up by encoding a test picture and offers
only those that work, hardware first (HEVC, then AV1, then H.264), then libx264 and
libx265. The server picks the first codec in its order that the client decodes.

| Host (`CABOOSE_GPU`) | Runtime | Encoders |
| --- | --- | --- |
| No GPU (`none`) | microVM (Cloud Hypervisor) or container | libx264, libx265 |
| Linux, NVIDIA (`nvidia`) | container | NVENC, libx264, libx265 |
| Linux, Intel or AMD render node (`dri`) | container | libx264, libx265 |
| WSL2 (`wsl`) | container | NVENC through `/usr/lib/wsl/lib` on an NVIDIA GPU, libx264, libx265 |

`caboose-display --list-encoders` prints what a machine offers.

## Two instances

The computer runs two instances of caboose-display, one for the owner and one for agents.

| | Owner's display | Agent seat |
| --- | --- | --- |
| microVM unit | `caboose-display.service` | `caboose-display-agent.service` |
| Container | `caboose-session start` | `caboose-session start-agent` |
| WebSocket port | `14600` | `14601` |
| Host relay | `/v1/display` | `/v1/display?seat=agent` |
| Wayland socket | `wayland-caboose-0` | `wayland-caboose-agent` |
| Xwayland | `:110` | `:101` |
| Applications use | Wayland first, X11 through Xwayland second | the same |
| Sound | its own PulseAudio, Opus to the client | none (`--no-audio`) |
| D-Bus session bus | `/run/user/1000/bus` | `/run/user/1000/agent-bus`, with its own notification endpoint |
| Launch environment | `/run/caboose/display.env` | `/run/caboose/agent-display.env` |
| Video socket | `$XDG_RUNTIME_DIR/caboose-video.sock` | `$XDG_RUNTIME_DIR/caboose-video-agent.sock` |
| Control socket | `…/caboose-display/wayland-caboose-0/control.sock` | `…/caboose-display/wayland-caboose-agent/control.sock` |
| Started | by the host at each wake | on demand, when an agent task or a watcher (the app's Agent space) needs it |

- **Token.** At each wake the host writes a fresh token to `/run/caboose/display-token`
  (mode 0600, owned by `caboose`). Both instances and the file service (port 14700) check
  it, and caboose-display re-reads it on every `hello`. `/v1/session` wakes the computer
  and returns `{ display: { path: '/v1/display', token, protocol: 'caboose-display' } }`.
- **Relay.** The host relays bytes between the client and the instance and never decodes
  them. In the container runtime both ports are published on host loopback only.
- **Launch environment.** Once Wayland and Xwayland are ready, each instance writes the
  environment its applications need (`WAYLAND_DISPLAY`, `DISPLAY`, `XAUTHORITY`,
  `XDG_RUNTIME_DIR`, toolkit backends, `CABOOSE_DISPLAY_CONTROL`, `PULSE_SERVER` when it
  plays sound, the VA-API passthrough variables when the driver is installed) to its env
  file in sh syntax.
- **Per-instance state.** Each instance keeps its X authority (`Xauthority`), the
  Xwayland shim that adds `-auth` (`bin/Xwayland`), its PulseAudio socket
  (`pulse/native`) and its control socket (`control.sock`) under
  `$XDG_RUNTIME_DIR/caboose-display/<Wayland socket name>/`, owner-only, so the two never
  share them.
- **Readiness.** `caboose-display-ready [TIMEOUT] [PORT]` exits 0 once the instance on
  `PORT` (default 14600) answers a `hello` made with the per-wake token, trying for
  `TIMEOUT` seconds (default 60).
- **Control socket.** The computer's own tools see and act on a seat through its
  control socket rather than through X: the window list (each window's process, geometry,
  surface and focus, Wayland and X11 alike), the seat's pointer and keyboard, and pictures
  of a window or the whole seat. The screen routes (`/v1/screen/*`) use it on the owner's
  display and the agents' desktop tools on the agent seat, together with AT-SPI for the
  windows' contents. The requests are in [architecture.md § Displays](architecture.md#displays);
  the code is `compositor/src/control.rs`, and `guest/desktop-mcp/seat.py` is its client.
  A seat nobody watches paces applications at one frame a second; `settle` lets them draw
  before a picture is taken.

## Video, for every app

Video is handled at the operating system's own seams rather than for particular sites or
apps, so any program that plays video benefits. caboose-display sends video as `video.*`
streams (see "Video streams" below) in two ways, and everything else stays in the
window's own picture.

1. **Codec passthrough.** The computer ships a Caboose VA-API driver, used through the
   standard Linux interface for hardware video decoding. The driver does not decode. It
   rebuilds the compressed bitstream (H.264, HEVC, VP9, AV1) from the parameter and slice
   buffers and forwards it, as is, to caboose-display, which sends it to the client as a
   `passthrough` stream bound to the window and rectangle it plays in. The client decodes
   it in hardware and layers it into the window at the moment the application shows each
   frame, so the application's own audio sync holds. It gives the original quality at
   almost no server CPU. The driver, its socket, and the on-screen marker that binds a
   stream to its window are specified in [codec-passthrough.md](codec-passthrough.md).
2. **Detected motion.** A region of a window that updates at video rates is encoded as
   its own `motion` stream, at the size it is shown on the client, and left out of the
   window's pictures. This covers X11 players, canvas animation, and video that does not
   decode through VA.

Players that decode on the CPU through VA (mpv, GStreamer, FFmpeg) pass through wherever
the driver runs. Chromium and Firefox decode through VA only with a working GPU process,
which needs a DRM render node; on WSL2 and on hosts without a GPU their video stays in the
window picture or becomes a `motion` stream. VA carries no HDR metadata, and AV1 is
forwarded one picture late (see [guest/vaapi](../guest/vaapi/README.md)).

The protocol also defines `surface` streams, for applications that present video on its
own YUV (NV12/P010) subsurface. caboose-display's pixman renderer offers no YUV buffer
formats, so applications present RGB buffers to it and it does not send `surface`
streams.

## Caboose Display Protocol (v0)

The server is `caboose-display` in the guest, on WebSocket `0.0.0.0:14600` for the
owner's display and `0.0.0.0:14601` for the agent seat (any path; it accepts the `binary`
subprotocol). The host relays it byte for byte. Each instance serves one client at a time:
a new authenticated client replaces the previous one, which gets
`bye { reason: "replaced" }` and is closed. A client should not reconnect on its own
after `replaced`, or two devices would keep taking the display from each other. A client
that sends nothing for 30 s (no `vsync`, `ack` or `ping`) is taken for suspended or gone
and is closed. A client without a display to pace pings at least every 10 s. The Rust
codec is `guest/display/protocol`, and `guest/display/vectors/` pins every message byte
for byte.

### Framing and encoding

- The client parses a **byte stream**. WebSocket message boundaries carry no meaning (the
  server happens to write one protocol message per WebSocket message).
- Each message is `type: u8`, `length: u32` little-endian, then `payload[length]`. The
  payload is always exactly one CBOR map with text keys. Binary content (NAL units, OBUs,
  PNG, Opus) is a CBOR byte string field, so it is raw bytes on the wire.
- The largest payload is 16 MiB minus the 5-byte header (the relay's WebSocket
  `maxPayload` is 16 MiB). A larger announced length is a protocol error and closes the
  connection.
- Unknown types are skipped by length. Unknown keys are ignored. A known type whose payload
  does not decode is dropped and the stream continues. A message of the other direction's
  type range, or a text WebSocket message, is a protocol error: the server sends
  `bye { reason: "protocol" }` and closes.
- **Encoders are canonical**, so vectors compare byte for byte in both directions:
  definite lengths, integers in the shortest form, every float as float64 (`0xfb`), map
  keys sorted bytewise on their encoded form (RFC 8949 §4.2.1; for short text keys, the
  shorter key first, then lexicographic), and optional fields absent rather than null.
  **Decoders are liberal**: any key order, any integer or float width, tags read through,
  and an integer where a float is expected.

### Coordinates and ids

- Everything is in **display pixels**, the `width`/`height` of a display in the client's
  `hello`. Geometry and rects are `[x, y, w, h]` integers; sizes are `[w, h]`; input
  positions are floats.
- A toplevel's `geometry` is relative to its display's origin. A popup's or dialog's is
  relative to its parent's geometry origin and may be negative. Geometry is the xdg window
  geometry: client-side shadows are outside it and are cropped out of the stream.
- `frame.rect` is window-local display pixels (origin = the window's geometry origin).
  `frame.crop` is the visible part of the decoded picture in picture pixels (encoders pad,
  for example NVENC 2160 → 2176). When the two sizes differ the client scales, which also
  covers a scale-1 Xwayland window on a scale-3 display. Input `x`/`y` are window-local,
  with the same origin as `rect`.
- Window ids are unique for the server's lifetime and survive reconnects, so a client can
  keep a last-frame cache per id.

### Handshake

The client speaks first, as soon as the socket opens, with `hello` carrying the
`display.token` from `/v1/session`. The server re-reads the per-wake token file on every
hello. On a mismatch it sends `bye { reason: "auth" }` and closes; on an unsupported
version, `bye { reason: "version" }`; when none of its encoders is in the client's
`decoders`, `bye { reason: "protocol" }`. Otherwise it answers `hello` with the display
ids it accepted, `encoders` = its encoders ∩ the client's decoders in the server's
preference order, and its `features`; then sends `window.create` for every live window,
followed by a keyframe of each.

`features` is any of `vsync`, `ack`, `touch`, `pencil`, `text-input-v3`, `clipboard`,
`clipboard-types`, `drop`, `drag`, `cursor-named`, `tiles`, `audio`, `xwayland`, `video`.
A feature is listed only when the server implements it. caboose-display always lists
`vsync`, `ack`, `touch`, `text-input-v3`, `cursor-named`, `clipboard`, `clipboard-types`,
`drop` and `drag`; `xwayland` when Xwayland runs; `video`
when it can send video streams and the client lists `video_decoders`; `audio` when it
plays sound; and `tiles` unless tiles are turned off. It does not list `pencil`.

### Pacing and flow control

- `pts_us` is the server's `CLOCK_MONOTONIC` at the surface commit, in microseconds.
- The client sends `vsync` once per refresh of each display that shows a window. Frame
  callbacks of a window are released on a vsync of its display, and only while fewer than
  2 of its frames are unacknowledged (`ack` matches by `pts_us`). A window whose display
  sends no vsync is throttled like a minimised one: it gets frame callbacks once a second.
- **Tiles.** A small change (typing, a caret, a small widget) can arrive as `tile`s
  instead of a frame: lossless PNGs, 8-bit RGB, of the changed 16×16 blocks.
  `tile.rect` is in picture pixels, the space of `frame.crop`, and maps to the window
  the way the last frame's `crop` maps to its `rect`. A tile paints over the window's
  picture. Tiles are applied in order with frames and are not acknowledged, and a later
  frame repaints the whole picture, tiles included. The server makes that frame carry
  the current content of every tiled area. The server lists `tiles` in `features` when
  it sends them.
- A frame can change no content and only sharpen it: once part of a window has been
  unchanged for a while, the server codes it once more at a lower QP (progressive
  refinement). It is an ordinary non-key `frame` under the same flow control. Its `pts_us`
  is when it was made, which is later than the commit of the content it shows.
- `ack.decoded_us` is the decode duration, or `-1` if decoding failed, after which the
  client also sends `request_keyframe`. The next frame after `request_keyframe`, a
  reconnect, or a size change is a keyframe with parameter sets.

### Messages

Server → client (`0x01`–`0x7F`):

| Type | Name | Fields (`?` optional) |
| --- | --- | --- |
| `0x01` | `hello` | `version: uint`, `displays: [uint]`, `encoders: [codec]`, `features: [text]` |
| `0x02` | `window.create` | `id`, `parent?: uint`, `kind: "toplevel"\|"popup"\|"dialog"`, `title`, `app_id`, `icon?: bytes` (PNG), `geometry: rect`, `min?: size`, `max?: size`, `fullscreen: bool`, `display?: uint`, `xwayland?: bool`, `alpha?: bool` |
| `0x03` | `window.update` | `id` plus any `window.create` field that changed |
| `0x04` | `window.destroy` | `id` |
| `0x10` | `frame` | `id`, `codec: "hevc"\|"av1"\|"h264"`, `keyframe: bool`, `pts_us: uint`, `rect`, `crop`, `data: bytes` |
| `0x11` | `tile` | `id`, `rect`, `format: "png"\|"webp-lossless"`, `data: bytes` |
| `0x12` | `video.create` | `id`, `window`, `rect`, `clip?: rect`, `z?: int`, `codec: "h264"\|"hevc"\|"av1"\|"vp9"`, `source: "passthrough"\|"surface"\|"motion"`, `color?: { primaries, transfer, matrix, full_range }`, `extradata?: bytes` |
| `0x13` | `video.frame` | `id`, `seq`, `keyframe: bool`, `pts_us?`, `data: bytes` |
| `0x14` | `video.update` | `id`, `rect?`, `clip?`, `z?` |
| `0x15` | `video.destroy` | `id` |
| `0x16` | `video.present` | `id`, `seq`, `pts_us` |
| `0x20` | `cursor` | `id?`, `image: bytes` (PNG), `hotspot: [x, y]` |
| `0x21` | `cursor.named` | `name` (cursor-shape-v1 / CSS names: `default`, `text`, `pointer`, `vertical-text`, …) |
| `0x22` | `text_input` | `id`, `enabled: bool`, `purpose?: text` (`normal`, `terminal`, `password`, `email`, `url`, `number`, …) |
| `0x30` | `clipboard` | `mime`, `data: bytes`, `alternatives?: [{ mime, data: bytes }]` (see "Clipboard") |
| `0x31` | `notification` | `id`, `app`, `summary`, `body` |
| `0x32` | `drop.status` | `accepted: bool` (see "Drag and drop") |
| `0x33` | `drop.result` | `ok: bool`, `reason?: "rejected"\|"cancelled"\|"timeout"\|"invalid"` |
| `0x34` | `drag.start` | `mimes: [mime]` |
| `0x35` | `drag.end` | `taken: bool` |
| `0x36` | `drag.data` | as `clipboard` |
| `0x40` | `audio` | `codec: "opus"`, `pts_us`, `channels?: uint` (1 or 2, absent = 2), `data: bytes` |
| `0x7E` | `pong` | `t_us` (echoed from `ping`) |
| `0x7F` | `bye` | `reason: "auth"\|"version"\|"shutdown"\|"protocol"\|"replaced"` (another client took over the display) |

Client → server (`0x81`–`0xFF`):

| Type | Name | Fields (`?` optional) |
| --- | --- | --- |
| `0x81` | `hello` | `version: 0`, `token`, `decoders: [codec]`, `displays: [display]`, `video_decoders?: [codec]`, `audio_decoders?: ["opus"]`, `clipboard_types?: [mime]` (what the client takes from the clipboard besides text) |
| `0x82` | `vsync` | `display`, `t_us` (client monotonic) |
| `0x83` | `ack` | `id`, `pts_us`, `decoded_us: int` |
| `0x84` | `configure` | `id`, `geometry?`, `display?` (whose vsync paces it), `fullscreen?`, `maximized?`, `activated?` |
| `0x85` | `close` | `id` |
| `0x86` | `request_keyframe` | `id` |
| `0x87` | `displays` | `displays: [display]`; replaces the set on a live session (rotation, a TV plugged in, a zoom change). The server re-lays-out and answers with `window.update` |
| `0x88` | `video.ack` | `id`, `seq`: the frame is queued for display |
| `0x89` | `video.keyframe` | `id`: the decoder failed; frames are dropped until a keyframe |
| `0x90` | `touch` | `id`, `points: [{ slot, phase: "down"\|"motion"\|"up"\|"cancel", x, y, force?, radius? }]`; one message is one `wl_touch.frame` |
| `0x91` | `pencil` | `id`, `phase: "down"\|"motion"\|"up"\|"cancel"\|"hover"\|"leave"`, `x`, `y`, `pressure` (0…1), `tilt: [x_deg, y_deg]`, `azimuth_deg` |
| `0x92` | `pointer` | `id`, `x`, `y`, `buttons: uint` (the pressed set: 1 left, 2 middle, 4 right, 8 back, 16 forward), `scroll?: { dx, dy, precise: bool }` (pixels when precise, otherwise wheel clicks) |
| `0x93` | `key` | `keysym: uint`, `pressed: bool`, `mods: ["shift"\|"control"\|"mod1"\|"mod4"]` |
| `0x94` | `text` | `commit?`, `preedit?`, `cursor?: [begin, end]` (byte offsets into `preedit`), `delete_before?`, `delete_after?` (extended grapheme clusters) |
| `0xA0` | `clipboard` | `mime`, `data: bytes`, `alternatives?: [{ mime, data: bytes }]` |
| `0xA1` | `drop.enter` | `id`, `x`, `y`, `mimes: [mime]` |
| `0xA2` | `drop.motion` | `id`, `x`, `y` |
| `0xA3` | `drop.leave` | (empty map) |
| `0xA4` | `drop.perform` | as `clipboard` |
| `0xA5` | `drag.take` | (empty map) |
| `0xFE` | `ping` | `t_us`, answered by `pong` for round-trip time |

A `display` is `{ id: uint, width: int, height: int, scale: float, refresh_hz: float, hdr: bool }`.

- `frame.data` is Annex-B for H.264 and HEVC, with parameter sets on keyframes; for AV1 it is
  one temporal unit of low-overhead OBUs with the sequence header on keyframes.
- `text` is text-input-v3. Deletions (`delete_before`, `delete_after`, in grapheme
  clusters) are sent to every surface as BackSpace and Delete presses, one per cluster,
  before the commit; that removes one grapheme cluster in every toolkit, where
  `delete_surrounding_text` depends on the application's surrounding-text bookkeeping
  (Chromium drops it). The commit and pre-edit text go through text-input-v3 when the
  focused surface has it enabled; otherwise (an X11 app through Xwayland, for example)
  the commit is typed as key presses and pre-edit text is not shown. Clients send Return as
  a `key` press/release (`0xFF0D`), not a committed newline: single-line fields can ignore
  newlines committed by an input method.
- `text_input` fires when the focused window's text-input-v3 is enabled or disabled. With
  the `text-input-v3` feature the client shows and hides the keyboard from it, and treats a
  `text` cursor shape only as a fallback.
- Clients keep pointer gestures (tap, long-press right-click, swipe to scroll) for
  `xwayland: true` windows and send real touch to native Wayland ones, because most X11
  apps turn a touch drag into a selection.

caboose-display sends a subset of these messages. It sends named cursors (`cursor.named`)
and no `cursor` images; tiles only as `png`; `video.create` and `video.update` without
`z`, `color` or `extradata`; and no `notification` (the computer's notifications reach
the app through the host, from [guest/notifications](../guest/notifications)). It ignores
`pencil`.

### Clipboard

One `clipboard` message is one copy: its first representation in `mime` and `data`, and
the same content in other types in `alternatives`, absent when there are none. Either
side sends one whenever its own clipboard changes; the server also sends the computer's
current copy right after `hello`. The types are:

| Type | Content |
| --- | --- |
| `text/plain;charset=utf-8` | UTF-8 text, at most 1 MiB |
| `image/png` | A PNG, beginning with the PNG signature |
| `image/jpeg` | A JPEG, beginning with `FF D8 FF` |
| `text/uri-list` | Files: `file://` URIs of absolute paths (empty or `localhost` host, percent-encoded), one per line, `#` lines ignored; at most 64 files and 256 KiB |

- A copy carries each type at most once, at most 12 MiB (`MAX_BYTES`) for every
  representation together, and is listed text first, then images, then files. A receiver
  refuses a whole copy with an unknown or repeated type, bytes that are not what their
  type says, or more than the limit; the framing's 16 MiB limit is enforced before any of
  it is read.
- **To the client**, the server sends text, and the other types only when the client's
  `hello` lists them in `clipboard_types`; a copy that leaves nothing for the client is
  not sent. caboose-display reads an application's copy in its best text type
  (`text/plain;charset=utf-8`, `UTF8_STRING`, `text/plain`, `TEXT`, `STRING`), its best
  image type (`image/png`, then `image/jpeg`) and its files (`text/uri-list`, or
  GNOME's `x-special/gnome-copied-files`, converted), each within its share of the limit
  and five seconds. Paths are the computer's; a client fetches files under the home
  through the host's `/v1/fs` routes and cannot reach others.
- **From the client**, `text/uri-list` may only name files the client has uploaded to the
  computer's transfer area (`~/.cache/caboose/transfers/<id>/<name>`, through the host's
  `/v1/fs/transfer`, [architecture.md § Files](architecture.md#files)). caboose-display
  opens each one without following links before it offers the copy, and refuses the copy
  otherwise. It offers applications the text in every text type above, the images in
  their own types, and files as `text/uri-list` and `x-special/gnome-copied-files`
  (`copy`), and gives an application that pastes thirty seconds to read.

### Drag and drop

The clipboard's types, limits and checks apply to everything dragged either way; a
drop's or a drag's content has the shape of a `clipboard` message.

**A drop from the client** (`drop`). While the client drags something over a window,
it sends `drop.enter` with the window, the window-local position and the types it can
deliver, then `drop.motion` as it moves, over the same window or another. The server
drags the same types over the application at that point: a Wayland window gets a
compositor-owned Wayland drag, an X11 window an XDND (version 3 to 5) drag from the
server's own X client, with the copy action only. `drop.status` reports whether the
application under the point accepts it, whenever that changes and after every change of
window (as not accepted until the application says otherwise). When the user lets go,
the client prepares the content (it uploads files to the transfer area first) and sends
`drop.perform` with it: the types are a subset of those it entered with, and its files
must be in the transfer area. Only then is the drag released, on the application under
the last position, which then reads the content. `drop.result` ends the drop: `ok`, or
`rejected` (nothing there accepted it), `cancelled` (no drop was in progress), `timeout`
(the application did not finish within 30 s, or the drop hovered 15 minutes without a
`drop.motion`) or `invalid` (the content failed the checks). `drop.leave` ends a drop
without a result.

Applications read a drag's data as it enters, and many decide from it whether to
accept, but the client can deliver the content only once the user has let go. So
`drop.status` while hovering reflects what the application says without the content, and
on `drop.perform` the server enters the application again with the content ready: a
Wayland drag leaves and re-enters the surface, an XDND drag re-enters if the window asked
for data early. The server releases the drag once the application accepts, has been sent
all it asked for, and has had 0.6 s to read it, moving the drag over it meanwhile; an
application that does not accept within 3 s (XDND: 2 s of renewed positions) rejects the
drop. Chromium on Wayland sometimes hands a dropped text to its page empty (one drop in
five in the `drop-wayland` check); files and X11 targets do not show this. While a drop is in progress the server ignores the client's `pointer`
messages, which would move the drag.

**A drag to the client** (`drag`). When a Wayland application starts dragging something
in a type the client takes (text, or one its hello lists in `clipboard_types`), the
server sends `drag.start` with those types. If the user releases it on the client's
own drop target, the client sends `drag.take` before the release. The server moves the
drag off every window, reads the content from the application as it reads a copy, and
holds the client's `touch`, `pointer` and `key` messages until it is read (five seconds
at most). It sends `drag.data` and then applies the held input, so the release ends the
drag over no window: the application sees a drag that was not dropped, and removes
nothing. `drag.end` says the application's drag ended and whether the client took it.
Drags started by X11 applications stay within X11 (Xwayland and its window manager do
not hand them to Wayland), so the client is not told of them.

### Audio

The computer's sound is one Opus stream: each `audio` message is one 20 ms packet (960
samples per channel) at 48 kHz, stereo, with `pts_us` the server `CLOCK_MONOTONIC` of its
first sample, the clock of `frame` and `video.present`, so a client plays sound and pictures
on one timeline. It goes only to a client whose hello lists `"opus"` in `audio_decoders`.
Digital silence is not sent after a second of it: a gap in `pts_us` is silence, and packets
resume without a reset. The server lists `audio` in `features` when it has sound to send.

### Video streams

A video stream is layered into a window (`window`) by the client: it decodes it with its
own decoder and draws it at `rect` (window-local display pixels, the whole picture,
scaled to fit), showing only `clip` when present (a scrolled or cropped player, or an
H.264 1088-line picture whose 1080 lines are visible). Every video stream is drawn above
the window's own picture, ordered by `z` (higher on top); window pictures carry no alpha,
so the server sends the visible region as `clip` instead of relying on a hole in the
window. Video ids are their own namespace, unique for the server's lifetime.
The client intersects `clip` (or `rect` when absent) with the window's bounds and `rect`;
clipping preserves the scale and origin of the complete decoded picture. The window's
picture and video layers share one window-pixel-to-view transform, including while the
previous picture stretches during a resize. A playback layer has one active presentation
owner; thumbnails and inactive presentations do not take it from the visible window.

- The client lists in `hello.video_decoders` what it can play as a video stream. The server
  creates streams only in those codecs and sends `video` in `features`; anything else
  stays in the window's picture.
- `video.frame` carries one access unit in **decode order**: `seq` starts at 0 for each
  stream and increases by one. `data` is Annex-B with parameter sets on keyframes for
  H.264 and HEVC, a temporal unit of OBUs with the sequence header on keyframes for AV1,
  and a frame or superframe for VP9. `extradata` is only for a codec whose parameters
  cannot travel in band.
- **`motion` streams** are regions of a window that the server finds updating at video
  rates. A region qualifies once it has been a dense rectangle of at least 192×112
  picture pixels for a second, with most of its macroblocks changing in most pictures at
  15 or more pictures a second. It is sent in the window stream's codec at the window
  picture's pixel scale, and only to a client that lists that codec in `video_decoders`;
  a window with a passthrough stream bound gets none. While the stream exists, the
  window's `frame`s leave the region out; the client shows the stream over it. Once the
  region has stopped looking like that for a second (the video paused, moved, or closed),
  the server sends a window `frame` that repaints the region and then `video.destroy`.
  The client keeps showing the stream until it has shown that frame. A resize ends the
  stream with the keyframe that follows it.
- **`surface` and `motion` streams** carry `pts_us` (server `CLOCK_MONOTONIC` at the
  commit, like `frame`), have no reordering, and are shown as soon as they are decoded.
- **`passthrough` streams** carry no `pts_us`: the application's decoder is the server's
  VA-API driver, which sees no timestamps. The client decodes in order and keeps decoded
  pictures by `seq`; `video.present { id, seq, pts_us }` says the application is showing
  frame `seq` now, and the client shows it then. The application has already synchronised
  that moment with its own audio clock.
- `color` describes the stream in ITU-T H.273 code points (for example `9/16/9`, BT.2020
  with PQ); with it a client whose display reports `hdr` shows HDR video with EDR. Window
  pictures stay SDR.
- `video.ack` says a frame is queued for display; for `surface` and `motion` streams it is
  the flow control of the window stream (at most 2 unacknowledged), for `passthrough` it is
  only latency accounting, because the application paces itself. After a
  `video.keyframe` the server sends a keyframe (a passthrough stream is replayed from its
  last one). A client that sends three `video.keyframe` for a passthrough stream within
  10 s gets that stream decoded on the server instead.

## Measurements

All figures below are from an AMD Ryzen 7 2700X (8 cores), with software rendering,
libx264 on one thread per window, and frames decoded and acknowledged by
`caboose-display-probe` on the same machine. They are produced by the scripts named with
each table, run in the dev container (`guest/display/scripts/dev.sh`).

`scripts/check.py` with the probe's `--server-pid`:

| Workload | Frame rate | Latency, commit → decoded (p50 / p95) | Server CPU |
| --- | --- | --- | --- |
| Chromium, 1280×720 animation (60 Hz) | 60.2 fps | 3.3 / 5.0 ms | 3.8 ms per frame |
| Chromium, 1920×1080 animation (60 Hz) | 59.8 fps | 6.8 / 7.9 ms | 7.4 ms per frame, 43% of a core |
| weston-simple-shm, 250×250 (60 Hz) | 60.2 fps | 0.7 / 1.2 ms | 0.94 ms per frame, 6% of a core |
| The same with HEVC (x265) | 60.4 fps | 4.9 / 11.7 ms | 10.8 ms per frame |
| An idle terminal, client ticking vsync at 60 Hz | — | — | 0.5% of a core |
| No client connected | — | — | nothing measurable (one housekeeping timer a second) |

- Chromium damages about a quarter of the window per frame while the pixels that change
  cover about 1%, which is why changed blocks are compared before they are converted.
- Reading a single-buffer window in place costs 12.0 ms of server CPU per frame for
  full-window 1080p video; composing it (`--always-compose`) costs 13.1 ms.
- `refine`: the sharpened picture of a quiet terminal is 42.4 → 50.3 dB against a
  near-lossless reference, for one 34 kB picture. A blinking caret for 6 s costs 16
  pictures, against 13 without sharpening.
- `tiles`: 31 characters typed into Chromium at 1179×2556 take 6 pictures and 470 ms of
  server CPU, against 77 pictures and 1180 ms with `--tile-max-px 0`; the final pictures
  match at 66.6 dB.
- `motion`: the check's 8 s canvas video in a 1280×720 Chromium window costs 5.1% of a
  core, against 8.0% with `--no-motion`. The window stream sends about 50 pictures, most
  of them before the region qualifies; each video frame is then a 480×288 encode instead
  of a 1280×720 one.

`scripts/profile.py [phone|tv] [type|scroll|caret]`, Chromium maximised on a phone's
display (1179×2556 at 3×) or a TV's (3840×2160 at 2×), server CPU from process CPU over
9 s of typing (about 25 keystrokes) minus the idle-caret baseline:

| | With tiles | `--tile-max-px 0` |
| --- | --- | --- |
| phone, per keystroke | ≈0.8 ms | ≈17 ms |
| TV, per keystroke | under 1 ms (below the 10 ms clock tick over the run) | ≈44 ms |
| phone, idle caret | 1.1% of a core | 2.9% |
| TV, idle caret | 1.0% | 7.1% |

The encoder alone on one thread, with synthetic text
(`cargo test -p caboose-display bench_text -- --ignored --nocapture`), libx264 in CRF mode
at 23 with `qcomp=1`:

| Picture | Time, size |
| --- | --- |
| 1080p, one glyph typed | 4.4 ms, 198 B |
| 1080p, scrolled 18 px | 10.9 ms, 22 kB |
| 720p, one glyph typed | 1.6 ms, 131 B |
| 720p, scrolled 18 px | 5.2 ms, 12 kB |

A whole picture has a cost floor that scales with its size, whatever changed: one typed
glyph coded as a picture is 6.4 ms at 1179×2556 and 18.5 ms at 3840×2160, which is what
tiles avoid. Sharpening 30 typed glyphs at 1080p is one 1.7 kB picture; the first
sharpening of a whole window after its keyframe is the largest (a full screen of dense
text: 470 kB, 15 ms).
