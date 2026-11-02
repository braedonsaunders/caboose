# Caboose Display

Caboose Display is the computer's display server: a headless Wayland compositor, with
Xwayland for X11 applications. Every window is rendered on the phone's GPU and shown as
its own native iOS surface. The code is in [guest/display](../guest/display); its README
covers building, running and testing it. This document is the design and the wire
contract, the Caboose Display Protocol.

## Design

```
 apps (Wayland, and X11 through Xwayland)
   │ wl_shm and linear dma-buf buffers, surface damage, frame callbacks
   ▼
 caboose-display (headless Wayland compositor, Rust + Smithay, inside the computer)
   ├ one window record per toplevel, dialog, popup and X11 window
   ├ each window rendered on the phone GPU into phone-resident images
   │   (docs/gpu-buffers.md), or presented from a client buffer that already
   │   lives on the phone
   ├ video decoded through the VA-API driver on the phone (docs/gpu-media.md)
   ├ pacing: frame callbacks released on the client's vsync
   ├ input: pointer, touch, pencil, keyboard by keysym, text-input-v3
   └ sound: a private PulseAudio, sent as Opus
   │ Caboose Display Protocol (below), relayed byte for byte by caboose-host
   ▼
 CabooseKit (iOS): one native surface per window, rendered by the live GPU
 executor (docs/gpu-live.md)
```

- **The compositor composites nothing across windows.** Each window's surface tree is
  rendered alone, cropped to its window geometry. The phone is the compositor, which
  is how each window stays a native surface with its own title, icon, size hints and
  parent.
- **Pictures travel only as GPU images.** The compositor renders each window into
  phone-resident buffers through the gfxstream Vulkan driver and presents them
  through the GPU broker. No window picture is encoded, tiled or copied over the
  display connection.
- **Nothing runs while nothing changes.** A window is rendered only after it commits,
  and only its damage is redrawn.
- **The client paces the applications.** Frame callbacks are released on the client's
  display refresh while the window has a free image, so applications draw at the rate
  the phone shows.
- **Video stays compressed until the phone.** An application that decodes through the
  VA-API driver sends its bitstream to the phone, which decodes it into the window's
  GPU images ([gpu-media.md](gpu-media.md)). Video an application decodes itself is
  part of its window picture, rendered like any other content.

## Two instances

The computer runs two instances of caboose-display, one for the owner and one for
agents.

| | Owner's display | Agent seat |
| --- | --- | --- |
| microVM unit | `caboose-display.service` | `caboose-display-agent.service` |
| Container | `caboose-session start` | `caboose-session start-agent` |
| WebSocket port | `14600` | `14601` |
| Host relay | `/v1/display` | `/v1/display?seat=agent` |
| Wayland socket | `wayland-caboose-0` | `wayland-caboose-agent` |
| Xwayland | `:110` | `:101` |
| Sound | its own PulseAudio, Opus to the client | none (`--no-audio`) |
| Game socket | `$XDG_RUNTIME_DIR/caboose-game.sock` | none (`--no-games`) |
| Phone devices ([devices.md](devices.md)) | the phone's hardware, while connected | none (`--no-devices`) |
| Started | by the host at each wake | on demand, when an agent task needs it |

- **Token.** At each wake the host writes a fresh token to `/run/caboose/display-token`
  (mode 0600, owned by `caboose`). Both instances check it on every `hello`.
- **Relay.** The host relays bytes between the client and the instance and never
  decodes them.
