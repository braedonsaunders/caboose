# Caboose Display

Caboose's display server: a headless Wayland compositor that streams every window as its
own encoded video, for the phone and TV to show as native surfaces. The computer runs two
instances, one for the owner and one for agents. The design, the deployment and the wire
contract are [docs/display.md](../../docs/display.md).

This directory is a Cargo workspace:

| Path | What |
| --- | --- |
| `protocol/` | `caboose-display-protocol`: Caboose Display Protocol v0. Framing, the canonical CBOR codec, every message, and the golden vector set. No dependencies |
| `compositor/` | `caboose-display`: the compositor and stream server |
| `probe/` | `caboose-display-probe`: a headless client that decodes every window and reports fps, latency and server CPU; also the readiness check |
| `vectors/` | Golden vectors every client replays (see [vectors/README.md](vectors/README.md)) |
| `scripts/check.py` | Scripted checks against real applications |
| `scripts/profile.py` | Server CPU per update for Chromium at phone and TV sizes |
| `scripts/wsl-check.sh` | Chromium video at 1080p and 4K on a WSL2 GPU host, with libx264 and NVENC |
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
  only). Other windows are rendered damage-tracked, straight into the encoder's input
  image. The encoder keeps the previous picture and compares the damaged 16×16 blocks
  against it, converts only the blocks that really changed (applications often damage a
  whole widget for a blinking caret), and tells libx264 which macroblocks changed so it
  skips the rest. One picture per window is at the encoder at a time and the newest
  content wins; stale pictures are never queued.
- **Paced by the client.** Frame callbacks are released on the client's `vsync` and only
  while fewer than two of the window's frames are unacknowledged, so applications draw at
  the rate the link and the screen can show. A window whose display sends no vsync gets
  frame callbacks once a second.
- **Encoders.** libx264 (default for software: H.264 at one QP for every picture,
  `ultrafast`, zero latency, keyframes only on request), libx265, and NVENC (`h264_nvenc`,
  `hevc_nvenc`, `av1_nvenc`) from system memory, all through libavcodec behind one
  `Encoder` trait. Each is probed at start-up by encoding a test picture; only working
  ones are offered, hardware first. `--list-encoders` prints them.
- **Tiles.** A change of at most `--tile-max-px` (64K) pixels in at most 32 runs, which
  is typing, a caret or a small widget, goes as lossless PNG tiles of the changed
  blocks instead of a picture, with no x264 pass. The comparison shadow becomes "what
  the client shows", and tiled areas are marked stale for the encoder. The next picture
  codes them, and a sharpening picture codes them directly at the sharpening QP. A window
  updating more than 7 times in 500 ms (an animation, not typing) gets pictures, which
  video coding keeps far smaller. A damage report with no real change sends nothing.
  Software encoders only; `--tile-max-px 0` turns tiles off.
- **Sharpening.** Pictures are coded at `--crf` (23), which keeps updates small but
  leaves text soft. An area of a window that has not changed for `--refine-after` (300 ms)
  is coded once more at `--refine-qp` (12): it rides along in the next picture the window
  sends anyway (a caret blink, the next keystroke), or, if the window has gone quiet, in
  one extra picture of the same content. libx264 then skips those macroblocks, so they
  stay sharp until they change again. An area that changes again soon after it was
  sharpened (a blinking caret) waits twice as long each time, up to 16×, so blinking
  costs no extra pictures. libx264 runs in CRF mode with `qcomp=1`, so every P picture
  gets the same QP while AQ, which the per-macroblock QP offsets need, stays on. libx264
  only; `--refine-qp 0` turns it off.
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
  one. Window ids survive reconnects and every window restarts with a keyframe. A client
  that sends nothing for `--client-timeout` (30 s) is closed.
- **Video passthrough** ([docs/codec-passthrough.md](../../docs/codec-passthrough.md)). The
  compositor listens on the video socket (`$CABOOSE_VIDEO_SOCKET`, default
  `$XDG_RUNTIME_DIR/caboose-video.sock`) for the Caboose VA-API driver
  ([guest/vaapi](../vaapi/README.md)), which hands it each player's bitstream instead of
  decoding it. It accepts streams the client can play (`hello.video_decoders`), marks each
  with a tag, finds the driver's marker in the windows of the player's process family
  (half resolution, refined at full resolution, only while a stream is open), and sends
  `video.create`/`video.update` for where the video is and `video.frame` for every access
  unit, replaying from the last keyframe when a client connects or its decoder fails, and
  `video.present` when the application shows each frame. A client that keeps failing to
  decode a stream gets it decoded on the server. Launched applications get
  `LIBVA_DRIVER_NAME=caboose` when the driver is installed.
