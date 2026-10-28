# Caboose Display

Caboose's own display server and stream: every Linux window rendered on the GPU, encoded
straight from GPU memory, and shown on the phone or TV as its own native surface. It
replaces Xvfb + Xpra wherever a host has a GPU. Xpra stays as the fallback for hosts
without one, behind the same window model in the app.

## Why

Measured on an RTX 4080 under WSL (2026-10-28): a 4K Chromium video reached the phone at
~16 fps. NVENC HEVC encoded every frame in a few milliseconds, and Xpra sent every frame
Chromium painted. The limit was Xvfb. Chromium rendered on the GPU, read each 33 MB frame
back to the CPU and wrote it into Xvfb's memory, and then Xpra read it out again. Parsec,
Sunshine and Steam Link stream 4K60 from weaker GPUs because their frames never leave GPU
memory between render and encode. Caboose Display does the same per window.

## What it is

```
 apps (Wayland, and X11 through Xwayland)
   │ linux-dmabuf buffers, wl_surface damage, frame callbacks
   ▼
 caboose-display   (headless Wayland compositor, Rust + Smithay, inside the computer)
   ├ one Stream per toplevel / popup: its committed dmabuf + damage
   ├ Encoder per stream, zero copy from the dmabuf:
   │     NVENC (CUDA external memory) · VA-API (dmabuf import) · Vulkan Video ·
   │     software (x264/x265, for hosts without a GPU; then the buffers are wl_shm)
   ├ text mode: static content re-sent as lossless tiles once motion stops
   ├ pacing: frame callbacks released on the client's vsync ticks
   └ input: wl_touch, tablet-v2 (Pencil), text-input-v3 (IME), pointer, keyboard
   │ Caboose Display Protocol (below) over the existing host relay
   ▼
 CabooseKit (iOS) · VideoToolbox HEVC/AV1 → CAMetalLayer (EDR/HDR), per window
```

The compositor composites nothing. It is a window and buffer broker. The phone and TV are
the compositors, which is how each window stays a native surface.

## Host requirements, and what each gets

| Host | Rendering | Buffers | Encode | Expected |
| --- | --- | --- | --- | --- |
| Linux, NVIDIA (`CABOOSE_GPU=nvidia`) | EGL/Vulkan on the GPU | dmabuf | NVENC (zero copy) | 4K60+ |
| Linux, Intel/AMD (`dri`) | Mesa | dmabuf | VA-API (zero copy) | 4K60 on recent parts |
| Bare-metal microVM with VFIO GPU | as above, inside the VM | dmabuf | as above | 4K60, VM isolation |
| WSL2 (`wsl`) | Mesa D3D12 on `/dev/dxg` | wl_shm (no DRM/GBM in WSL) | NVENC/D3D12-VA after a CPU copy | same ceiling as today |
| No GPU (`none`, microVM default) | pixman / llvmpipe | wl_shm | x264/x265 | CPU-bound, like Xpra |

