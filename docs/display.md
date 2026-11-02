# Caboose Display

Caboose Display is the computer's display server: a headless Wayland compositor, with
Xwayland for X11 applications, that renders every window on the phone's GPU into its own
phone-resident images and presents each as one GPU layer, for the phone or TV to show as a
native surface. The code is in [guest/display](../guest/display); its README covers
building, running and testing it. This document is the design and the wire contract, the
Caboose Display Protocol.

## Design

```
 apps (Wayland, and X11 through Xwayland)
   │ wl_shm and dma-buf buffers (linear, or phone-resident: gpu-buffers.md), damage, frame callbacks
   ▼
 caboose-display   (headless Wayland compositor, Rust + Smithay, inside the computer)
   ├ one window per toplevel, dialog, popup and X11 window
   ├ pictures: each window rendered with OpenGL ES on Zink over the phone's GPU into its own
   │   phone-resident images, presented through the GPU broker (BUFFER_PRESENT, gpu-buffers.md);
   │   a window that is one phone-resident buffer is presented as it is
   ├ video: decoded on the phone through the Caboose VA-API driver (gpu-media.md)
   ├ games: WebAssembly games and agent-app web views handed off to the client
   ├ pacing: frame callbacks released on the client's vsync while a window has a free image
   ├ input: pointer, wl_touch, keyboard by keysym, text-input-v3
   └ sound: a private PulseAudio, sent as Opus
   │ Caboose Display Protocol (below): windows, input, clipboard, sound; relayed by caboose-host
   │ live GPU transport (gpu-live.md): every window's picture
   ▼
 CabooseKit (iOS): one surface per window, each showing that window's GPU layer
```

- **The compositor composites nothing across windows.** It is a window and buffer broker.
  Each window's surface tree is rendered alone, cropped to its window geometry, into its
  own images. The phone and the TV are the compositors, which is how each window stays a
  native surface with its own title, icon, size hints and parent.
- **Pictures reach the client only on the GPU.** The compositor is an OpenGL ES client of
  Mesa's Zink on the Caboose Vulkan driver, whose memory is on the phone
  (`compositor/src/render.rs`). Each window has at most two images: one rendered while the
  other is shown or queued. A window whose whole tree is one phone-resident client buffer
  covering its geometry is presented as that buffer, without rendering, and a window whose
  application draws into its own phone surface (a Vulkan swapchain on its Wayland surface
  or X11 window) is presented by the application ([gpu-live.md](gpu-live.md)). The
  Display Protocol carries no pixels.
- **Only what changed is drawn and sent.** A per-window damage tracker redraws only the
  damaged part of an image. A `wl_shm` buffer has its own staging buffer and uploads only
  the client's damaged rectangles; client dma-bufs, phone-resident ones included, are
  imported without their pixels passing through the computer.
- **The client paces the applications.** Frame callbacks are released on the client's
  display refresh, and only while the window has an image the broker is not holding, so
  applications draw at the rate the phone shows.
- **Text stays sharp.** A window's picture keeps its buffer's own density, so its pixels
  are drawn one for one and the phone scales the picture to the window it shows.
- **Popups keep their shape.** A popup (an xdg popup, an X11 override-redirect menu or
  tooltip) has its rounded corners and shadow inside its window geometry, so it is sent
  with `alpha: true`; its images keep premultiplied alpha and the client shows it on a
  transparent surface.

Without a phone's GPU attached, the compositor renders the same way on the computer's CPU
Vulkan implementation, which the routing layer presents as a GPU
([guest/gpu/routing-layer](../guest/gpu/routing-layer)), and presents nothing. When the
phone's executor changes, the renderer is made again and every window is drawn again from
the buffers its clients last committed.