- **Detected motion** (`src/motion.rs`). Each window's changed macroblocks feed a tracker.
  A dense rectangle of at least 192×112 pixels whose blocks change in most pictures at
  15 fps or more, for a second, becomes a `motion` video stream. The window's encode
  worker encodes that crop with its own encoder (no sharpening) and leaves it out of the
  window picture. Once the region has stopped looking like video for a second, a window
  picture repaints it and the stream ends. Only for a client that lists the stream's codec
  in `video_decoders`; `--no-motion` turns it off.

Limitations: the renderer is pixman (CPU), so buffers reach the encoders through system
memory and the compositor offers no YUV formats; tiles come only from the software
encoders; the clipboard carries text only; cursors are sent by name, not as images;
Pencil input is ignored (`pencil` is not in `hello.features`); notifications are not sent
on the display protocol; and characters that are not on the keymap cannot be typed into
X11 applications.

## Build and test

Everything builds and runs in the dev container (Debian 13, with the applications the
checks drive), so the host needs only Docker:

```sh
docker build -t caboose-display-dev guest/display
guest/display/scripts/dev.sh cargo build
guest/display/scripts/dev.sh cargo test
guest/display/scripts/dev.sh cargo clippy --all-targets -- -D warnings
guest/display/scripts/dev.sh python3 scripts/check.py            # every check
guest/display/scripts/dev.sh python3 scripts/check.py chromium   # checks by name
```

`dev.sh` runs as the calling user with this directory at `/src`, keeps the cargo registry
in `~/.cache/caboose-display`, and caps the container at 6 CPUs and 6 GiB
(`CABOOSE_DISPLAY_CPUS`, `CABOOSE_DISPLAY_MEMORY`). `CABOOSE_DISPLAY_DRI=1` passes the
host's render nodes through, and `CABOOSE_DISPLAY_DOCKER_ARGS` adds `docker run`
arguments. Dev builds are optimised (`opt-level = 2`) because the checks measure frame
rates. The workspace targets `x86-64-v2` so the pixel conversion vectorises. Release
builds (`cargo build --release`) are what the guest images carry.

Unit tests cover the protocol (canonical encoding, the stream decoder on split and
malformed input, and the committed vectors against the encoder), the pixel conversion
(reference colours, damage-only and threaded conversion, changed-block detection), the
encoders (parameter sets on keyframes), keysym mapping on the real `us` keymap, grapheme
→ byte conversion for deletions, flow control, the launch environment (including
`--x11-only`), configuration and per-instance state directories, and the Xauthority
format.

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
| `reconnect-idle` | a window streamed in place from its shm buffer that draws nothing between two clients gives the second client the same picture |
| `replace` | a second client takes over; the first gets `bye(replaced)` |
| `storm` | 48 broken connections while a window animates (closed at once, left silent, handshakes cut short, a wrong token, clients killed mid-stream): the next client streams normally, and the server's threads and memory are back where they were |
| `takeover` | six clients take the display from each other in turn: each starts with a keyframe, each one replaced gets `bye(replaced)` |
| `resize-streaming` | Chromium animates while the client resizes its window ten times: every size starts with a keyframe, nothing fails to decode, the last size sticks |
| `app-crash` | two of three applications (one an X11 app) are killed mid-stream: their windows go, the survivor keeps streaming, the next client gets it |
| `stalled-client` | a client stops reading while sound plays: memory does not grow, the server closes it after `--client-timeout`, the next client is served |
| `popup` | a `<select>` list is its own popup window with the page as parent |
| `text-input-on-connect` | a client that connects after a field was focused is still told text input is enabled |
| `autocorrect` | `text` with `delete_before` (autocorrect, the delete key) edits a Chromium field exactly, one grapheme cluster per deletion |
| `direct-matches-compose` | a window streamed straight from its shm buffer is the picture composition makes, byte for byte |
| `passthrough` | a stand-in VA-API driver (`scripts/fake-video-driver.py`, the real socket protocol, real H.264) streams while Chromium shows its marker: the stream is bound to the right window and rectangle, every frame decodes on the client, presents name frames the client has, and the driver's own detector agrees on the rectangle |
| `clipboard-wayland` | the phone's text pastes into Chromium (Ctrl+V), and Chromium's copy (Ctrl+A, Ctrl+C) reaches the phone |
| `clipboard-x11` | an X11 copy (xclip) reaches the phone on connect, and the phone's copy reaches X11 |
| `clipboard-bridge` | on the computer, a Wayland copy (wl-copy) pastes into X11 and an X11 copy into Wayland |
| `audio` | a tone played into the session's default output reaches the probe as stereo Opus it decodes, at the tone's level, and the silence before it is not sent |
| `refine` | a quiet terminal gets its keyframe, one sharpening picture 300 ms later and then nothing; against a near-lossless reference the sharpened picture is at least 3 dB closer; a blinking caret costs at most 4 extra pictures in 6 s, not one per blink |
| `motion` | Chromium plays a 480×270 canvas "video" in a page of text for 8 s: it becomes one `motion` stream at the canvas, every frame decodes with a pts, the window stream sends at most half as many pictures beside it, the stream ends after the video stops, and the final window picture matches the one streamed with `--no-motion` (≥ 40 dB) |
| `tiles` | 31 characters typed into Chromium at 1179×2556 go as tiles: every tile decodes, at most a third of the pictures of a run without tiles, the server spends at most 60% of the CPU, and the final picture (frame plus tiles, as the client paints it) matches the one without tiles (≥ 40 dB); a 250×250 animation at 60 Hz stays video |
| `idle` | an idle window with a client ticking vsync costs under 2% of a core |