Zero copy on WSL waits on the cross-process buffer sharing that WSL does not have today
(active work: a Cookiekira/niri issue to validate a GLES → D3D12-VA proof of concept,
microsoft/wslg#469). A box that needs zero-copy 4K runs Linux natively.

## Video, for every app

Video is not a special case for particular sites or apps. It is handled at the operating
system's own seams, so any program that plays video benefits. There are three layers;
each one falls back to the one below it.

1. **Codec passthrough (zero server cost).** The computer ships a Caboose VA-API driver,
   the standard Linux interface for hardware video decoding. Chromium, Firefox, mpv, VLC,
   GStreamer and FFmpeg all decode through it. The driver does not decode. It
   reconstitutes the compressed bitstream (H.264, HEVC, VP9, AV1) from the parameter and
   slice buffers and forwards it, as is, to the client as a `video` stream bound to the
   window and rectangle it plays in. The client decodes it in hardware and layers it into
   the window at the app's own timestamps, with audio kept in sync. This is the same idea
   as RDP and Citrix multimedia redirection, applied at the decode interface every Linux
   player shares. It gives the original quality, near-zero server CPU and no GPU. Content
   the client cannot decode, or that the app reads back (canvas, effects), falls back to
   layer 2. The driver, its socket to the compositor and the on-screen marker that binds a
   stream to its window are specified in [codec-passthrough.md](codec-passthrough.md).
2. **Video surfaces (first class in the compositor).** On Wayland, players present video
   on its own subsurface in a YUV format (NV12/P010): the overlay path used by Chromium,
   Firefox, mpv, GStreamer and VLC. The compositor treats that subsurface as its own
   stream, with a video codec at the video's own size and frame rate, hardware encoded
   where available. The window around it keeps sharp, lossless UI updates, and the client
   layers the two. No heuristics are involved.
3. **Detected motion (X11 and everything else).** A region that updates at video rates is
   encoded as video, at the size it is actually shown on the client, as Xpra does today.

On the wire these are the `video.*` messages (see "Video streams" below). "Play on
iPhone / Apple TV" (media handoff) stays as a user action layered on top, not as the
mechanism.

## Caboose Display Protocol (v0)

The server is `caboose-display` in the guest, on WebSocket `0.0.0.0:14600` (any path; it
accepts the `binary` subprotocol). The host relays it exactly as it relays Xpra; `14601` is
reserved for an agent seat. One client is served at a time: a new authenticated client
replaces the previous one, whose socket is closed. The Rust codec is
`guest/display/protocol`, and `guest/display/vectors/` pins every message byte for byte.

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
  does not decode is dropped and the stream continues.
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
version, `bye { reason: "version" }`. Otherwise it answers `hello` with the display ids it
accepted, `encoders` = its encoders ∩ the client's decoders in the server's preference
order, and its `features`; then sends `window.create` for every live window, followed by a
keyframe of each.

`features` is any of `vsync`, `ack`, `touch`, `pencil`, `text-input-v3`, `clipboard`,
`cursor-named`, `tiles`, `audio`, `xwayland`, `video`. A feature is listed only when the
server implements it.

### Pacing and flow control

- `pts_us` is the server's `CLOCK_MONOTONIC` at the surface commit, in microseconds.
- The client sends `vsync` once per refresh of each display that shows a window. Frame
  callbacks of a window are released on a vsync of its display, and only while fewer than
  2 of its frames are unacknowledged (`ack` matches by `pts_us`). A window whose display
  sends no vsync is throttled like a minimised one: it gets frame callbacks once a second.
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
| `0x30` | `clipboard` | `mime`, `data: bytes` |
| `0x31` | `notification` | `id`, `app`, `summary`, `body` |
| `0x40` | `audio` | `codec: "opus"`, `pts_us`, `data: bytes` |
| `0x7E` | `pong` | `t_us` (echoed from `ping`) |
| `0x7F` | `bye` | `reason: "auth"\|"version"\|"shutdown"\|"protocol"` |

Client → server (`0x81`–`0xFF`):

| Type | Name | Fields (`?` optional) |
| --- | --- | --- |
| `0x81` | `hello` | `version: 0`, `token`, `decoders: [codec]`, `displays: [display]`, `video_decoders?: [codec]` |
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
| `0xA0` | `clipboard` | `mime`, `data: bytes` |
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
  the commit is typed as key presses and pre-edit text is not shown.
- `text_input` fires when the focused window's text-input-v3 is enabled or disabled. With
  the `text-input-v3` feature the client shows and hides the keyboard from it, and treats a
  `text` cursor shape only as a fallback.
- Clients keep pointer gestures (tap, long-press right-click, swipe to scroll) for
  `xwayland: true` windows and send real touch to native Wayland ones, because most X11
  apps turn a touch drag into a selection.

### Video streams

A video stream is layered into a window (`window`) by the client: it decodes it with its
own decoder and draws it at `rect` (window-local display pixels, the whole picture,
scaled to fit), showing only `clip` when present (a scrolled or cropped player, or an
H.264 1088-line picture whose 1080 lines are visible). Every video stream is drawn above
the window's own picture, ordered by `z` (higher on top); window pictures carry no alpha,
so the server sends the visible region as `clip` instead of relying on a hole in the
window. Video ids are their own namespace, unique for the server's lifetime.

- The client lists in `hello.video_decoders` what it can play as a video stream. The server
  creates streams only in those codecs and sends `video` in `features`; anything else
  stays in the window's picture.
- `video.frame` carries one access unit in **decode order**: `seq` starts at 0 for each
  stream and increases by one. `data` is Annex-B with parameter sets on keyframes for
  H.264 and HEVC, a temporal unit of OBUs with the sequence header on keyframes for AV1,
  and a frame or superframe for VP9. `extradata` is only for a codec whose parameters
  cannot travel in band.
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
  last one).