GTK 3 ordinary windows use the KDE server-decoration default; xdg-decoration
clients are configured for server-side decorations. Both leave their window controls
to Caboose. The launch environment sets `GTK_CSD=0` for the X11 GTK fallback.
Application-supplied headerbars and menus remain content, but the window-button layout
is empty (`:`) everywhere toolkits read it: the desktop portal's
`org.gnome.desktop.wm.preferences` `button-layout`, the GSettings default, and
`gtk-decoration-layout` in the GTK settings files. GTK 3 and 4 headerbars, libadwaita,
Firefox, and Chromium's and Electron's window-controls overlay (VS Code) therefore draw no
minimize, maximize or close buttons. Qt asks for server-side decorations and draws none.

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
| Phone's GPU ([gpu-live.md](gpu-live.md)) | windows render on it while a phone's executor is attached | none: windows render on the computer's CPU device and are presented nowhere |
| D-Bus session bus | `/run/user/1000/bus` | `/run/user/1000/agent-bus`, with its own notification endpoint |
| Launch environment | `/run/caboose/display.env` | `/run/caboose/agent-display.env` |
| Game socket | `$XDG_RUNTIME_DIR/caboose-game.sock` | none (`--no-games`) |
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
  `XDG_RUNTIME_DIR`, toolkit backends, `CABOOSE_DISPLAY_CONTROL`, `PULSE_SERVER` when it
  plays sound, `CABOOSE_GAME_SOCKET` when it hands games off, `IBUS_ADDRESS` when IBus
  runs, and on the owner's display the phone GPU driver's variables and, when the Caboose
  VA-API driver is installed, `LIBVA_DRIVER_NAME=caboose`) to its env file in sh syntax.
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

## Video

Video is decoded where the picture is, on the phone. On the owner's display, applications
decode through the Caboose VA-API driver as through any hardware decoder
(`LIBVA_DRIVER_NAME=caboose` in the launch environment when the driver is installed). The
driver sends the compressed bitstream to the phone through the GPU broker, the phone
decodes it in hardware, and the decoded picture appears in the Vulkan image the
application samples, so the application composites the video into its window itself. The
contract is [gpu-media.md](gpu-media.md) and the driver is
[guest/vaapi](../guest/vaapi/README.md). Video an application decodes and draws itself is
part of its window's picture like anything else it draws. The Display Protocol carries no
video.

## Caboose Display Protocol (v0)

The server is `caboose-display` in the guest, on WebSocket `0.0.0.0:14600` for the
owner's display and `0.0.0.0:14601` for the agent seat (any path; it accepts the `binary`
subprotocol). The host relays it byte for byte. Each instance serves one client at a time:
a new authenticated client replaces the previous one, which gets
`bye { reason: "replaced" }` and is closed. A client should not reconnect on its own
after `replaced`, or two devices would keep taking the display from each other. A client
that sends nothing for 30 s (no `vsync` or `ping`) is taken for suspended or gone
and is closed. A client without a display to pace pings at least every 10 s. The Rust
codec is `guest/display/protocol`, and `guest/display/vectors/` pins every message byte
for byte.

### Framing and encoding

- The client parses a **byte stream**. WebSocket message boundaries carry no meaning (the
  server happens to write one protocol message per WebSocket message).
