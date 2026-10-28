# Caboose Display

Caboose's own display server: a headless Wayland compositor that streams every window
as its own encoded video, for the phone and TV to show as native surfaces. The design
and the wire contract are [docs/display.md](../../docs/display.md).

This directory is a Cargo workspace:

| Path | What |
| --- | --- |
| `protocol/` | `caboose-display-protocol`: Caboose Display Protocol v0. Framing, the canonical CBOR codec, every message, and the golden vector set. No dependencies |
| `compositor/` | `caboose-display`: the compositor and stream server |
| `probe/` | `caboose-display-probe`: a headless client that decodes every window and reports fps, latency and server CPU |
| `vectors/` | Golden vectors every client replays (see [vectors/README.md](vectors/README.md)) |
| `scripts/check.py` | Scripted checks against real applications |
| `systemd/`, `install.sh`, `caboose-display-ready` | Running it in a guest |
| `Dockerfile`, `scripts/dev.sh` | The build and test environment |

## What the compositor does

- **Wayland and X11 applications.** A headless [Smithay](https://github.com/Smithay/smithay)
  compositor with xdg-shell (toplevels and popups), xdg-decoration (applications are told
  the phone draws the frame, so they draw no title bar of their own), viewporter,
  fractional scale, cursor-shape, linux-dmabuf (linear buffers) and wl_shm. Xwayland runs
  with a window manager, so X11 applications are windows too, with a per-boot
  MIT-MAGIC-COOKIE in an Xauthority file.
- **One stream per window.** Every toplevel, dialog, popup and X11 window is announced
  with `window.create` and streamed on its own. The compositor composes nothing across
  windows: each window's surface tree (with its subsurfaces) is rendered alone, cropped to
  its window geometry, at the buffer's own density.
- **Cheap when nothing changes, and when little does.** A window that is one surface with
  one wl_shm buffer (most windows: terminals, Chromium, X11 apps) is not composed at all:
  the encoder reads the client's buffer in place, holding it until it is done, and only the
  client's own damage is looked at (a picture that needs encoder padding is copied, damage
  only). Other windows are rendered damage-tracked, straight into the encoder's input image. The encoder keeps the previous picture
  and compares the damaged 16×16 blocks against it, converts only the blocks that really
  changed (applications often damage a whole widget for a blinking caret), and tells
  libx264 which macroblocks changed so it skips the rest. One picture per window is at the
  encoder at a time and the newest content wins; stale pictures are never queued.
- **Paced by the client.** Frame callbacks are released on the client's `vsync` and only
  while fewer than two of the window's frames are unacknowledged, so applications draw at
  the rate the link and the screen can show. A window whose display sends no vsync gets
  frame callbacks once a second.
- **Encoders.** libx264 (default for software: H.264 at constant QP, `ultrafast`,
  zero latency, keyframes only on request), libx265, and NVENC (`h264_nvenc`,
  `hevc_nvenc`, `av1_nvenc`) from system memory, all through libavcodec behind one
  `Encoder` trait. Each is probed at start-up by encoding a test picture; only working
  ones are offered. `--list-encoders` prints them.
- **Input.** Pointer (buttons as a pressed set, precise and wheel scrolling), multitouch
  (`wl_touch`, one frame per message), keys by keysym (mapped to the keymap, with the
  modifiers a level needs), and text: commits and pre-edit text go to the focused surface
  through text-input-v3, whose enable/disable is reported with `text_input` (also to a
  client that connects after a field was focused); deletions are BackSpace/Delete
  presses, one per grapheme cluster. Surfaces without text-input-v3 (X11 apps, many
  terminals) get the commit as key presses.
- **Clipboard** (text). The phone's `clipboard` becomes the selection Wayland and X11
  applications paste; what they copy reaches the phone (and a new client is sent the
  current text on connect). Copying between Wayland and X11 applications on the computer
  works through Xwayland's window manager. When a focused window closes, focus returns to
  the window focused before it.
- **Sound.** The compositor runs its own PulseAudio on a private socket with a null sink
  as the only, so default, output, and gives launched applications `PULSE_SERVER`. While a
  client that plays Opus is connected (`hello.audio_decoders`), `parec` records the sink and
  each 20 ms of 48 kHz stereo goes out as an `audio` message, timestamped on the pictures'
  clock; silence stops being sent after a second, and nothing records with no listener.
  `--no-audio` turns it off.
- **Sessions.** One client at a time; a new authenticated client replaces the previous
  one. Window ids survive reconnects and every window restarts with a keyframe.