For the `passthrough` check's cross-check against the driver's reference detector, mount
the driver's source with `CABOOSE_DISPLAY_DOCKER_ARGS="-v $PWD/guest/vaapi:/vaapi:ro"` and
build `cbva-detect` first (`make -C /vaapi BUILD=/tmp/vaapi`). To run the real driver
against the real socket, build it the same way and run a VA player with
`LIBVA_DRIVERS_PATH=/tmp/vaapi LIBVA_DRIVER_NAME=caboose` under the compositor, with
`CABOOSE_DISPLAY_DRI=1` and `/dev/udmabuf`; a readback closes the stream as the contract
says.

`scripts/profile.py` measures the server CPU per update for Chromium at the display sizes
the app uses. It connects with a phone's display (1179×2556 at 3×) or a TV's
(3840×2160 at 2×) and maximises the window, as the app does. It then types, scrolls an
article, or leaves a caret blinking, and prints the server's CPU per picture and its
split by thread:

    guest/display/scripts/dev.sh python3 scripts/profile.py [phone|tv] [type|scroll|caret] [-- FLAGS]

`scripts/wsl-check.sh` runs on a WSL2 host with an NVIDIA GPU (`/dev/dxg`): in a
disposable container it plays a 60 fps test video full-window in Chromium at 1080p and
4K, streamed with libx264 and with NVENC, and prints the probe's report and the server's
CPU summary. The encoder alone is benchmarked by
`cargo test -p caboose-display bench_text -- --ignored --nocapture`. Recorded results,
with the hardware they were measured on, are in
[docs/display.md, "Measurements"](../../docs/display.md#measurements).

Two scripted checks outside this directory exercise both instances together:
`guest/desktop-mcp/check-a11y.sh` runs the owner's display and the agent seat in Docker
and drives them with the desktop tools, and `apps/host/scripts/e2e.sh` checks a hello on
both seats against a real host.

## Run

```sh
caboose-display [OPTIONS] [-- COMMAND ARGS...]
caboose-display --help
```

It needs `XDG_RUNTIME_DIR`. It creates the Wayland socket (`--socket`), starts Xwayland
(`--x-display`), and once both are ready writes the application environment to
`--env-file` in sh syntax: `WAYLAND_DISPLAY` (unless `--x11-only`), `DISPLAY`,
`XAUTHORITY`, `XDG_RUNTIME_DIR`, toolkit backends (Wayland first, or X11 only with
`--x11-only`), `PULSE_SERVER` when it plays sound, `LIBVA_DRIVER_NAME=caboose`,
`GST_VA_ALL_DRIVERS=1` and `CABOOSE_VIDEO_SOCKET` when the passthrough driver is
installed, and the GPU variables it was started with (`GALLIUM_DRIVER`,
`MESA_D3D12_DEFAULT_ADAPTER_NAME`, `LIBVA_DRIVER_NAME`). It then runs `COMMAND` with that
environment and exits when it does. SIGTERM stops it cleanly and logs a per-stage CPU
summary.

### Configuration

| Option | Default | Effect |
| --- | --- | --- |
| `--listen ADDR` | `0.0.0.0:14600` | WebSocket listen address |
| `--token-file PATH` | `/run/caboose/display-token` | The per-wake token, re-read on every hello |
| `--no-auth` | | Accept any token (development only) |
| `--socket NAME` | `wayland-caboose-0` | Wayland socket name in `$XDG_RUNTIME_DIR`; also names the instance's state directory |
| `--x-display N` | `110` | Xwayland display number |
| `--no-xwayland` | | Do not start Xwayland |
| `--x11-only` | | Point applications at Xwayland alone: the env file names `DISPLAY` and X11 toolkit backends, not `WAYLAND_DISPLAY` |
| `--no-audio` | | Do not run PulseAudio or send sound |
| `--audio-bitrate BPS` | `128000` | Opus bitrate |
| `--env-file PATH` | | Where to write the application environment once ready |
| `--renderer KIND` | `pixman` | The renderer (pixman is the only one) |
| `--always-compose` | | Compose every window instead of reading single-buffer windows in place (for comparisons) |
| `--no-motion` | | Keep regions that update at video rates in the window picture |
| `--client-timeout SECS` | `30` | Close a client that has sent nothing for this long; `0` never |
| `--encoder KIND` | `auto` | `auto`, `software` or `nvenc` |
| `--crf N` | `23` | Encoder quality, lower is better |
| `--preset NAME` | `ultrafast` | x264 preset |
| `--refine-qp N` | `12` | QP for sharpening quiet areas (H.264 software); `0` turns it off |
| `--refine-after MS` | `300` | How long an area must be quiet before it is sharpened |
| `--tile-max-px N` | `65536` | Largest change sent as lossless tiles (software encoders); `0` turns tiles off |
| `--encoder-threads N` | `0` | Threads per software encoder; `0` is 1 up to 2560×1600 and 2 above |
| `--display WxH@HZxS` | `1920x1080@60x1` | The display used before a client connects |
| `--list-encoders` | | Print the usable encoders and exit |

| Variable | Effect |
| --- | --- |
| `XDG_RUNTIME_DIR` | Required. Holds the Wayland socket, the default video socket and the instance's state directory |
| `CABOOSE_VIDEO_SOCKET` | The video passthrough socket (default `$XDG_RUNTIME_DIR/caboose-video.sock`) |
| `LIBVA_DRIVERS_PATH` | Where to look for `caboose_drv_video.so` (default `/usr/lib/x86_64-linux-gnu/dri`) |
| `CABOOSE_DISPLAY_LOG` | A `tracing` filter (`info`, `caboose_display=debug`, …) |

Each instance keeps its X authority (`Xauthority`), the Xwayland shim that adds `-auth`
(`bin/Xwayland`) and its PulseAudio socket (`pulse/native`) under
`$XDG_RUNTIME_DIR/caboose-display/<socket name>/`, so two instances with different
`--socket` names never share them.

The probe connects like the phone:

```sh
caboose-display-probe --token-file /run/caboose/display-token --duration 10 \
  --display 1179x2556@120x3 --save /tmp/out --server-pid "$(pidof -s caboose-display)"
caboose-display-probe --check --url ws://127.0.0.1:14601/ --token-file /run/caboose/display-token
```

`--url` selects the instance (default `ws://127.0.0.1:14600/`). `--save` writes each
window's stream and last decoded picture (PNG); `--type`, `--click` and `--touch` send
input once a window shows, and `--actions` replays a sequence of keys, text, taps and
clicks (`--window` picks the window); `--decoders`, `--video-decoders` and `--audio` set
what the probe announces; `--json` prints a machine-readable report; `--check` exits 0 as
soon as the server answers a hello. `caboose-display-probe --help` lists every option.

## In the guest

Both guest images build the binaries in a first Docker stage and install them with the
passthrough driver. Neither enables a unit at boot; the host starts the displays.

- **microVM** (`guest/image`): `caboose-display.service` is the owner's display, started
  by the host at each wake; `caboose-display-agent.service` is the agent seat, started
  when an agent task or the app's Agent space needs it. The agent seat runs
  `--listen 0.0.0.0:14601 --socket wayland-caboose-agent --x-display 101 --x11-only
  --no-audio --env-file /run/caboose/agent-display.env` on its own D-Bus session bus
  (`/run/user/1000/agent-bus`, from `caboose-agent-bus.service`) with its own
  notification endpoint, so the agents' notifications never reach the owner. Both units
  turn applications' accessibility on and start the display's accessibility bus once it
  is ready, so the desktop tools can read each display separately.
- **Container** (`guest/container`): `caboose-session start` starts the owner's display
  and `caboose-session start-agent` the agent seat, with the same arguments, as
  `caboose`; `caboose-session ready` waits for the owner's display.

`caboose-display-ready [TIMEOUT] [PORT]` exits 0 once the instance on `PORT` (default
`14600`; `14601` for the agent seat) answers a hello made with the token in
`/run/caboose/display-token`, and fails after `TIMEOUT` seconds (default 60).

On a Debian 13 system with the release binaries built, `install.sh [TARGET_DIR]`
installs the runtime libraries, the binaries, both units (not enabled), the readiness
check, and the D-Bus notification endpoint and monitor from
[guest/notifications](../notifications). The monitor forwards notifications through the
host, separately from the display protocol. Run `guest/notifications/check-container.sh`
to exercise the monitor without a VM; `guest/notifications/check.sh` checks a running
guest.