- Each message is `type: u8`, `length: u32` little-endian, then `payload[length]`. The
  payload is always exactly one CBOR map with text keys. Binary content (PNG, Opus, a
  device's media) is a CBOR byte string field, so it is raw
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
  geometry: client-side shadows are outside it and are cropped out of the picture.
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
  ID during that bootstrap; explicit pacing IDs are never redirected. Pictures do not
  depend on the client selecting a replacement output.
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
- A new X11 top-level gets the size it asked for, clamped to its display, except one with
  no size hints that asks to be larger than the display (a Wine virtual desktop of a
  fixed resolution): it keeps that size and its `min` and `max` are reported as that
  size, so the phone keeps it fixed-size and shows it scaled to fit. Resizing it, smaller
  or larger, would cut or pad its picture, since the application keeps drawing at the size
  it chose, and a swapchain child that no longer covers it would lose its GPU surface.
  It is placed where it asked to be when its size hints give a position (Wine gives every
  window one; a splash centres itself), otherwise centred, and moved only as far as keeps
  it on its display.
- A window configured `maximized: true` with a `geometry` takes that geometry and keeps it
  while it stays maximized; one maximized without a geometry (the application's own
  request) takes its display's rectangle. An X11 application's own configure request
  sizes its window, except while it is maximized or fullscreen, and moves it while the
  client has not laid it out (given it a geometry), as any window manager lets a floating
  window move itself.
- An output mode/origin change reconfigures existing fullscreen and maximized windows
  through the common Wayland/X11 configure path, preserving their state flags; a maximized
  window takes the changed display's rectangle until the client configures it again. Removed
  outputs first remap to the primary output. Unchanged outputs and ordinary windows do
  not receive a geometry configure from this reconciliation. Fullscreen pictures fit
  centered in the client viewport without transient stretching; pointer/touch input,
  text drops and popup roots use the same fitted rectangle. Ordinary constrained tiles
  retain their top-aligned fit, including pending keyboard and tile resizes. Configure
  metadata can precede the window's new picture: presentation retains the picture
  dimensions until its successor is shown, without animating picture bounds between aspects.
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
- Input `x`/`y` are window-local display pixels, with the window's geometry origin as their
  origin. A window's picture covers its geometry; when the picture's pixel size differs
  from it (a buffer at its own density, a scale-1 Xwayland window on a scale-3 display)
  the client scales it.
- Window ids are unique for the server's lifetime and survive reconnects. A new server
  process starts its ids again, so a client keeps a window's last picture across a
  reconnect only when the hello's `epoch` (random for each server process) is the one it
  had; a hello without an epoch proves nothing.

### Handshake

The client speaks first, as soon as the socket opens, with `hello` carrying the
`display.token` from `/v1/session`. The server re-reads the per-wake token file on every
hello. On a mismatch it sends `bye { reason: "auth" }` and closes; on an unsupported
version, `bye { reason: "version" }`. Otherwise it answers `hello` with the display ids it
accepted, its `features`, its `epoch`, and `gpu_live_epoch` while the live GPU service is
ready (the namespace of the window surfaces the phone binds, [gpu-live.md](gpu-live.md));
then it sends `window.create` for every live window. Each window's picture reaches the
client over the live GPU transport, not this connection.

The client also parses the optional `gpu_live_epoch` as a 16-byte CBOR byte string
with at least one nonzero byte, separately from the text `epoch`.
Absent or malformed values leave live GPU display identity unavailable without rejecting
the ordinary display. Parsing this identity does not enable a GPU executor or bind a layer.

The server writes every `window.create` of a hello before it reads the client's next
message, and answers `ping` on the same ordered connection. A `pong` to a ping sent after
the hello therefore follows the last `window.create` of that hello: at that point the
client's windows are exactly the server's. A server that sends `epoch` guarantees this
order; a client relies on it only from such a server.

`features` is any of `vsync`, `touch`, `pencil`, `text-input-v3`, `clipboard`,
`clipboard-types`, `drop`, `drag`, `cursor-named`, `audio`, `xwayland`, `wasm`, `webview`,
`devices`, `targets`. A feature is listed only when the server implements it.
caboose-display always lists `vsync`, `touch`, `pencil`, `text-input-v3`, `cursor-named`,
`clipboard`, `clipboard-types`, `drop` and `drag`; `xwayland` when Xwayland runs; `audio`
when it plays sound; `wasm` when it hands games off (the owner's display) and the client's
hello says `wasm: true`; `webview` when the owner display and client support agent-app
handoff; `devices` when the owner's display accepts the phone's hardware
([devices.md](devices.md)) and the client's hello says `devices: true`; and `targets` when
the touch target provider is installed and the client's hello says `targets: true`.

### Pacing and flow control

- `pts_us` (in `audio`) is the server's `CLOCK_MONOTONIC`, in microseconds.
- The client sends `vsync` once per refresh of each display that shows a window. A
  window's frame callbacks are released on its display's vsync while the window has an
  image the GPU broker is not holding (each window has two: one rendered while the other
  is shown or queued), and again when the broker releases one, so an application slows to
  what the phone shows. A window presented as its client's own buffer is paced by vsync
  alone. A display without current vsync gets callbacks once a second.
- The connection's 48 MiB WebSocket write-buffer cap applies; exceeding it closes the
  connection rather than accumulating more data. These limits bound work in flight; they
  do not guarantee a frame rate.

### Messages

Server → client (`0x01`–`0x7F`):

| Type | Name | Fields (`?` optional) |
| --- | --- | --- |
| `0x01` | `hello` | `version: uint`, `displays: [uint]`, `features: [text]`, `epoch?: text` (1–64 bytes; caboose-display sends 16 hex characters), `gpu_live_epoch?: bytes` (16 bytes, not all zero) |
| `0x02` | `window.create` | `id`, `parent?: uint`, `kind: "toplevel"\|"popup"\|"dialog"`, `title`, `app_id`, `icon?: bytes` (PNG), `geometry: rect`, `min?: size`, `max?: size`, `fullscreen: bool`, `display?: uint`, `xwayland?: bool`, `alpha?: bool`, `desktop_id?: text`, `pid?: uint` ([Windows and launches](#windows-and-launches)) |
| `0x03` | `window.update` | `id` plus any `window.create` field that changed |
| `0x04` | `window.destroy` | `id` |
| `0x17` | `game.create` | `id`, `window`, `root: text`, `entry: text`, `saves?: [{ mount: text, path: text }]` |
| `0x18` | `game.destroy` | `id` |
| `0x1C` | `webview.create` | `id`, `window`, `app: text`, `root: text`, `entry: text`, `bridge: text`, `grant: text` |
| `0x1D` | `webview.destroy` | `id` |
| `0x20` | `cursor` | `id?`, `image: bytes` (PNG), `hotspot: [x, y]` |
| `0x21` | `cursor.named` | `name` (cursor-shape-v1 / CSS names: `default`, `text`, `pointer`, `vertical-text`, …) |
| `0x22` | `text_input` | `id`, `enabled: bool`, `purpose?: text` (text-input-v3 content purpose: `normal`, `alpha`, `digits`, `number`, `phone`, `url`, `email`, `name`, `password`, `pin`, `date`, `time`, `datetime`, `terminal`), `surrounding?: text`, `cursor?: uint`, `anchor?: uint` |
| `0x28` | `targets` | `id`, `serial: uint`, `targets: [[x, y, w, h, kind]]` ([Touch targets](#touch-targets)) |
| `0x29` | `text_focus` | `id`, `editing: bool` ([Touch targets](#touch-targets)) |
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
| `0x81` | `hello` | `version: 0`, `token`, `displays: [display]`, `audio_decoders?: ["opus"]`, `wasm?: bool`, `webview?: bool`, `devices?: bool`, `targets?: bool` (booleans present only when true), `clipboard_types?: [mime]` (what the client takes from the clipboard besides text) |
| `0x82` | `vsync` | `display`, `t_us` (client monotonic) |
| `0x84` | `configure` | `id`, `geometry?`, `display?` (whose vsync paces it), `fullscreen?`, `maximized?`, `activated?` |
| `0x85` | `close` | `id` |
| `0x87` | `displays` | `displays: [display]`; replaces the set on a live session (rotation, a TV plugged in, a zoom change). The server re-lays-out and answers with `window.update` |
| `0x90` | `touch` | `id`, `points: [{ slot, phase: "down"\|"motion"\|"up"\|"cancel", x, y, force?, radius? }]`; one message is one `wl_touch.frame` |
| `0x91` | `pencil` | `id`, `phase: "down"\|"motion"\|"up"\|"cancel"\|"hover"\|"leave"`, `x`, `y`, `pressure` (0…1), `tilt: [x_deg, y_deg]`, `azimuth_deg` |
| `0x92` | `pointer` | `id`, `x`, `y`, `buttons: uint` (the pressed set: 1 left, 2 middle, 4 right, 8 back, 16 forward), `scroll?: { dx, dy, precise: bool, seq?: uint }` (pixels when precise, otherwise wheel clicks; `seq`: [Input sequencing](#input-sequencing)), `relative?: [dx, dy]` (motion in display pixels that leaves the pointer at `x`, `y`) |
| `0x93` | `key` | `keysym: uint`, `pressed: bool`, `mods: ["shift"\|"control"\|"mod1"\|"mod4"]` |
| `0x94` | `text` | `commit?`, `preedit?`, `cursor?: [begin, end]` (byte offsets into `preedit`), `delete_before?`, `delete_after?` (extended grapheme clusters) |
| `0x97` | `game.decline` | `id`, `reason: text` (at most 200 UTF-8 bytes; the server logs no more): the client cannot run game `id` ([game-handoff.md, "Declining"](game-handoff.md#declining)) |
| `0x98` | `webview.decline` | `id`, `reason: text` (at most 200 UTF-8 bytes) |
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
(milliseconds for `wl_pointer`, microseconds for relative motion). A message with
`relative` sends that vector as the relative motion instead, which is how a stick looks
around in a game. caboose-display implements pointer-constraints-v1: while a client holds a
locked pointer on the surface under the pointer (a game's mouse look on Wayland), the
pointer does not move and only relative motion reaches it; a constraint takes effect when
the pointer is on its surface. X11 games read the same motion as XInput 2 raw motion. This does not change
the pointer message's pixel coordinates or its precise-pixel versus wheel-click units.

- A window with `alpha: true` has a picture with alpha: its images keep premultiplied
  alpha, and the client shows it over a transparent surface. Every other window's picture
  is opaque.
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
- Clients keep pointer gestures (tap, a hold that aims the pointer, swipe to scroll) for
  `xwayland: true` windows and send real touch to native Wayland ones, because most X11
  apps turn a touch drag into a selection. Emulated pans retain one gesture owner;
  a finger-count change cancels that pan. Card and free-desktop scroll delivery,
  including momentum, stops when its connection or coordinate mapping changes.

caboose-display sends a subset of these messages. It sends named cursors (`cursor.named`)
and no `cursor` images; `alpha: true` for windows of kind `popup` and
`alpha: false` for every other; `icon` only for a toplevel that gives one as pixels
(`_NET_WM_ICON`, or xdg-toplevel-icon-v1 `wl_shm` buffers; an icon given only by name is not
sent, and the client resolves it from the computer's app list by `app_id`); and no `notification` (the computer's notifications reach
the app through the host, from [guest/notifications](../guest/notifications)). It delivers
`pencil` as tablet-unstable-v2 pen events: `hover` and `motion` move the pen (bringing it
into proximity of the surface under it), `down` and `up` are the tip's contact, `leave` and
`cancel` take it out of proximity; pressure maps to 0–65535 and tilt passes through in
degrees. The clipboard carries text, images and files ("Clipboard" below).

### Windows and launches

`desktop_id` names the desktop entry whose launch started a toplevel's process, as
`<id>.desktop`. It holds when the window's class says something else, as it does for an
application behind a wrapper script or a game started by its own launcher. A launch marks
the process it starts through its environment, which everything it starts inherits: GLib
sets `GIO_LAUNCHED_DESKTOP_FILE` and `GIO_LAUNCHED_DESKTOP_FILE_PID` for any entry it launches,
and Caboose's Apps launch adds `CABOOSE_DESKTOP_ID`. caboose-display reads them from the
window's process, or from its nearest ancestor that has them when the process cleared its
environment. A window belongs to the launch only if no process between it and the launched
process has a window of its own. So a program started from a launched terminal's shell is not
the terminal. A client matches launches and taskbar entries to windows by `desktop_id` first,
then by class (`app_id`, `StartupWMClass`).

`pid` is the process that owns a toplevel as the computer sees it: the Wayland client's, or for
an X11 window the X server's record of the client that created it (X-Resource
`LocalClientPID`), with `_NET_WM_PID` only when the server has none. `_NET_WM_PID` is the
client's claim in its own PID namespace, which for an application in Flatpak, such as a game
Steam runs, names a process of the sandbox. A client's taskbar is built from the windows that
exist, never only from the launches it made: every toplevel belongs to an application, matched
to a desktop entry by `desktop_id`, `StartupWMClass`, the entry's id, a Steam game's
`steam_app_<id>` class to the entry whose `Exec` runs `steam://rungameid/<id>`, the entry's
program, and finally another window of the same `pid`. A window no entry claims is an
application of its own, grouped with windows of the same class (else the same `pid`), drawn
with its `icon` and named by its class or title. An X11 window's `icon` follows the
application's changes to `_NET_WM_ICON` as `window.update`s.

### Scrolling input

A `pointer` message's `scroll` is in the window's pixels when `precise` (a finger) and in
wheel clicks otherwise. How the computer delivers it to Wayland and X11 applications,
and what they do with it, is the input system's ([input.md](input.md#scrolling)).

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

### Input sequencing

A client may number its scroll input: `pointer.scroll.seq` is the window's input sequence
number, per window, strictly increasing from 1 within a display session, and restarting
with a new session. The iOS app numbers every scroll it sends. caboose-display accepts
the number and does not act on it. `pointer-scroll-seq` in `guest/display/vectors/` pins
the message.

### Touch targets

Desktop controls are drawn for a mouse; a finger lands a couple of millimetres from where
it aimed, often on a neighbour. The computer reads the focused window's controls from its
accessibility tree and sends them, so the phone can aim a finger's press at the control it
most likely meant, at once and without a round trip.

While a client whose hello says `targets: true` is connected, caboose-display runs
`/opt/caboose/caboose-targets.py serve` ([guest/desktop-mcp](../guest/desktop-mcp)) with
the seat's launch environment; nothing runs without such a client. It reads the focused
window and its open menus through the seat's AT-SPI bus, the way `a11y.py` does: buttons,
toggles, links, menu items, tabs, text fields, list, tree and table items, and adjustable
controls, showing and on the window. It reads again after accessibility events (a window
activated or created, something shown, children changed), 120 ms and 450 ms after the
client's input to the window, and every 2 s; readings are at least 150 ms apart, and twice
as far apart as the last one took. GTK and Chromium windows read in about 50–70 ms.

**`targets`** (`0x28`): window `id`'s controls, replacing its previous list; an empty list
clears it. Each is `[x, y, w, h, kind]` in window-local display pixels. `kind` is 1 button,
2 toggle (check box, radio, switch), 3 link, 4 menu item, 5 tab, 6 text field, 7 item
(list, tree or table cell), 8 adjustable (slider, spin button, scroll bar), 9 window control
or 0 other, with `0x80` set for a disabled control. A window control is one the application
draws in its own page, which toolkit settings cannot remove (an Electron app's HTML title
bar): a row of controls named Minimize, Maximize, Restore or Close, one of them Close,
against the window's top-left or top-right corner within 64 logical pixels of its top. The
client covers each row with the colour read beside it from the window's picture and sends
no click there (Caboose's own controls are on every window); it never aims a touch at one.
Electron renders its pages' trees only with `--force-renderer-accessibility`, which the
guest's launcher adds when an entry's program sits beside Chromium's resource packs. A control belongs to the topmost window of the focused
window's family (its popups, newest first, then itself) that holds its centre. `serial`
increases with every list in a session. A list is sent only when it changed; it describes
the window as of a reading, so a client treats it as a hint that may lag the picture by a
reading.

The phone (`CabooseKit/Input/TouchTargeting.swift`) scores each control within three
spreads of a finger by how likely a finger aiming somewhere on it lands there: uniform aim
over the control, Gaussian landing error of 1.2 mm, a difference of normal CDFs per axis
(Bayesian touch). Touching nothing in particular is a hypothesis too, spread over a patch
twenty spreads wide. A tap on a pointer window presses the likeliest control: where the
finger is when it is on it, else the nearest point well inside it; a disabled control keeps
its touches without taking them. A native touch window's lone finger is aimed at its
touch-down, and the rest of its contact keeps the same offset. A list can therefore move a
press by at most a few spreads, no further than an unaided finger misses by. A tap on a
pointer window whose tree lists nothing is aimed among the shapes that stand out from the
background of its picture around the finger (`PictureTargets.swift`), read back from the
phone's copy of the picture.

**`text_focus`** (`0x29`): whether window `id`'s accessible focus is where typed text goes,
sent by the same provider when the focused window's focus moves into or out of such a place.
A focused object takes typing when it is editable and a text or has lines (a field, a text
view, a spreadsheet cell's editor); an editable table does not, and a window's own frame
taking focus says nothing. Where it reports, it decides over the window's input method
state, which an application can keep on where nothing is being edited: LibreOffice Calc
keeps GTK's input method on for its whole grid, and only its accessibility focus moves into
a cell's editor and back out. The phone uses it for its keyboard and for Laptop's input.

`targets`, `targets-empty`, `text-focus` and `client-hello-targets` in
`guest/display/vectors/` pin the messages. [guest/touch-targets](../guest/touch-targets) is the target-acquisition benchmark.

### Audio

The computer's sound is one Opus stream: each `audio` message is one 20 ms packet (960
samples per channel) at 48 kHz, stereo, with `pts_us` the server `CLOCK_MONOTONIC` of its
first sample. It goes only to a client whose hello lists `"opus"` in `audio_decoders`.
Digital silence is not sent after a second of it: a gap in `pts_us` is silence, and packets
resume without a reset. The server lists `audio` in `features` when it has sound to send.
The iOS player anchors server time to the monotonic host clock when starting playback;
it does not use the asynchronously updated renderer timebase to detect packet backlog.
Audio-session interruptions clear that anchor before the next playback begins. Window
pictures are shown as they arrive, independently of the audio timeline. PCM playback uses decoded sample durations to join adjacent
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

### Game handoff

A client whose hello says `wasm: true` runs games itself. A game is an ordinary toplevel on
the computer, made by `caboose-game-run`; `game.create` tells the client that window's game
runs on the client, from files under `root` (relative to `/home/caboose`) starting at
`entry` (relative to `root`), and which directories it persists (`saves`: `mount` in the
game's Emscripten file system, `path` relative to `/home/caboose`). The server sends it after
the window's `window.create`, in the hello burst too, and `game.destroy` before the window
is withdrawn or when the game ends. Game ids are their own namespace, unique for the server
process's lifetime. While a client runs a window's game, the window's picture is not
presented; `configure` and `close` work as for any window, and once the game ends a
remaining window is presented again. The launcher, its socket and the client's side are specified in
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

## Agent application profile environment

When the compositor starts with `CABOOSE_SEAT=agent`, its launch file additionally
publishes the inherited HOME, XDG_CONFIG_HOME, XDG_DATA_HOME, XDG_CACHE_HOME,
XDG_STATE_HOME, CABOOSE_SEAT, MOZ_NO_REMOTE, DBUS_SESSION_BUS_ADDRESS, VSCODE_PORTABLE,
CHROME_CONFIG_HOME, CHROME_USER_DATA_DIR and PATH. VSCODE_IPC_HOOK_CLI is empty to avoid
reusing an inherited editor instance. The guest agent-profile launcher supplies these
values; the owner compositor's environment contract is unchanged. This changes no display
wire messages. See [persistent agent profiles](../guest/desktop-mcp/README.md#persistent-agent-gui-profiles).