- **Launch environment.** Once Wayland and Xwayland are ready, each instance writes
  the environment its applications need (`WAYLAND_DISPLAY`, `DISPLAY`, `XAUTHORITY`,
  toolkit backends, `CABOOSE_DISPLAY_CONTROL`, `PULSE_SERVER` when it plays sound,
  `CABOOSE_GAME_SOCKET` when it hands games off, and the GPU broker sockets on the
  owner's seat) to its env file in sh syntax.
- **Readiness.** `caboose-display-ready [TIMEOUT] [PORT] [ENV_FILE]` checks the written
  launch environment, its control socket and the listening TCP port.
- **Control socket.** The computer's own tools see and act on a seat through its
  control socket: the window list, the seat's pointer and keyboard, and pictures of a
  window or the whole seat for checks. The code is `compositor/src/control.rs`.

## Caboose Display Protocol (v0)

The server is `caboose-display` in the guest, on WebSocket `0.0.0.0:14600` for the
owner's display and `0.0.0.0:14601` for the agent seat. The host relays it byte for
byte. Each instance serves one client at a time: a new authenticated client replaces
the previous one, which gets `bye { reason: "replaced" }` and is closed. A client that
sends nothing for 30 s is taken for suspended or gone and is closed. The Rust codec is
`guest/display/protocol`, and `guest/display/vectors/` pins every message byte for
byte.

### Framing and encoding

- The client parses a **byte stream**. WebSocket message boundaries carry no meaning.
- Each message is `type: u8`, `length: u32` little-endian, then `payload[length]`.
  The payload is exactly one CBOR map with text keys. Binary content (PNG icons and
  cursors, Opus packets) is a CBOR byte string field.
- The largest payload is 16 MiB minus the 5-byte header. A larger announced length is
  a protocol error and closes the connection.
- Unknown types are skipped by length. Unknown keys are ignored. A known type whose
  payload does not decode is dropped and the stream continues.
- **Encoders are canonical**, so vectors compare byte for byte: definite lengths,
  integers in the shortest form, every float as float64, map keys sorted bytewise on
  their encoded form, and optional fields absent rather than null. **Decoders are
  liberal**: any key order, any integer or float width, and an integer where a float
  is expected.

### Coordinates and ids

- Everything is in **display pixels**, the `width`/`height` of a display in the
  client's `hello`. Geometry and rects are `[x, y, w, h]` integers; sizes are
  `[w, h]`; input positions are floats.
- A toplevel's `geometry` is relative to its display's origin. A popup's or dialog's
  is relative to its parent's geometry origin and may be negative.
- A configure size is a request. The client keeps the server-reported size for the
  picture's layout and input coordinates until the app reports a new size.
- Window ids are unique for the server's lifetime. A new server process starts its
  ids again, so a client keeps a window across a reconnect only when the hello's
  `epoch` (random for each server process) is the one it had.

### Handshake

The client speaks first, as soon as the socket opens, with `hello` carrying the
`display.token` from `/v1/session`. The server re-reads the per-wake token file on
every hello. On a mismatch it sends `bye { reason: "auth" }` and closes; on an
unsupported version, `bye { reason: "version" }`. Otherwise it answers with the
display ids it accepted, its `features` and its `epoch`, then sends `window.create`
for every live window.

The server also sends the optional `gpu_live_epoch`, a 16-byte CBOR byte string with
at least one nonzero byte, which names the private live GPU surface namespace.
Absent or malformed values leave live GPU display identity unavailable without
rejecting the ordinary display.

`features` names only what the server implements. caboose-display lists `vsync`,
`touch`, `pencil`, `text-input-v3`, `cursor-named`, `clipboard`, `clipboard-types`,
`drop` and `drag`; `xwayland` when Xwayland runs; `audio` when it plays sound;
`wasm` when it hands games off and the client's hello says `wasm: true`; `webview`
on the owner display when the client supports agent-app handoff; `devices` when the
owner's display accepts the phone's hardware and the client's hello says
`devices: true`; and `targets` when the touch target provider is installed and the
client's hello says `targets: true`.

### Pacing

The client sends `vsync` once per refresh of each display that shows a window.
Frame callbacks are released on that display's vsync while the window has a free
GPU image. A seat nobody watches paces applications at one frame a second.

### Messages

Server → client (`0x01`–`0x7F`):

| Type | Name | Fields (`?` optional) |
| --- | --- | --- |
| `0x01` | `hello` | `version: 0`, `displays: [uint]`, `features: [text]`, `epoch?: text`, `gpu_live_epoch?: bytes` |
| `0x02` | `window.create` | `id`, `parent?: uint`, `kind: "toplevel"\|"popup"\|"dialog"`, `title`, `app_id`, `icon?: bytes` (PNG), `geometry: rect`, `min?: size`, `max?: size`, `fullscreen: bool`, `display?: uint`, `xwayland?: bool`, `alpha?: bool`, `desktop_id?: text`, `pid?: uint` |
| `0x03` | `window.update` | `id` plus any `window.create` field that changed |
| `0x04` | `window.destroy` | `id` |
| `0x17` | `game.create` | `id`, `window`, `root: text`, `entry: text`, `saves?: [{ mount, path }]` ([game-handoff.md](game-handoff.md)) |
| `0x18` | `game.destroy` | `id` |
| `0x1C` | `webview.create` | `id`, `window`, `app`, `bridge`, `grant`, `root`, `entry` |
| `0x1D` | `webview.destroy` | `id` |
| `0x20` | `cursor` | `id?`, `image: bytes` (PNG), `hotspot: [x, y]` |
| `0x21` | `cursor.named` | `name` |
| `0x22` | `text_input` | `id`, `enabled: bool`, `purpose?: text`, `surrounding?: { text, cursor, anchor }` |
| `0x28` | `targets` | `id`, `serial: uint`, `targets: [[x, y, w, h, kind]]` |
| `0x29` | `text_focus` | `id`, `editing: bool` |
| `0x30` | `clipboard` | `mime`, `data: bytes`, `alternatives?: [{ mime, data }]` |
| `0x31` | `notification` | `id`, `app`, `summary`, `body` |
| `0x32` | `drop.status` | `accepted?: bool` |
| `0x33` | `drop.result` | `ok: bool`, `reason?: "rejected"\|"cancelled"\|"timeout"\|"invalid"` |
| `0x34` | `drag.start` | `mimes: [mime]` |
| `0x35` | `drag.end` | `taken: bool` |
| `0x36` | `drag.data` | as `clipboard` |
| `0x40` | `audio` | `codec: "opus"`, `pts_us`, `channels?: uint` (absent = 2), `data: bytes` |
| `0x60` | `device.status` | `devices: [{ id, nodes, error? }]` ([devices.md](devices.md)) |
| `0x61` | `device.open` | `device`, `rate_hz?: float` |
| `0x62` | `device.close` | `device` |
| `0x63` | `device.rumble` | `device`, `strong: float`, `weak: float`, `ms: uint` |
| `0x64` | `device.keyframe` | `device` |
| `0x7E` | `pong` | `t_us` (echoed from `ping`) |
| `0x7F` | `bye` | `reason: "auth"\|"version"\|"shutdown"\|"protocol"\|"replaced"` |

Client → server (`0x81`–`0xFF`):

| Type | Name | Fields (`?` optional) |
| --- | --- | --- |
| `0x81` | `hello` | `version: 0`, `token`, `displays: [display]`, `audio_decoders?: ["opus"]`, `wasm?: bool`, `webview?: bool`, `devices?: bool`, `targets?: bool`, `clipboard_types?: [mime]` (booleans present only when true) |
| `0x82` | `vsync` | `display`, `t_us` |
| `0x84` | `configure` | `id`, `geometry?`, `display?`, `fullscreen?`, `maximized?`, `activated?` |
| `0x85` | `close` | `id` |
| `0x87` | `displays` | `displays: [display]`; replaces the set on a live session |
| `0x90` | `touch` | `id`, `points: [{ slot, phase, x, y, force?, radius? }]`; one message is one `wl_touch.frame` |
| `0x91` | `pencil` | `id`, `phase`, `x`, `y`, `pressure` (0…1), `tilt: [x_deg, y_deg]`, `azimuth_deg` |
| `0x92` | `pointer` | `id`, `x`, `y`, `buttons: uint` (1 left, 2 middle, 4 right, 8 back, 16 forward), `scroll?: { dx, dy, precise, seq?, lift?: [vx, vy], hold? }`, `relative?: [dx, dy]` |
| `0x93` | `key` | `keysym: uint`, `pressed: bool`, `mods: ["shift"\|"control"\|"mod1"\|"mod4"]` |
| `0x94` | `text` | `commit?`, `preedit?`, `cursor?: [begin, end]`, `delete_before?`, `delete_after?` |
| `0x97` | `game.decline` | `id`, `reason: text` |
| `0x98` | `webview.decline` | `id`, `reason: text` |
| `0xA0` | `clipboard` | as server `clipboard` |
| `0xA1` | `drop.enter` | `id`, `x`, `y`, `mimes: [mime]` |
| `0xA2` | `drop.motion` | `id`, `x`, `y` |
| `0xA3` | `drop.leave` | (empty map) |
| `0xA4` | `drop.perform` | as `clipboard` |
| `0xA5` | `drag.take` | (empty map) |
| `0xB0` | `devices` | `devices: [device]` ([devices.md](devices.md)) |
| `0xB1` | `device.camera` | `device`, `seq`, `keyframe: bool`, `t_us`, `data: bytes` |
| `0xB2` | `device.depth` | `device`, `t_us`, `size: [w, h]`, `data: bytes` |
| `0xB3` | `device.audio` | `device`, `t_us`, `data: bytes` (20 ms Opus, 48 kHz mono) |
| `0xB4` | `device.motion` | `device`, `samples: [{ t_us, accel?, gyro?, magnet?, rotation?, pressure? }]` |
| `0xB5` | `device.gamepad` | `device`, `buttons: uint`, `axes: [float × 6]` |
| `0xB6` | `device.button` | `device`, `key`, `pressed: bool` |
| `0xB7` | `device.battery` | `device`, `level`, `charging`, `full`, `low_power`, `thermal` |
| `0xB8` | `device.error` | `device`, `reason: text` |
| `0xFE` | `ping` | `t_us`, answered by `pong` |

A `display` is `{ id: uint, width: int, height: int, scale: float, refresh_hz: float, hdr: bool }`.

caboose-display sends named cursors (`cursor.named`) and no `cursor` images;
`alpha: true` for windows of kind `popup` and `alpha: false` for every other; and
`icon` only for a toplevel that gives one as pixels. It delivers `pencil` as
tablet pen events. The computer's notifications reach the app through the host.

### Windows and launches

`desktop_id` names the desktop entry whose launch started a toplevel's process, as
`<id>.desktop`. A launch marks the process it starts through its environment:
`GIO_LAUNCHED_DESKTOP_FILE`, `GIO_LAUNCHED_DESKTOP_FILE_PID`, and Caboose's
`CABOOSE_DESKTOP_ID`. caboose-display reads them from the window's process, or from
its nearest ancestor that has them. A window belongs to the launch only if no process
between it and the launched process has a window of its own. A client matches
launches and taskbar entries to windows by `desktop_id` first, then by class
(`app_id`, `StartupWMClass`).

`pid` is the process that owns a toplevel: the Wayland client's, or for an X11 window
the X server's record of the client that created it, with `_NET_WM_PID` only when the
server has none.

### Scrolling input

A `pointer` message's `scroll` is in the window's pixels when `precise` (a finger)
and in wheel clicks otherwise. A finger's last sample carries `lift`, its velocity as it
lifted in window pixels per second, from which the computer scrolls on kinetically; a
finger touching down sends `hold: true` with `dx` and `dy` 0, which stops that. How the
computer delivers it is in [input.md](input.md#scrolling). `pointer-scroll-lift` and
`pointer-scroll-hold` in `guest/display/vectors/` pin the two.

### Clipboard

One `clipboard` message is one copy: its first representation in `mime` and `data`,
and the same content in other types in `alternatives`, absent when there are none.
Either side sends one whenever its own clipboard changes; the server also sends the
computer's current copy right after `hello`. The types are UTF-8 text (at most
1 MiB), PNG and JPEG images (checked against their signatures), and `text/uri-list`
file lists. A copy carries each type at most once and at most 12 MiB in total. To the
client, the server sends text, and the other types only when the client's `hello`
lists them in `clipboard_types`. From the client, `text/uri-list` may only name
files the client has uploaded to the computer's transfer area.

### Drag and drop

The clipboard's types, limits and checks apply to everything dragged either way.
While the client drags something over a window it sends `drop.enter`, then
`drop.motion` as it moves, and `drop.perform` with the content when the user lets
go. `drop.status` reports whether the application under the finger accepts it, and
`drop.result` ends the drop. When a Wayland application starts dragging something
the client could take, the server sends `drag.start`; the client answers with
`drag.take`, and the server sends the content as `drag.data` and then `drag.end`.

### Sound

Sound is one `audio` message per 20 ms Opus packet at 48 kHz, stamped with the
server's `CLOCK_MONOTONIC`. A client whose hello lists no `audio_decoders` gets no
sound.

### Game handoff

A window whose game the client runs gets `game.create` after its `window.create`;
while the client runs it, the window presents no GPU picture. `game.decline` says
the client cannot run it, and the window then renders on the GPU like any other.
See [game-handoff.md](game-handoff.md).
