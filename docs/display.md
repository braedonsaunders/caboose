# Caboose Display

Caboose Display is the computer's display server: a headless Wayland compositor, with
Xwayland for X11 applications, that streams every window as its own surface or encoded video for the
phone or TV to show as a native surface. The code is in [guest/display](../guest/display);
its README covers building, running and testing it. This document is the design and the
wire contract, the Caboose Display Protocol.

## Design

```
 apps (Wayland, and X11 through Xwayland)
   │ wl_shm and linear dmabuf buffers, surface damage, frame callbacks
   │ + guest/scene (LD_PRELOAD Cairo/GTK/Qt scene hook, Chromium layer flags, Vulkan WSI / Zink promotion)
   ▼
 caboose-display   (headless Wayland compositor, Rust + Smithay, inside the computer)
   ├ one stream per toplevel, dialog, popup and X11 window
   ├ Surface Atlas (Layer 0, when client advertises atlas: true):
   │   64×64 XXH64 content-addressed tile cache, CopyRect scroll detection, solid RGBA fills,
   │   and adaptive lossless micro-codec (pal2-lz4, pal16-lz4, rgba-lz4) via surface.batch (0x23)
   ├ Scene Graph (Layer 1, when client advertises scene: true):
   │   outline font faces (scene.font, 0x25), retained vector/glyph trees (scene.commit, 0x26),
   │   and 120 Hz client-predicted scroll sync (scene.scroll, 0x9A)
   ├ legacy/fallback video encoder per stream: libx264, libx265, or NVENC (h264/hevc/av1_nvenc)
   ├ changed-block detection, lossless tiles for small changes, sharpening of quiet areas
   ├ video: codec passthrough (the VA-API driver) and detected motion, as their own streams
   ├ games & 3D: WebAssembly games handed off to the client, and Vulkan / Zink GPU streams
   ├ pacing: frame callbacks released on the client's vsync, at most two frames in flight
   ├ input: pointer, wl_touch, keyboard by keysym, text-input-v3
   └ sound: a private PulseAudio, sent as Opus on the pictures' clock
   │ Caboose Display Protocol (below), relayed byte for byte by caboose-host
   ▼
 CabooseKit (iOS): Metal Surface Atlas + CoreText/Metal Scene Graph + VideoToolbox HEVC / AV1 / H.264, one surface per window
```

- **The compositor composites nothing across windows.** It is a window and buffer broker.
  Each window's surface tree is rendered alone, cropped to its window geometry, and
  streamed as its own surface. The phone and the TV are the compositors, which is how each
  window stays a native surface with its own title, icon, size hints and parent.
- **Zero Server Video when `atlas: true` is negotiated.** When a client advertises `atlas: true`
  in `ClientHello` (even with `decoders: []`), the server skips per-window H.264/HEVC video
  encoding (`0x10` `frame`) and instead transmits atomic byte-perfect `surface.batch` (`0x23`)
  damage updates (Layer 0) and retained vector/glyph `scene.commit` (`0x26`) trees (Layer 1).
  Hardware video (`video.*` passthrough and motion streams) remains reserved for actual video
  media and high-churn motion regions.
- **Nothing runs while nothing changes.** Only damaged blocks are compared, and with no client
  connected the server does no per-window encoding work. In legacy video mode, only damaged
  16×16 blocks whose pixels really changed are converted and passed to the video encoder.
- **The client paces the applications.** Frame callbacks are released on the client's
  display refresh and only while fewer than two frames or surface batches are unacknowledged, so
  applications draw at the rate the link and the screen can show.
- **Text stays sharp and cheap.** In Surface Atlas mode, 64×64 UI tiles are content-addressed by
  64-bit `XXH64`, deduplicated across frames and scroll positions, and compressed with the
  lossless UI micro-codec (`pal2-lz4`, `pal16-lz4`, `rgba-lz4`). In Scene Graph mode, outline
  fonts (`scene.font`, `0x25`) and positioned glyph runs (`scene.commit`, `0x26`) rasterize
  natively on the client at retina scale. In legacy video mode, small changes go as lossless
  PNG tiles (`0x11` `tile`) and quiet areas are sharpened after 300 ms.
- **Popups keep their shape.** A popup (an xdg popup, an X11 override-redirect menu or
  tooltip) has its rounded corners and shadow inside its window geometry, so it is sent
  with `alpha: true`, composed on a transparent canvas and coded losslessly with alpha,
  never as lossy video frames; the client shows it on a transparent surface.

The renderer is pixman, on the CPU. Applications render themselves (with Mesa's D3D12
driver on WSL2 hosts, for example), and their buffers reach the compositor through system
memory.

GTK 3 ordinary windows use the KDE server-decoration default; xdg-decoration
clients are configured for server-side decorations. Both leave their window controls
to Caboose. The launch environment sets `GTK_CSD=0` for the X11 GTK fallback.
Application-supplied headerbars and menus remain content: their controls cannot be
safely removed by cropping the picture.

## Hosts and encoders

caboose-display probes its encoders at start-up by encoding a test picture and offers
only those that work, hardware first (HEVC, then AV1, then H.264), then libx264 and
libx265. The server picks the first codec in its order that the client decodes. When a
client advertises `atlas: true`, it may send `decoders: []` (zero window-video decoders)
and still complete the handshake with `encoders: []`.

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
| Scene socket | `$XDG_RUNTIME_DIR/caboose-scene.sock` | `$XDG_RUNTIME_DIR/caboose-scene-agent.sock` |
| Game socket | `$XDG_RUNTIME_DIR/caboose-game.sock` | none (`--no-games`) |
| WSI auto-promotion | `CABOOSE_WSI_AUTO_PROMOTE=1` (`CABOOSE_SEAT=owner`) | disabled (`CABOOSE_SEAT=agent`) |
| Phone devices ([devices.md](devices.md)) | the phone's hardware, while it is connected | none (`--no-devices`) |
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
  `XDG_RUNTIME_DIR`, toolkit backends, `CABOOSE_DISPLAY_CONTROL`, `CABOOSE_SCENE_SOCKET`,
  `PULSE_SERVER` when it plays sound, `CABOOSE_GAME_SOCKET` when it hands games off, the
  VA-API passthrough variables when the driver is installed) to its env file in sh syntax.
- **Per-instance state.** Each instance keeps its X authority (`Xauthority`), the
  Xwayland shim that adds `-auth` (`bin/Xwayland`), its PulseAudio socket
  (`pulse/native`) and its control socket (`control.sock`) under
  `$XDG_RUNTIME_DIR/caboose-display/<Wayland socket name>/`, owner-only, so the two never
  share them.