## Status

`guest/display` implements milestone 1 and the CPU path of the design; its README has the
measurements and the scripted checks.

- **Done:** the protocol and its vectors; the headless compositor with Xwayland, wl_shm and
  linear dmabufs; one stream per toplevel, dialog, popup and X11 window; single-buffer
  windows read in place without composition, the rest damage-tracked; changed-block
  detection and libx264 macroblock hints, so the server's CPU follows what changes on
  screen; libx264, libx265 and NVENC (from system memory, the WSL2
  path) behind one `Encoder` trait; pacing on vsync with acknowledgement-based flow
  control; pointer, multitouch, keys and text-input-v3 input; the text clipboard between
  the phone, Wayland and X11 applications; reconnect and replacement;
  video layer 1, codec passthrough ([codec-passthrough.md](codec-passthrough.md)): the
  driver's socket, streams bound to windows by their marker, `video.*` out with
  `video.present` at the moment the application shows each frame; the container and
  microVM integration, with the driver (installed, not the default).
- **Next:** a GPU renderer that composes into dmabufs, and the zero-copy encoders on it
  (dmabuf → NVENC through CUDA external memory, dmabuf → VA-API), which also enables the
  exact passthrough binding; video layers 2 (YUV subsurfaces) and 3 (detected motion);
  lossless tiles; cursor images, Pencil and audio.
- **Passthrough reach:** Chromium and Firefox decode through VA only with a working GPU
  process, which needs a DRM render node; on WSL2 and hosts without a GPU their video stays
  in the window picture (layers 2 and 3 are for that). Players that decode on the CPU
  through VA (mpv, GStreamer, FFmpeg) pass through anywhere the driver runs. VA carries no
  HDR metadata, and AV1 is presented one picture late (docs in guest/vaapi).
- **Not measurable here yet:** milestone 2's success criterion needs a Linux host with an
  encode-capable GPU. The development machine's GPU (Radeon HD 7450) has VA-API decode
  only, and the RTX 4080 machine runs WSL2, which has no DRM render node.

## Milestones

1. **Compositor skeleton.** Headless Smithay compositor with Xwayland, wl_shm + dmabuf, and one stream per toplevel with a software encoder. The iOS client renders windows over the relay. Runs on any Linux.
2. **Zero copy on a Linux GPU.** dmabuf → NVENC (CUDA) and dmabuf → VA-API, plus Vulkan Video where present. Success: Chromium 4K60 video at ≥55 fps on the phone/TV, under 30 ms from frame to decode on a LAN.
3. **Input that is native.** wl_touch multitouch, Pencil via tablet-v2, text-input-v3 IME from the iOS keyboard.
4. **Pacing and polish.** Frame callbacks paced on vsync (ProMotion 120 Hz), HDR/EDR, lossless text tiles, Opus audio in sync with video.
5. **Video for every app.** Video surfaces (layer 2), then the VA-API codec-passthrough
   driver (layer 1) with in-window layering and A/V sync on the client.
6. **Default where it can be.** The host picks Caboose Display when the computer has a GPU and the image has it, and falls back to Xpra otherwise. The app supports both.