- **Video passthrough** ([docs/codec-passthrough.md](../../docs/codec-passthrough.md)). The
  compositor listens on the video socket (`$XDG_RUNTIME_DIR/caboose-video.sock`) for the
  Caboose VA-API driver (guest/vaapi), which hands it each player's bitstream instead of
  decoding it. It accepts streams the client can play (`hello.video_decoders`), marks each
  with a tag, finds the driver's marker in the windows of the player's process family
  (half resolution, refined at full resolution, only while a stream is open), and sends
  `video.create`/`video.update` for where the video is and `video.frame` for every access
  unit, replaying from the last keyframe when a client connects or its decoder fails, and
  `video.present` when the application shows each frame. A client that keeps failing to
  decode a stream gets it decoded on the server. Launched applications get
  `LIBVA_DRIVER_NAME=caboose` when the driver is installed.

Not yet here, and absent from `hello.features` until they are: non-text clipboard types, Pencil
(tablet-v2), cursor images (named cursors are sent), notifications, the microphone, lossless
tiles, video layers 2 and 3, a GPU renderer with the zero-copy encoders (dmabuf → NVENC or
VA-API) and the exact passthrough binding it enables, typing characters that are not on the
keymap into X11 applications, and an agent seat on `14601`.

## Build and test

Everything builds and runs in the dev container, so the host needs only Docker:

```sh
docker build -t caboose-display-dev guest/display
guest/display/scripts/dev.sh cargo build
guest/display/scripts/dev.sh cargo test
guest/display/scripts/dev.sh cargo clippy --all-targets -- -D warnings
guest/display/scripts/dev.sh python3 scripts/check.py
```

For the `passthrough` check's cross-check against the driver's reference detector, mount
the driver's source: `CABOOSE_DISPLAY_DOCKER_ARGS="-v $PWD/guest/vaapi:/vaapi:ro"` and build
`cbva-detect` first (`make -C /vaapi BUILD=/tmp/vaapi`). The real driver against the real
socket: build it the same way and run a VA player with `LIBVA_DRIVERS_PATH=/tmp/vaapi
LIBVA_DRIVER_NAME=caboose` under the compositor (with `CABOOSE_DISPLAY_DRI=1` and
`/dev/udmabuf`; on this project's development machine FFmpeg's H.264 and HEVC streams pass
through, and a readback closes the stream as the contract says).

`dev.sh` runs as the calling user, keeps the cargo registry in `~/.cache/caboose-display`,
and caps the container at 6 CPUs and 6 GiB (`CABOOSE_DISPLAY_CPUS`, `CABOOSE_DISPLAY_MEMORY`).
Dev builds are optimised (`opt-level = 2`) because the checks measure frame rates. The
workspace targets `x86-64-v2` so the pixel conversion vectorises.

Unit tests cover the protocol (canonical encoding, the stream decoder on split and
malformed input, and the committed vectors against the encoder), the pixel conversion
(reference colours, damage-only and threaded conversion, changed-block detection), the
encoders (parameter sets on keyframes), keysym mapping on the real `us` keymap, grapheme
→ byte conversion for deletions, flow control, configuration and the Xauthority format.

`scripts/check.py` starts the compositor with real applications and drives it with the
probe. Every check asserts on what arrived, not on a picture:

| Check | What it proves |
| --- | --- |
| `auth` | a wrong token gets `bye(auth)`; the right one gets windows |
| `wayland-terminal` | text typed from the client reaches weston-terminal exactly (key fallback) |
| `x11-terminal` | the same through Xwayland into xterm |
| `shm-animation` | an animating client is paced on vsync at ≥ 55 fps |
| `hevc` | a client that decodes only HEVC gets x265 |
| `two-windows` | two applications stream as two windows |
| `chromium` | Chromium as a native Wayland client animates at ≥ 55 fps |
| `chromium-text-input` | touch reaches the page; text-input-v3 is enabled and its commit arrives exactly |
| `reconnect` | window ids survive a reconnect and each window restarts with a keyframe |
| `replace` | a second client takes over; the first gets `bye(shutdown)` |
| `popup` | a `<select>` list is its own popup window with the page as parent |
| `text-input-on-connect` | a client that connects after a field was focused is still told text input is enabled |
| `autocorrect` | `text` with `delete_before` (autocorrect, the delete key) edits a Chromium field exactly, one grapheme cluster per deletion |
| `direct-matches-compose` | a window streamed straight from its shm buffer is the picture composition makes, byte for byte |
| `passthrough` | a stand-in VA-API driver (`scripts/fake-video-driver.py`, the real socket protocol, real H.264) streams while Chromium shows its marker: the stream is bound to the right window and rectangle, every frame decodes on the client, presents name frames the client has, and the driver's own detector agrees on the rectangle |
| `clipboard-wayland` | the phone's text pastes into Chromium (Ctrl+V), and Chromium's copy (Ctrl+A, Ctrl+C) reaches the phone |
| `clipboard-x11` | an X11 copy (xclip) reaches the phone on connect, and the phone's copy reaches X11 |
| `clipboard-bridge` | on the computer, a Wayland copy (wl-copy) pastes into X11 and an X11 copy into Wayland |
| `audio` | a tone played into the session's default output reaches the probe as stereo Opus it decodes, at the tone's level, and the silence before it is not sent |
| `idle` | an idle window with a client ticking vsync costs under 2% of a core |