- **Readiness.** `caboose-display-ready [TIMEOUT] [PORT] [ENV_FILE]` checks the written
  launch environment, its peer-authenticated control socket and the selected listening
  TCP port, for up to `TIMEOUT` seconds (default 60). It sends no display hello and does
  not validate WebSocket token acceptance or evict an existing watcher.
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
  PNG, LZ4 tiles, font faces, glyph runs, Opus) is a CBOR byte string field, so it is raw
  bytes on the wire.
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
- A configure size is a request. The client keeps the server-reported size for the
  picture's layout and input coordinates until the app reports a new size; fixed-size
  windows may decline a request without sending another geometry update. Placement can
  move immediately, but an in-flight placement never suppresses a reported size change.
- Monitor dimensions are independent of a window's presentation viewport. The iOS client
  saves its initial full-device output and the DPI chosen on device attachment, including
  an active desktop's UI scale. A validated per-computer local preference restores the
  device mode/DPI/render scale before start or resume. Without one, Home announces an
  empty display set, retaining the server's current/default output until a real measured
  device attachment. A view with no assigned output paces the retained hello's primary
  ID during that bootstrap; explicit pacing IDs are never redirected. Pictures and
  acknowledgements do not depend on the client selecting a replacement output.
  Card, keyboard and stage changes resize ordinary window requests without changing that
  output. Physical scene-window measurements update monitor dimensions at the retained
  DPI/render scale: full bounds in Tablet mode and the upper panel in Laptop mode. Rotation
  and leaving Laptop use the current scene bounds, independently of keyboard avoidance.
  External monitors use their own mode and
  DPI without overwriting the device preference; explicit owner zoom can change DPI.
  An unchanged monitor sends no `displays` message. Desktop content uses the model's
  shown rectangle directly for rendering and input, without a second inner fit.
- Ordinary card and dialog requests respect positive per-axis minimum/maximum hints;
  inconsistent maxima cannot override minima. Fullscreen geometry belongs to the
  compositor's monitor and is not fitted by a card request. Its complete reported picture
  uses the same aspect-fit transform for presentation and input. Explicit fullscreen exit
  resumes ordinary window fitting. No application-specific or fixed minimum output mode
  is inferred from a small phone viewport.
- An output mode/origin change reconfigures existing fullscreen and maximized windows
  through the common Wayland/X11 configure path, preserving their state flags. Removed
  outputs first remap to the primary output. Unchanged outputs and ordinary windows do
  not receive a geometry configure from this reconciliation. Fullscreen pictures fit
  centered in the client viewport without transient stretching; pointer/touch input,
  text drops and popup roots use the same fitted rectangle. Ordinary constrained tiles
  retain their top-aligned fit, including pending keyboard and tile resizes. Configure
  metadata can precede decoded pixels: presentation retains the picture dimensions
  until Metal adopts its successor, without animating picture bounds between aspects.
  The slot may animate, but its picture scale remains uniform. Popup roots, drops and
  input use the same fitted rectangle.
- The session applies size hints at the common configure boundary for every layout.
  Layout-owned tile, card and snap requests preserve the viewport aspect when
  satisfying minimum or maximum sizes permits it: a larger minimum width grows
  the requested height proportionally. Conflicting aspect constraints and genuinely
  fixed-size windows retain per-axis sizing and fit their committed picture. Free
  window resizing continues to clamp each axis independently. Switchyard reasserts
  its target after an app changes size, with the same bounded correction policy as
  cards; the last sent request alone does not count as an accepted size.
  Text drops in cards and tiles invert the same fitted rectangle, including its
  padding, rather than assuming the viewport is the surface's natural size.
  Desktop pointer positions and scroll deltas use the shown surface rectangle and
  committed remote size. An active desktop trackpad scroll cancels when that mapping
  changes; a captured pointer drag still releases its original target at the surface edge.
- `frame.rect` is window-local display pixels (origin = the window's geometry origin).
  `frame.crop` is the visible part of the decoded picture in picture pixels (encoders pad,
  for example NVENC 2160 → 2176). When the two sizes differ the client scales, which also
  covers a scale-1 Xwayland window on a scale-3 display. Input `x`/`y` are window-local,
  with the same origin as `rect`.
- Window ids are unique for the server's lifetime and survive reconnects. A new server
  process starts its ids again, so a client keeps a window's last picture across a
  reconnect only when the hello's `epoch` (random for each server process) is the one it
  had; a hello without an epoch proves nothing.

### Handshake

The client speaks first, as soon as the socket opens, with `hello` carrying the
`display.token` from `/v1/session`. The server re-reads the per-wake token file on every
hello. On a mismatch it sends `bye { reason: "auth" }` and closes; on an unsupported
version, `bye { reason: "version" }`; when none of its encoders is in the client's
`decoders` **and** the client did not advertise `atlas: true`, `bye { reason: "protocol" }`.
When the client advertises `atlas: true`, `decoders: []` is valid and negotiates a zero-video
window session (`encoders: []` in `ServerHello`). Otherwise it answers `hello` with the display
ids it accepted, `encoders` = its encoders ∩ the client's decoders in the server's
preference order, its `features` and its `epoch`; then sends `window.create` for every
live window, followed by a keyframe (`surface.batch` with `keyframe: true` when `atlas` is
active, or `frame` in legacy video mode) of each.

The client also parses the optional `gpu_live_epoch` as a 16-byte CBOR byte string
with at least one nonzero byte, separately from the text `epoch`.
Absent or malformed values leave live GPU display identity unavailable without rejecting
the ordinary display. Parsing this identity does not enable a GPU executor or bind a layer.

The server writes every `window.create` of a hello before it reads the client's next
message, and answers `ping` on the same ordered connection. A `pong` to a ping sent after
the hello therefore follows the last `window.create` of that hello: at that point the
client's windows are exactly the server's. A server that sends `epoch` guarantees this
order; a client relies on it only from such a server.

`features` is any of `vsync`, `ack`, `touch`, `pencil`, `text-input-v3`, `clipboard`,
`clipboard-types`, `drop`, `drag`, `cursor-named`, `tiles`, `audio`, `xwayland`, `video`, `wasm`, `gpu`, `webview`,
`devices`, `atlas`, `scene`. A feature is listed only when the server implements it.
caboose-display always lists `vsync`, `ack`, `touch`, `pencil`, `text-input-v3`,
`cursor-named`, `clipboard`, `clipboard-types`, `drop` and `drag`; `xwayland` when Xwayland runs; `video` when it can send video streams and the
client lists `video_decoders`; `audio` when it plays sound; `tiles` unless tiles are turned
off or superseded by `atlas`; `wasm` when it hands games off (the owner's display) and the
client's hello says `wasm: true`; `gpu` when it relays GPU streams (the owner's display) and
the client's hello says `gpu: true`; `webview` when the owner display and client support
agent-app handoff; `devices` when the owner's display accepts the phone's hardware
([devices.md](devices.md)) and the client's hello says `devices: true`; `atlas` when the
client's hello says `atlas: true`; and `scene` when the client's hello says `scene: true`.

### Pacing and flow control

- `pts_us` is the server's `CLOCK_MONOTONIC` at the surface commit, in microseconds.
- The client sends `vsync` once per refresh of each display that shows a window. Frame
  callbacks are released on that display's vsync while fewer than 2 video frames or 12
  negotiated atlas batches are unacknowledged (`ack` matches by `pts_us`). Atlas also releases
  a pending callback when an acknowledgment creates room, provided that display's vsync
  is still current. Video callbacks retain vsync pacing. Each window has at most one encode
  in progress, counted against callback admission. A display without current vsync gets
  callbacks once a second. The connection's existing 48 MiB WebSocket write-buffer cap
  still applies; exceeding it closes the connection rather than accumulating more data.
  These limits bound work in flight; they do not guarantee a frame rate.
- **Tiles (legacy mode).** When `atlas` is not negotiated, a small change (typing, a caret, a
  small widget) can arrive as `tile`s instead of a frame: lossless PNGs, 8-bit RGB, of the
  changed 16×16 blocks. `tile.rect` is in picture pixels, the space of `frame.crop`, and maps
  to the window the way the last frame's `crop` maps to its `rect`. A tile paints over the
  window's picture. Tiles are applied in order with frames and are not acknowledged, and a
  later frame repaints the whole picture, tiles included. The server makes that frame carry
  the current content of every tiled area. The server lists `tiles` in `features` when
  it sends them.
- A frame can change no content and only sharpen it: once part of a window has been
  unchanged for a while, the server codes it once more at a lower QP (progressive
  refinement). It is an ordinary non-key `frame` under the same flow control. Its `pts_us`
  is when it was made, which is later than the commit of the content it shows.
- `ack.decoded_us` is the decode or batch-apply duration, or `-1` if decoding failed, after
  which the client also sends `request_keyframe`. The next update after `request_keyframe`, a
  reconnect, or a size change is a keyframe (`surface.batch` with `keyframe: true` or a video
  `frame` with parameter sets).

### Messages

Server → client (`0x01`–`0x7F`):

| Type | Name | Fields (`?` optional) |
| --- | --- | --- |
| `0x01` | `hello` | `version: uint`, `displays: [uint]`, `encoders: [codec]`, `features: [text]`, `epoch?: text` (1–64 bytes; caboose-display sends 16 hex characters) |
| `0x02` | `window.create` | `id`, `parent?: uint`, `kind: "toplevel"\|"popup"\|"dialog"`, `title`, `app_id`, `icon?: bytes` (PNG), `geometry: rect`, `min?: size`, `max?: size`, `fullscreen: bool`, `display?: uint`, `xwayland?: bool`, `alpha?: bool` |
| `0x03` | `window.update` | `id` plus any `window.create` field that changed |
| `0x04` | `window.destroy` | `id` |
| `0x10` | `frame` | `id`, `codec: "hevc"\|"av1"\|"h264"`, `keyframe: bool`, `pts_us: uint`, `rect`, `crop`, `data: bytes` |
| `0x11` | `tile` | `id`, `rect`, `format: "png"\|"webp-lossless"`, `data: bytes` |
| `0x12` | `video.create` | `id`, `window`, `rect`, `clip?: rect`, `z?: int`, `codec: "h264"\|"hevc"\|"av1"\|"vp9"`, `source: "passthrough"\|"surface"\|"motion"`, `color?: { primaries, transfer, matrix, full_range }`, `extradata?: bytes`, `scaled?: bool` |
| `0x13` | `video.frame` | `id`, `seq`, `keyframe: bool`, `pts_us?`, `data: bytes` |
| `0x14` | `video.update` | `id`, `rect?`, `clip?`, `z?` |
| `0x15` | `video.destroy` | `id` |
| `0x16` | `video.present` | `id`, `seq`, `pts_us` |
| `0x17` | `game.create` | `id`, `window`, `root: text`, `entry: text`, `saves?: [{ mount: text, path: text }]` |
| `0x18` | `game.destroy` | `id` |
| `0x19` | `gpu.create` | `id`, `window` |
| `0x1A` | `gpu.data` | `id`, `offset: uint`, `data: bytes` |
| `0x1B` | `gpu.destroy` | `id`, `reason?: "spool-limit"` |
| `0x1C` | `webview.create` | `id`, `window`, `app: text`, `root: text`, `entry: text`, `bridge: text`, `grant: text` |
| `0x1D` | `webview.destroy` | `id` |
| `0x20` | `cursor` | `id?`, `image: bytes` (PNG), `hotspot: [x, y]` |
| `0x21` | `cursor.named` | `name` (cursor-shape-v1 / CSS names: `default`, `text`, `pointer`, `vertical-text`, …) |
| `0x22` | `text_input` | `id`, `enabled: bool`, `purpose?: text` (text-input-v3 content purpose: `normal`, `alpha`, `digits`, `number`, `phone`, `url`, `email`, `name`, `password`, `pin`, `date`, `time`, `datetime`, `terminal`), `surrounding?: text`, `cursor?: uint`, `anchor?: uint` |
| `0x23` | `surface.batch` | `id`, `seq`, `pts_us`, `size: [w, h]`, `rect`, `keyframe?: bool`, `copies?: [[dx, dy, x, y, w, h]]`, `fills?: [[x, y, w, h, rgba]]`, `refs?: [[x, y, hash]]`, `tiles?: [{ x, y, w, h, fmt: "pal2-lz4"\|"pal16-lz4"\|"rgba-lz4"\|"png", hash?: uint, data: bytes }]` |
| `0x24` | `surface.reset` | `epoch: uint` |
| `0x25` | `scene.font` | `font: uint` (`XXH64`), `index: uint`, `family?: text`, `data: bytes` (TTF/OTF) |
| `0x26` | `scene.commit` | `id`, `seq`, `pts_us`, `root: uint`, `reset?: bool`, `nodes?: [{ id, kind: "group"\|"clip"\|"rclip"\|"scroll"\|"rect"\|"border"\|"shadow"\|"glyphs"\|"path"\|"surface", rect?, radius?: [u32 × 4], color?: uint, scroll?: rect, children?: [uint], font?: uint, size?: float, glyphs?: bytes, path?: bytes, surface?: uint }]`, `remove?: [uint]` |
| `0x30` | `clipboard` | `mime`, `data: bytes`, `alternatives?: [{ mime, data: bytes }]` (see "Clipboard") |
| `0x31` | `notification` | `id`, `app`, `summary`, `body` |
| `0x32` | `drop.status` | `accepted?: bool`, absent while the application answers only on the drop (see "Drag and drop") |
| `0x33` | `drop.result` | `ok: bool`, `reason?: "rejected"\|"cancelled"\|"timeout"\|"invalid"` |
| `0x34` | `drag.start` | `mimes: [mime]` |
| `0x35` | `drag.end` | `taken: bool` |
| `0x36` | `drag.data` | as `clipboard` |
| `0x40` | `audio` | `codec: "opus"`, `pts_us`, `channels?: uint` (1 or 2, absent = 2), `data: bytes` |
| `0x60` | `device.status` | `devices: [{ id, nodes: [text], error?: text }]` ([devices.md](devices.md#protocol)) |
| `0x61` | `device.open` | `device`, `rate_hz?: float` |
| `0x62` | `device.close` | `device` |
| `0x63` | `device.rumble` | `device`, `strong: float`, `weak: float`, `ms: uint` |
| `0x64` | `device.keyframe` | `device` |
| `0x7E` | `pong` | `t_us` (echoed from `ping`) |
| `0x7F` | `bye` | `reason: "auth"\|"version"\|"shutdown"\|"protocol"\|"replaced"` (another client took over the display) |

Client → server (`0x81`–`0xFF`):

| Type | Name | Fields (`?` optional) |
| --- | --- | --- |
| `0x81` | `hello` | `version: 0`, `token`, `decoders: [codec]`, `displays: [display]`, `video_decoders?: [codec]`, `audio_decoders?: ["opus"]`, `wasm?: bool`, `gpu?: bool`, `scaled_motion?: bool`, `webview?: bool`, `devices?: bool`, `atlas?: bool`, `scene?: bool` (booleans present only when true), `clipboard_types?: [mime]` (what the client takes from the clipboard besides text) |
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
| `0x96` | `gpu.ack` | `id`, `offset`: the client has consumed the stream up to `offset` |
| `0x97` | `game.decline` | `id`, `reason: text` (at most 200 UTF-8 bytes; the server logs no more): the client cannot run game `id` ([game-handoff.md, "Declining"](game-handoff.md#declining)) |
| `0x98` | `webview.decline` | `id`, `reason: text` (at most 200 UTF-8 bytes) |
| `0x9A` | `scene.scroll` | `id`, `node: uint`, `sx: float`, `sy: float` (client-predicted scroll offset synced back to the guest) |
| `0xA0` | `clipboard` | `mime`, `data: bytes`, `alternatives?: [{ mime, data: bytes }]` |
| `0xA1` | `drop.enter` | `id`, `x`, `y`, `mimes: [mime]` |
| `0xA2` | `drop.motion` | `id`, `x`, `y` |
| `0xA3` | `drop.leave` | (empty map) |
| `0xA4` | `drop.perform` | as `clipboard` |
| `0xA5` | `drag.take` | (empty map) |
| `0xB0` | `devices` | `devices: [device]` ([devices.md](devices.md#protocol)) |
| `0xB1` | `device.camera` | `device`, `seq`, `keyframe: bool`, `t_us`, `data: bytes` (H.264, Annex-B) |
| `0xB2` | `device.depth` | `device`, `t_us`, `size: [w, h]`, `data: bytes` (u16 LE millimetres) |
| `0xB3` | `device.audio` | `device`, `t_us`, `data: bytes` (20 ms Opus, 48 kHz mono) |
| `0xB4` | `device.motion` | `device`, `samples: [{ t_us, accel?, gyro?, magnet?, rotation?, pressure? }]` |
| `0xB5` | `device.gamepad` | `device`, `buttons: uint`, `axes: [float × 6]` |
| `0xB6` | `device.button` | `device`, `key: "volume-up"\|"volume-down"\|"camera"\|"action"`, `pressed: bool` |
| `0xB7` | `device.battery` | `device`, `level`, `charging`, `full`, `low_power`, `thermal` |
| `0xB8` | `device.error` | `device`, `reason: text` |
| `0xFE` | `ping` | `t_us`, answered by `pong` for round-trip time |

A `display` is `{ id: uint, width: int, height: int, scale: float, refresh_hz: float, hdr: bool }`.

Each pointer message positions the virtual pointer, pairs that absolute motion with
`relative-pointer-v1` motion for clients that bind it, then delivers buttons and scroll
axes in the same frame. The relative vector is the change in logical pointer position;
the guest applies no acceleration. The two motion timestamps share one monotonic sample
(milliseconds for `wl_pointer`, microseconds for relative motion). This does not change
the pointer message's pixel coordinates or its precise-pixel versus wheel-click units.

- `frame.data` is Annex-B for H.264 and HEVC, with parameter sets on keyframes; for AV1 it is
  one temporal unit of low-overhead OBUs with the sequence header on keyframes. A frame
  carries no alpha. A window with `alpha: true` gets no frames: every picture of it, the
  first and the answer to `request_keyframe` included, is `tile` messages of 8-bit RGBA
  PNG (straight alpha) over a transparent surface (or `surface.batch` when `atlas` is
  negotiated); the tiles of other windows are 8-bit RGB.
- `text` is text-input-v3. Deletions (`delete_before`, `delete_after`, in grapheme
  clusters) are sent to every surface as BackSpace and Delete presses, one per cluster,
  before the commit; that removes one grapheme cluster in every toolkit, where
  `delete_surrounding_text` depends on the application's surrounding-text bookkeeping
  (Chromium drops it). The commit and pre-edit text go through text-input-v3 when the
  focused surface has it enabled; otherwise (an X11 app through Xwayland, for example)
  the commit is typed as key presses and pre-edit text is not shown. Clients send Return as
  a `key` press/release (`0xFF0D`), not a committed newline: single-line fields can ignore
  newlines committed by an input method.
- `text_input` fires when the focused window's text-input-v3 is enabled or disabled, and
  while enabled whenever the application reports new surrounding text. With the
  `text-input-v3` feature the client shows and hides the keyboard from it, and treats a
  `text` cursor shape only as a fallback. `surrounding`, `cursor` and `anchor` come
  together: the application's text around the caret (at most 4000 bytes of UTF-8), and the
  caret and the selection's other end as byte offsets into it, on character boundaries.
  They are absent when the application reports none, and for password and PIN fields and
  fields hinted sensitive or hidden, whose text never leaves the computer.
- Clients keep pointer gestures (tap, long-press right-click, swipe to scroll) for
  `xwayland: true` windows and send real touch to native Wayland ones, because most X11
  apps turn a touch drag into a selection. Emulated pans retain one gesture owner;
  a finger-count change cancels that pan. Card and free-desktop scroll delivery,
  including momentum, stops when its connection or coordinate mapping changes.

caboose-display sends a subset of these messages. It sends named cursors (`cursor.named`)
and no `cursor` images; tiles only as `png` in legacy mode; `alpha: true` for windows of kind `popup` and
`alpha: false` for every other; no `icon`, because Smithay 0.7 supports neither
xdg-toplevel-icon-v1 nor `_NET_WM_ICON`, so the phone resolves a window's icon from the
computer's app list by its `app_id` or class; `video.create` and `video.update` without
`z`, `color` or `extradata`; and no `notification` (the computer's notifications reach
the app through the host, from [guest/notifications](../guest/notifications)). It delivers
`pencil` as tablet-unstable-v2 pen events: `hover` and `motion` move the pen (bringing it
into proximity of the surface under it), `down` and `up` are the tip's contact, `leave` and
`cancel` take it out of proximity; pressure maps to 0–65535 and tilt passes through in
degrees. The clipboard carries text, images and files ("Clipboard" below).

### Surface Atlas (`0x23` `surface.batch`, `0x24` `surface.reset`)

When the client advertises `atlas: true` in `ClientHello` and the server includes `"atlas"`
in `ServerHello.features`, window surfaces are transmitted as atomic byte-perfect
`surface.batch` (`0x23`) updates instead of lossy H.264/HEVC `frame`s (`0x10`). This is
**Layer 0** of the OS Decomposition ("Zero Server Video") architecture, implemented in
`guest/display/protocol/src/atlas.rs`.

Each `surface.batch` applies operations to window `id` (at surface dimensions `size: [w, h]`
and window-local placement `rect: [x, y, w, h]`) in strict deterministic order before
acknowledging `pts_us` via `ack` (`0x83`):

1. **`copies` (`CopyRect`)**: Each `[dx, dy, x, y, w, h]` copies the rectangle from source
   `[x - dx, y - dy, w, h]` of the window's existing retained texture into destination
   `[x, y, w, h]` (using an intermediate scratch blit so overlapping scroll regions never
   alias). The phone queues the GPU copies and dirty pixel uploads together; failure to
   allocate a required resource rejects the batch and requests a keyframe instead of
   acknowledging a partial picture. Ordinary touch/wheel input remains server-authoritative;
   pixel copies do not establish a semantic scroll target for local prediction.
   The server's scroll detector (`detect_scroll_copy`) hashes rows inside damaged
   regions (`w >= 64 && h >= 64`) with `XXH64` and emits a `SurfaceCopy` whenever at least
   60% of overlapping rows match a vertical displacement `dy`, reducing scroll bandwidth to
   only the newly exposed strip.
2. **`fills`**: Each `[x, y, w, h, rgba]` fills a solid rectangle with packed 32-bit
   `0xRRGGBBAA` color. Single-color 64×64 blocks are coalesced into `fills` rather than
   encoded as tiles.
3. **`refs` (`XXH64` tile cache references)**: Each `[x, y, hash]` blits a previously cached
   64×64 RGBA8888 tile identified by its 64-bit `XXH64` (`seed = 0`) content hash onto
   `(x, y)`. Both server and client maintain a session-wide content-addressed tile cache,
   so repeated UI chrome, icons, and text blocks across windows or scroll positions cost
   only a 16-byte reference.
4. **`tiles` (Lossless UI micro-codec)**: Newly observed tiles `{ x, y, w, h, fmt, hash?, data }`
   are decoded, blitted to `[x, y, w, h]`, and inserted into the client's `XXH64` tile cache
   when `hash` is present.

The adaptive lossless UI micro-codec (`encode_atlas_tile` / `decode_atlas_tile`) inspects the
unique RGBA8888 colors in each `w × h` tile and prefixes the payload with a 4-byte
little-endian uncompressed byte length followed by an LZ4 raw block:

- **`pal2-lz4` (1–2 unique colors)**: Uncompressed payload is `c0: [u8; 4]`, `c1: [u8; 4]`,
  followed by `⌈(w × h) / 8⌉` bytes of MSB-first 1-bit palette indices (`0 → c0`, `1 → c1`).
- **`pal16-lz4` (3–16 unique colors)**: Uncompressed payload is `count: u8`, `palette: [u8; count * 4]`,
  followed by `⌈(w × h) / 2⌉` bytes of 4-bit nibble-packed palette indices (even pixel in high
  nibble `byte >> 4`, odd pixel in low nibble `byte & 0x0F`).
- **`rgba-lz4` (> 16 unique colors)**: Uncompressed payload is the raw `w * h * 4` RGBA8888
  pixel buffer compressed with LZ4.
- **`png`**: Standard lossless PNG bytes.

`surface.reset` (`0x24`, `{ epoch: uint }`) clears the client's `XXH64` tile cache when the
server evicts its dictionary or advances the cache epoch.

### Scene Graph & Guest Interceptor (`0x25` `scene.font`, `0x26` `scene.commit`, `0x9A` `scene.scroll`)

When the client advertises `scene: true` in `ClientHello` and the server includes `"scene"`
in `ServerHello.features`, the server streams **Layer 1** retained vector and glyph scene
graphs alongside Surface Atlas updates:

- **`scene.font` (`0x25`)**: Registers an outline font face (`font`: 64-bit `XXH64` hash of
  the font bytes with `seed = 0`, `index`: face index within a TTC collection, optional
  `family` name, and `data`: raw TrueType/OpenType bytes). Each `(font, index)` pair is
  deduplicated and sent at most once per session.
- **`scene.commit` (`0x26`)**: Updates the retained scene tree for window `id` at sequence
  `seq`, timestamp `pts_us`, and root node `root`. When `reset: true`, the client clears
  previous nodes for the window before inserting `nodes` and pruning `remove`. Each node
  carries `id` and `kind`:
  - `group`, `clip`, `rclip`: Container and clipping nodes with `rect`, optional per-corner
    radii `radius: [tl, tr, br, bl]`, and `children: [node_id, ...]`.
  - `scroll`: Scrollable viewport container with `rect` (viewport bounds), `scroll`
    (content offset and size `[sx, sy, cw, ch]`), and `children`.
  - `rect`, `border`, `shadow`: Vector box primitives with `rect`, optional `radius`, and
    32-bit `0xRRGGBBAA` `color`.
  - `glyphs`: Positioned glyph run referencing `font` (`XXH64`), point `size`, `color`,
    `rect`, and `glyphs`: packed 10-byte little-endian records `(glyph_id: u16 LE, x: f32 LE, y: f32 LE)`.
  - `path`: Binary vector path stream (`0x01` MoveTo, `0x02` LineTo, `0x03` QuadTo,
    `0x04` CubicTo, `0x05` Close with IEEE-754 `f32` LE coordinates) and `color`.
  - `surface`: Embeds a Surface Atlas or media surface `surface` inside the vector tree.
- **`scene.scroll` (`0x9A`)**: Client → server feedback `{ id, node, sx, sy }`. The iOS client
  runs touch pan and 120 Hz ProMotion momentum physics locally on `scroll` nodes and streams
  the predicted offset `(sx, sy)` back to the guest so the application's scroll state stays
  synchronized without round-trip frame latency.

**Guest Scene Interceptor (`guest/scene`) & Headless Liveness Invariant.** Inside the Linux
guest, `guest/scene` provides:
1. `libcaboose_scene_cairo.so` (`guest/scene/src/caboose_scene_cairo.c` and `src/scene_wire.h`),
   an `LD_PRELOAD`-compatible Cairo/GTK/Qt interceptor with zero link-time dependency on
   `libcairo` (resolving symbols via `dlsym(RTLD_NEXT, ...)`). It hashes font faces with
   `cb_xxh64`, deduplicates `0x25` `scene.font` registrations per session, packs 10-byte
   glyph records into canonical RFC 8949 CBOR `0x26` `scene.commit` frames over the
   non-blocking `$CABOOSE_SCENE_SOCKET`, and polls `0x9A` `scene.scroll` events.
2. `chromium/caboose-chromium-scene.conf`, configuring Chromium and Electron apps
   (`claude-desktop`, `chatgpt`, `code`, `obsidian`, `chromium`) for native Ozone-Wayland
   subsurface delegation (`WaylandOverlayDelegation`), hardware VA-API decode, and smooth
   scroll tree emission.
3. `libcaboose_wsi_promote.so` (`VK_LAYER_CABOOSE_wsi_promote`), an implicit Vulkan WSI and
   Mesa Zink (`MESA_LOADER_DRIVER_OVERRIDE=zink`, `GALLIUM_DRIVER=zink`) promotion gate
   enabled only when `CABOOSE_WSI_AUTO_PROMOTE=1` and `CABOOSE_SEAT != "agent"`. It promotes
   3D, Vulkan, Zink, and Proton swapchains while keeping denylisted 2D desktop tools and
   Electron apps on the Scene Graph and Surface Atlas lanes.
4. **Headless Liveness Invariant (Invariant A)**: The guest computer must always continue
   unattended work when the phone disconnects or when running headlessly on the agent seat.
   If `$CABOOSE_SCENE_SOCKET` is unset, missing, refuses connection, or returns
   `EAGAIN`/`EWOULDBLOCK`/`EPIPE`/`ECONNRESET` on write, `cb_scene_client_t` immediately
   switches to non-blocking local passthrough mode (`SO_NOSIGPIPE` / `MSG_NOSIGNAL` /
   `O_NONBLOCK`) without stalling the application or raising `SIGPIPE` (< 5 ms for 1,000
   commits).

### Direct content scroll units

The iOS direct-content pan negates finger movement for natural direction, integrates
tracking and inertia in view points, then maps each axis by reported guest size divided
by presented surface size. It applies a reference gain of 1/12 before sending precise
pointer deltas. Hardware wheel/trackpad input, dedicated phone trackpads, native
`wl_touch` gestures and the guest's paired relative/absolute pointer motion are unchanged.
The precise wire values remain scaled pixel units; they do not guarantee content pixels.
The guest divides them by output scale and sends `wl_pointer.axis` with source `finger`.
Ordinary wheel clicks still use axis value 15 and value120 120 per click.

[Xwayland's scroll dispatch](https://gitlab.freedesktop.org/xorg/xserver/-/blob/xwayland-24.1.6/hw/xwayland/xwayland-input.c)
converts an axis value to XI2 increments by dividing by 10. The reference
[Chromium X11 consumer](https://chromium.googlesource.com/chromium/src/+/130.0.6723.116/ui/events/x/events_x_utils.cc)
uses 120 units per wheel increment; its
[native Wayland consumer](https://chromium.googlesource.com/chromium/src/+/130.0.6723.116/ui/ozone/platform/wayland/host/wayland_pointer.cc)
also converts axis values by 120/10. These explain the reference gain of 12; they do
not establish a particular Steam build's embedded Chromium version. Newer Chromium
has an unscaled-touchpad path, and other toolkits choose different steps or acceleration.
No application identity selects the phone's calibration.

For one axis, finger distance `d`, presented extent `V`, guest extent `P`, output scale
`s`, and client response `g`, the phone sends `-d * P / V / 12`, the guest sends
`-d * P / V / 12 / s`, and reference content moves by that amount times `g`.
Rendering back into the presented surface multiplies by `s * V / P`, leaving
`-d * g / 12`. Thus the reference `g = 12` follows finger distance independently of
rotation, fitting and output scale, including 1.5; other responses remain proportional.
Wayland fixed-point quantization, client rounding, zoom and scroll boundaries limit this
model. The client does not infer or compensate for per-application response differences.

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
deliver, then `drop.motion` as it moves, over the same window or another. Applications
read what a drag offers as it enters, and many decide from it whether to accept, but the
client can deliver the content only once the user has let go. So the server follows the
finger and enters the application under it as each kind of window allows:

- **X11 windows** get an XDND (version 3 to 5) drag from the server's own X client, with
  the copy action only, as the finger moves. `drop.status { accepted }` reports the
  window's answer whenever it changes. A window that asked for the data before it was
  there is entered again once it is.
- **Wayland windows** are entered only on the drop, with the content ready: a
  compositor-owned Wayland drag follows the finger without entering any surface, and
  `drop.status` is sent without `accepted`.

When the user lets go, the client prepares the content (it uploads files to the transfer
area first) and sends `drop.perform` with it: the types are a subset of those it entered
with, and its files must be in the transfer area. The server then drops on the
application under the last position. A Wayland application is entered and the drag
released once it accepts the offer, has been sent everything it asked for and has had
0.6 s to read it, the drag moving over it meanwhile; an XDND window is dropped on once it
accepts, its position renewed for up to 2 s. `drop.result` ends the drop: `ok`, or
`rejected` (the application did not accept it; a Wayland application has 3 s), `cancelled`
(no drop was in progress), `timeout` (the application did not finish within 30 s, or the
drop hovered 15 minutes without a `drop.motion`) or `invalid` (the content failed the
checks). `drop.leave` ends a drop without a result. While a drop is in progress the server
ignores the client's `pointer` messages, which would move the drag.

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

### Phone-owned scrolling

A one-finger or two-finger pan over a window shown with pointer gestures is scrolled by
the phone itself. That covers a window whose picture the phone draws (a card or tile) and
a live GPU window whose presented pictures the phone captures
([presented-picture capture](gpu-live.md#presented-picture-capture)). Games and GPU
streams are not covered. Over a live GPU layer, the phone draws its compositions in an
overlay above the layer, and only while it owns the scroll. The wire is unchanged: the app still receives precise `pointer` scroll. The phone
uses it differently:

- **The phone owns the position.** Finger tracking and iOS momentum (UIScrollView's normal
  deceleration, 0.998 per millisecond) move the content at display rate, 120 Hz on
  ProMotion, from the first movement. The phone draws the window's captured pictures moved
  to that position.
- **The app is driven ahead.** Forwarded scroll aims the app where the phone will be once
  the app's picture arrives: the position one measured input-to-picture latency ahead. That
  target is exact during momentum and extrapolated from finger velocity while tracking.
  While content moves fast, the target adds up to half the region more, fading below 1500
  picture pixels per second. The content a flick brings into view is therefore already in a
  captured picture. Earlier pictures cover the content behind it.
- **Prefetch at rest.** 0.1 s after a scroll hands back, the phone drives the app 0.7 of
  the scrolling region further in the scroll's direction and back. It shows the unchanged
  picture throughout, so the next flick's first frames find their content captured. Other
  input (a tap, a key) brings the app straight back.
- **Every picture is measured.** Each captured picture gets line signatures on the GPU:
  per row and per vertical band of about 40 pixels, the mean colour and the mean luma step
  along the row. Horizontal scrolling uses the transpose. A coarse search of sampled
  detailed cells, over the shifts the forwarded scroll makes possible, finds the rigid
  motion relative to the previous picture. A full search follows only for an unexpected
  jump, and it must be explained by much more of the picture. Cells explained only by
  standing still bound the moving region. Toolbars, sticky headers, status bars, sidebars
  and gutters are drawn from the newest picture, unmoved. Inside the region, blocks of 16
  lines by one band whose detail stood still while the content moved are fixed overlays
  (a floating button, a chat bubble). Up to four per picture are kept, drawn from the
  newest picture where they are, and left out of every picture's scrolled content, so
  they leave no copies behind. No application identity is used.
- **Learning the window.** The measured placements give the app's latency (the 75th
  percentile of recent samples) and its gain (content pixels per pixel sent, from rest to
  rest). Forwarded scroll is divided by that gain, so any toolkit's response follows the
  finger one to one. A run in which three pictures in a row stood still while the forwarded
  scroll kept moving one way was clamped at an end, so its gain is not learned.
- **Ends of content.** The app may stop moving while it is still being driven, for twice
  its latency plus 120 ms (or 1.5 times its longest recent stall). Pictures that do not
  move and no pictures at all look alike at an end and in an app whose scrolling is busy
  (a page decoding images). So the phone sends a 24-pixel step back, alone and behind its
  own picture. Only an app held at its end can answer by moving back; that confirms the
  end. An app that moves on was stalled, and one that does not answer within a second is
  driven again. Past a confirmed end the phone resists as UIScrollView does, and momentum
  that reaches it springs back. Each new gesture forgets inferred ends and tries again; a
  picture placed beyond an end removes it. A toolkit adapter's reported range stays.
- **Stalls.** Consecutive pictures must overlap to be measured. The app is therefore
  driven at most 0.6 of the region per picture interval. Its input is held while it has
  shown nothing for three picture intervals and at least 80 ms, so the picture after a stall still
  overlaps the last one. A picture that cannot be related to earlier ones is placed where
  the forwarded scroll had taken the app, and the earlier pictures are dropped.
- **Bounded reveal.** Content no captured picture covers shows in the colour of the
  nearest captured edge. It may fill at most 40% of the region. Past that, the shown
  position resists and catches up as pictures arrive, never slower than the gesture.
- **Hand back.** When the phone comes to rest, the app is brought to the same position,
  with up to three correction rounds at the newly learned gain. Once the app's newest
  picture is within 1.5 picture pixels of it, the phone draws the app's own picture
  again. After the corrections, an app that stays within 6 pixels, or any app after 1.5
  seconds at rest, takes over where it is. The phone's content never moves after the
  finger lets it rest. A touch on moving content stops it without clicking, as in any iOS
  scroll view.

The phone keeps captured pictures for three seconds after a scroll comes to rest, and at
most six of them, chosen for the content they add near the current position. Video layers
over the picture move with the scrolled content.

One GPU pass draws the region: per pixel, the newest captured picture that covers it
outside its fixed overlays, else the fill colour.

`CabooseKit/Scroll` implements this. `LocalScroll` is the model, free of UIKit and Metal.
`ScrollMotionEstimator` measures motion, `LocalScrollRenderer` captures and draws, and
`LocalScrollController` runs them for a view. A toolkit adapter that reports a picture's
exact scroll offset, region, range and fixed rectangles replaces measurement for that
picture (`ScrollObservation.reported`).

### Audio

The computer's sound is one Opus stream: each `audio` message is one 20 ms packet (960
samples per channel) at 48 kHz, stereo, with `pts_us` the server `CLOCK_MONOTONIC` of its
first sample, the clock of `frame` and `video.present`, so a client plays sound and pictures
on one timeline. It goes only to a client whose hello lists `"opus"` in `audio_decoders`.
Digital silence is not sent after a second of it: a gap in `pts_us` is silence, and packets
resume without a reset. The server lists `audio` in `features` when it has sound to send.
The iOS player anchors server time to the monotonic host clock when starting playback;
it does not use the asynchronously updated renderer timebase to detect packet backlog.
Audio-session interruptions clear that anchor before the next playback begins. Live
window and motion pictures present immediately; only passthrough presentation uses the
shared audio timeline, and an idle live video renderer cannot hold audio preroll.

### Video streams

The iOS app omits `video_decoders`. Independently, the compositor requests server
decode for all marker streams: codec support alone does not prove correct foreground
composition (see [composition admission](codec-passthrough.md#composition-admission)). It
advertises `scaled_motion`, allowing motion streams in the window codec. PCM playback uses decoded sample durations to join adjacent
packets despite capture-timestamp jitter; gaps over 200 ms retain the server timeline.
Compressed playback ingress retains at most 16 queued or running packets and 64 KiB of
payload. Excess or empty packets are rejected before dispatch, counted as
`ingress_rejected` in the five-second audio log. This adds no waiting or preroll.
After rejection, the next admitted packet retains its server timestamp instead of joining
across the missing duration; the Opus decoder remains alive, with no synthetic concealment
packet or replay. Packet loss can therefore be audible. Existing playout thresholds govern
any rebuffer. Stop and interruption invalidate old jobs without releasing their memory
budget until those jobs exit.
Playback runs at unity rate between explicit start, rebuffer and stop operations; ordinary
packets do not write the synchronizer rate. AVFoundation may automatically
flush queued audio on a rate or route change. The phone serializes cleanup of surviving
buffers with enqueue, without resetting the clock or rate; discarded audio is not replayed.
Renderer-specific notification generations are invalidated on stop and interruption.
The explicit playout policy starts with a 120 ms jitter buffer, grows it by 20 ms after
underruns up to 240 ms, and restarts for backlog beyond another 300 ms. These policy
restarts are separate from AVFoundation automatic flush loss. Stopping playback clears
the clock anchor; explicit time/host anchors are used only when playback starts or
restarts. There is no continuous sample-clock correction: sustained source/host clock
mismatch can require rebuffering, and hardware/host clock drift can accumulate between
explicit rebufferings.


A video stream is layered into a window (`window`) by the client: it decodes it with its
own decoder and draws it at `rect` (window-local display pixels, the whole picture,
scaled to fit), showing only `clip` when present (a scrolled or cropped player, or an
H.264 1088-line picture whose 1080 lines are visible). Every video stream is drawn above
the window's own picture, ordered by `z` (higher on top); frames carry no alpha (only a
popup's picture does, as PNG tiles with alpha, and a popup has no video streams), so the
server sends the visible region as `clip` instead of relying on a hole in the window. Video ids are their own namespace, unique for the server's lifetime.
The client intersects `clip` (or `rect` when absent) with the window's bounds and `rect`;
clipping preserves the scale and origin of the complete decoded picture. The window's
picture and video layers share one window-pixel-to-view transform, including while the
previous picture stretches during a resize. The pixel coordinate space changes only
when the replacement frame is decoded, not when resize metadata arrives. A playback layer has one active presentation
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
  picture's pixel scale by default, to a client that lists that codec in `video_decoders` or advertises
  `scaled_motion`. With `scaled_motion`, a software-encoded region divisible by four is box-filtered to
  half width and height and `video.create.scaled` is true; `rect` and `clip` still use
  window coordinates. The client upscales the decoded picture with MetalFX where available,
  falling back to vImage on the CPU if the scaler cannot be made or fails; if that fails,
  the video layer scales the decoded picture.
  A window with a passthrough stream bound gets none. While the stream exists, the
  window's `frame`s keep the region frozen, including keyframes, replacement codec buffers
  and refinement passes; the client shows the stream over it. Refining the base does not
  recreate the motion encoder or lose its reference frames. Once the
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

### Game handoff

A client whose hello says `wasm: true` runs games itself. A game is an ordinary toplevel on
the computer, made by `caboose-game-run`; `game.create` tells the client that window's game
runs on the client, from files under `root` (relative to `/home/caboose`) starting at
`entry` (relative to `root`), and which directories it persists (`saves`: `mount` in the
game's Emscripten file system, `path` relative to `/home/caboose`). The server sends it after
the window's `window.create`, in the hello burst too, and `game.destroy` before the window
is withdrawn or when the game ends. Game ids are their own namespace, unique for the server
process's lifetime. While a client runs a window's game, the window sends no `frame`,
`tile` or video stream and `request_keyframe` for it has no effect; `configure` and `close`
work as for any window, and once the game ends a remaining window sends its picture again
from a keyframe. The launcher, its socket and the client's side are specified in
[game-handoff.md](game-handoff.md).

### Agent-app web views

A client that says `webview: true` may receive `webview.create` after its window is
announced. The app id determines `root` as `Apps/<id>` under the home; `entry` is a relative
page. `bridge` is a random app-instance socket identifier and `grant` is a random display
session grant. They reach the native client over the authenticated display connection, not
the page. The launcher hears the current grant in the game socket's `mode` message. The
guest accepts bridge calls only for its current grant and document revision. A reconnect or
takeover rotates the grant, closes the previous document and ends its processes. A client
that cannot run the view sends `webview.decline`; the compositor withdraws it and the app
runs locally. The window sends no pictures during handoff. See
[agent apps](../guest/apps/README.md#native-handoff).

### GPU streams

A client whose hello says `gpu: true` renders windows from their applications' Vulkan calls.
`gpu.create` binds stream `id` to `window`; `gpu.data` carries the stream's bytes in order,
`offset` counting from its first byte, which is a GFXReconstruct capture file the client
replays on its own GPU into the window. The client answers with `gpu.ack` as it consumes the
stream; the server sends at most 4 MiB beyond the last acknowledged offset. A client that
connects later receives the stream from offset 0. `gpu.destroy` ends it; with
`reason: "spool-limit"` the stream outgrew what the server keeps of it and cannot be rendered. While a client renders
a window's stream, the window sends no `frame`, `tile` or video stream. The launcher and the
relay are specified in [gpu-stream.md](gpu-stream.md).

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

### Agent application profile environment

When the compositor starts with `CABOOSE_SEAT=agent`, its launch file additionally
publishes the inherited HOME, XDG_CONFIG_HOME, XDG_DATA_HOME, XDG_CACHE_HOME,
XDG_STATE_HOME, CABOOSE_SEAT, MOZ_NO_REMOTE, DBUS_SESSION_BUS_ADDRESS, VSCODE_PORTABLE,
CHROME_CONFIG_HOME, CHROME_USER_DATA_DIR and PATH. VSCODE_IPC_HOOK_CLI is empty to avoid
reusing an inherited editor instance. The guest agent-profile launcher supplies these
values; the owner compositor's environment contract is unchanged. This changes no display
wire messages. See [persistent agent profiles](../guest/desktop-mcp/README.md#persistent-agent-gui-profiles).

`CABOOSE_ATLAS_NO_REFS=1` disables cache references for isolated diagnostics and sends full lossless tiles instead. Copies and fills remain available. With this option unset, atlas sessions use references only to published cache entries; publication revalidates entries against eviction.