### Measured

On an AMD Ryzen 7 2700X (2018, 8 cores) shared with other work, software rendering and
libx264 on one thread per window, frames decoded and acknowledged by the probe on the
same machine (`scripts/check.py` and the probe's `--server-pid`):

| Workload | Frame rate | Latency, commit → decoded (p50 / p95) | Server CPU |
| --- | --- | --- | --- |
| Chromium, 1280×720 animation (60 Hz) | 60.2 fps | 3.3 / 5.0 ms | 3.6 ms per frame, 22% of a core |
| Chromium, 1920×1080 animation (60 Hz) | 59.8 fps | 6.8 / 7.9 ms | 7.4 ms per frame, 43% of a core |
| weston-simple-shm, 250×250 (60 Hz) | 60.2 fps | 0.7 / 1.2 ms | 0.94 ms per frame, 6% of a core |
| The same with HEVC (x265) | 60.4 fps | 4.9 / 11.7 ms | 10.8 ms per frame |
| An idle terminal, client ticking vsync at 60 Hz | — | — | 0.5% of a core |
| No client connected | — | — | nothing measurable (one housekeeping timer a second) |

Comparing damaged blocks before converting took Chromium's 720p frames from 7.9 ms to
3.6 ms of server CPU: Chromium damages about a quarter of the window per frame while the
pixels that change cover about 1%. Reading single-buffer windows in place instead of
composing them took full-window 1080p video from 13.1 to 12.0 ms of server CPU per frame
(composition was 2.3 ms of it; `--always-compose` turns this off for comparisons).

## Run

```sh
caboose-display [--listen 0.0.0.0:14600] [--token-file /run/caboose/xpra-token] \
  [--env-file /run/caboose/display.env] [-- COMMAND ARGS...]
caboose-display --help
```

It needs `XDG_RUNTIME_DIR`. It creates the Wayland socket `wayland-caboose-0`, starts
Xwayland on `:110`, and once both are ready writes the application environment
(`WAYLAND_DISPLAY`, `DISPLAY`, `XAUTHORITY`, `XDG_RUNTIME_DIR`, toolkit hints for Wayland
first, and the GPU variables it was started with) to `--env-file` in sh syntax, then runs
`COMMAND` with that environment and exits when it does. The token file is re-read on every
hello. SIGTERM stops it cleanly and logs a per-stage CPU summary. `CABOOSE_DISPLAY_LOG`
takes a `tracing` filter (`info`, `caboose_display=debug`, …).

The probe connects like the phone:

```sh
caboose-display-probe --token-file /run/caboose/xpra-token --duration 10 \
  --display 1179x2556@120x3 --save /tmp/out --server-pid "$(pidof caboose-display)"
caboose-display-probe --check --token-file /run/caboose/xpra-token   # readiness
```

`--save` writes each window's stream and last decoded picture (PNG); `--type`, `--click`
and `--touch` send input once a window shows, and `--actions` replays a sequence of keys,
text, taps and clicks (`--window` picks the window); `--json` prints a machine-readable
report.

## In the guest

Both guest images build the binaries in a first Docker stage and carry them without
enabling them; Xpra stays the default display until the host selects Caboose Display:

- **Container** (`guest/container`): `caboose-session start-display` starts the compositor
  as `caboose`; `caboose-session ready-display` waits until it answers a hello.
- **microVM** (`guest/image`): `caboose-display.service` (installed, not enabled);
  `caboose-display-ready [SECONDS]` waits until it answers a hello.

On a Debian 13 system with the binaries built, `install.sh` installs the runtime
libraries, the binaries, the unit and the readiness check.
