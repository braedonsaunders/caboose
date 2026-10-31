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
  image. After ten seconds without an encode job, a worker releases its encoders if no
  refinement is pending; the next picture recreates them with keyframes. The image is
  retained for damage-tracked rendering. The encoder keeps the previous picture and compares the damaged 16×16 blocks
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
  terminals) get the commit as key presses. The virtual pointer publishes paired absolute
  and relative motion in one frame, retaining one Xwayland source device for XI2 scrolling.
  Relative deltas use logical coordinates and receive no additional acceleration.
- **Reconnecting.** Every hello carries the process's random `epoch` (16 hex characters,
  from `/dev/urandom` at start), so a client can tell that window ids still name the same
  windows. A hello's `window.create` messages are all written before the next client
  message is read, so the `pong` to a ping sent after the hello follows them. A new hello
  replaces the previous connection, which may be the same client's dead one.
- **Clipboard** (text). The phone's `clipboard` becomes the selection Wayland and X11
  applications paste; what they copy reaches the phone (and a new client is sent the
  current text on connect). Copying between Wayland and X11 applications on the computer
  works through Xwayland's window manager. When a focused window closes, focus returns to
  the window focused before it. X11 foreground metadata (`_NET_ACTIVE_WINDOW`)
tracks the seat’s focused X11 window and clears for Wayland or no focus. Stale XWM
property updates are reconciled on notifications, without a polling timer.
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
  ([guest/vaapi](../vaapi/README.md)), which offers each player's reconstructed bitstream. Every `OPEN` receives local-decode mode, including when no client is
  connected or the client advertises the codec: flattened marker pixels cannot prove
  foreground alpha or occlusion. Applications compose controls and subtitles over real
  decoded pixels, carried by the ordinary window/motion paths. Marker recognition and
  stream machinery remain available as experimental source; no alpha mask is inferred.
  Launched applications get `LIBVA_DRIVER_NAME=caboose` when the driver is installed.
- **Game handoff** ([docs/game-handoff.md](../../docs/game-handoff.md), `src/game.rs`). The
  compositor listens on the game socket (`$CABOOSE_GAME_SOCKET`, default
  `$XDG_RUNTIME_DIR/caboose-game.sock`) for `caboose-game-run`
  ([guest/game](../game/README.md)), binds each launcher to the toplevel its process made
  (SO_PEERCRED), and tells it whether the connected client runs games. A client whose hello
  says `wasm: true` gets `game.create` after the window's `window.create` and
  `game.destroy` when the game ends, and the window sends it no pictures meanwhile.
  `--no-games` turns it off (the agent seat).
- **Phone devices** ([docs/devices.md](../../docs/devices.md), `src/devices`). For a client
  whose hello says `devices: true`, a hub thread makes the phone's hardware the computer's:
  gamepads, the motion device and buttons through uinput, the motion sensors (IIO) and
  battery as HID devices through UHID, cameras and depth as v4l2loopback devices, and the
  microphone as a source in the display's PulseAudio. It tells the phone with
  `device.open` and `device.close` when applications start and stop using a device, and
  writes `$XDG_RUNTIME_DIR/caboose-devices.json`. `--no-devices` turns it off (the agent
  seat).
- **Detected motion** (`src/motion.rs`). Each window's changed macroblocks feed a tracker.
  A dense rectangle of at least 192×112 pixels whose blocks change in most pictures at
  15 fps or more, for a second, becomes a `motion` video stream. The window's encode
  worker encodes that crop with its own encoder (no sharpening) and leaves it out of the
  window picture. A client advertising `scaled_motion` receives eligible software-encoded regions at half
  width and height with placement unchanged. Once the region has stopped looking like video for a second, a window
  picture repaints it and the stream ends. Only for a client that lists the stream's codec
  in `video_decoders` or advertising `scaled_motion`; `--no-motion` turns it off.

Limitations: the renderer is pixman (CPU), so buffers reach the encoders through system
memory and the compositor offers no YUV formats; tiles come only from the software
encoders; the clipboard carries text only; cursors are sent by name, not as images; notifications are not sent
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
→ byte conversion for deletions, flow control, the launch environment, configuration and
per-instance state directories, the Xauthority format, and the control socket's key
combinations and text escapes.

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
| `chromium-touch-fling` | a timed native finger swipe scrolls a real Chromium page, then continues after release without client-generated wheel events |
| `reconnect` | window ids survive a reconnect and each window restarts with a keyframe |
| `reconnect-idle` | a window streamed in place from its shm buffer that draws nothing between two clients gives the second client the same picture |
| `encoder-eviction` | a quiet Chromium window changes after encoder eviction; its new keyframe decodes on the same connection |
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
| `passthrough` | `video-admission.py` opens all four driver codecs before/during an advertising probe session and requires local-decode mode; no owner windows or media |
| `clipboard-wayland` | the phone's text pastes into Chromium (Ctrl+V), and Chromium's copy (Ctrl+A, Ctrl+C) reaches the phone |
| `clipboard-x11` | an X11 copy (xclip) reaches the phone on connect, and the phone's copy reaches X11 |
| `clipboard-bridge` | on the computer, a Wayland copy (wl-copy) pastes into X11 and an X11 copy into Wayland |
| `audio` | a tone played into the session's default output reaches the probe as stereo Opus it decodes, at the tone's level, and the silence before it is not sent |
| `refine` | a quiet terminal gets its keyframe, one sharpening picture 300 ms later and then nothing; against a near-lossless reference the sharpened picture is at least 3 dB closer; a blinking caret costs at most 4 extra pictures in 6 s, not one per blink |
| `motion` | Chromium plays a 480×270 canvas "video" in a page of text for 8 s: it becomes one `motion` stream at the canvas, every frame decodes with a pts, the window stream sends at most half as many pictures beside it, the stream ends after the video stops, and the final window picture matches the one streamed with `--no-motion` (≥ 40 dB) |
| `scaled-motion` | Chromium motion decodes at half size and retains its placement when the client advertises `scaled_motion` |
| `tiles` | 31 characters typed into Chromium at 1179×2556 go as tiles: every tile decodes, at most a third of the pictures of a run without tiles, the server spends at most 60% of the CPU, and the final picture (frame plus tiles, as the client paints it) matches the one without tiles (≥ 40 dB); a 250×250 animation at 60 Hz stays video |
| `idle` | an idle window with a client ticking vsync costs under 2% of a core |

`scripts/check-devices.py` checks the phone's devices ([docs/devices.md](../../docs/devices.md))
against a real kernel, so it runs inside a computer rather than the dev container: as root,
with the owner's display running and no phone connected, it plays a phone over the
protocol and checks each device through the kernel's own interfaces.

```sh
sudo python3 /path/to/guest/display/scripts/check-devices.py
sudo python3 check-devices.py --only microphone   # a container computer
```

| Check | What it proves |
| --- | --- |
| `gamepad` | a press and a stick reach the gamepad's event device, which the owner's applications can open; a rumble effect uploaded and played through evdev arrives as `device.rumble` with its magnitudes and length |
| `buttons` | volume up and the camera button arrive as `KEY_VOLUMEUP` and `KEY_CAMERA` presses and releases |
| `motion` | opening the motion event device sends `device.open` at 100 Hz, a face-up sample reads `ABS_Z` 8192 (1 g), closing it sends `device.close` |
| `iio` | the HID sensor hub became `accel_3d`, `gyro_3d`, `magn_3d`, `dev_rotation` and `press`; enabling the accelerometer's buffer opens motion, and the sample reads 9.80665 m/s² through the IIO scale |
| `battery` | the power supply reads 75%, Charging, scope Device |
| `camera` | ffmpeg streaming from the camera's node opens it; the phone's H.264 test picture arrives as YUYV; stopping sends `device.close` |
| `depth` | the depth node streams the phone's millimetres unchanged as 16-bit greyscale (`Y16`) |
| `microphone` | `parec` recording from the phone's source opens it and records the 1 kHz Opus tone sent to it |
| `disconnect` | closing the connection removes the gamepad and the battery |

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
`--env-file` in sh syntax: `WAYLAND_DISPLAY`, `DISPLAY`, `XAUTHORITY`, `XDG_RUNTIME_DIR`,
toolkit backends (Wayland first), `CABOOSE_DISPLAY_CONTROL` (its control socket),
`PULSE_SERVER` when it plays sound, `CABOOSE_GAME_SOCKET` when it hands games off,
`LIBVA_DRIVER_NAME=caboose`,
`GST_VA_ALL_DRIVERS=1` and `CABOOSE_VIDEO_SOCKET` when the passthrough driver is
installed, and the GPU variables it was started with (`GALLIUM_DRIVER`,
`MESA_D3D12_DEFAULT_ADAPTER_NAME`, `LIBVA_DRIVER_NAME`). Started with the private GPU
sockets and with the phone's driver installed, it routes applications to the phone's GPU
instead: `VK_ADD_DRIVER_FILES`, `CABOOSE_GFXSTREAM_SOCKET`,
`CABOOSE_GFXSTREAM_SURFACE_SOCKET`, `CABOOSE_GPU_EXECUTOR_SWITCH=1`, `LIBGL_KOPPER_DRI2=1` and
`GSK_RENDERER=vulkan`,
without `GALLIUM_DRIVER` ([docs/gpu-live.md](../../docs/gpu-live.md#applications)). It also serves an input method,
`IBUS_ADDRESS` and `IBUS_ADDRESS_FILE` (with `QT_IM_MODULE=ibus`): applications without
text-input-v3 (X11 clients, whose GTK selects IBus from the window manager's XSETTINGS
`Gtk/IMModule`; Qt; SDL) tell it when an editable field gains or loses focus, which shows
and hides the phone's keyboard, and receive its commits and pre-edit text as IBus signals
(`compositor/src/ibus.rs`, D-Bus wire format in `compositor/src/dbus.rs`). Sandboxed
(Flatpak) applications reach the same service as `org.freedesktop.portal.IBus` on the
session bus, which the compositor joins when `DBUS_SESSION_BUS_ADDRESS` is set
(`compositor/src/ibus_portal.rs`); their fields belong to the window that had keyboard
focus when they gained focus. No IBus daemon runs; the image carries IBus's GTK modules and `ibus-daemon`, whose presence Qt requires.
It then runs `COMMAND` with that
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
| `--no-audio` | | Do not run PulseAudio or send sound |
| `--no-games` | | Do not listen for game launchers |
| `--no-devices` | | Do not accept the phone's hardware as devices ([docs/devices.md](../../docs/devices.md)) |
| `--private-gpu-stream-socket PATH` | disabled | Owner-only private live GPU stream socket; requires the surface socket option |
| `--private-gpu-surface-socket PATH` | disabled | Owner-only private live GPU surface socket; requires the stream socket option |
| `--private-gpu-indexed` | disabled | Select private indexed v4 transport; requires both private GPU sockets |
| `--gpu-spool-limit BYTES` | `2147483648` | The most of one GPU stream kept on disk; a stream that outgrows it ends |
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
| `CABOOSE_GAME_SOCKET` | The game socket (default `$XDG_RUNTIME_DIR/caboose-game.sock`) |
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
clicks (`--window` picks the window, and `close` closes it); `--decoders`,
`--video-decoders`, `--audio` and `--wasm` set what the probe announces, and with `--wasm`
the report lists the games handed to it; `--json` prints a machine-readable report; `--check` exits 0 as
soon as the server answers a hello. `caboose-display-probe --help` lists every option.

## Control socket

Each instance listens on `control.sock` in its private directory
(`$XDG_RUNTIME_DIR/caboose-display/<Wayland socket name>/`, mode 0600) and serves only
processes of its own user. It is how the computer's own tools see and drive a seat, Wayland
and X11 windows alike: `windows` (each window's id, kind, title, app id, process, X window
for Xwayland, geometry, root surface and focus, bottom to top), `focus`, `click`, `press`,
`release`, `move`, `scroll`, `key`, `type`, `settle` and `screenshot`. Requests are single
lines and answers single JSON lines (a screenshot's is followed by the PNG); the full list is
in [docs/architecture.md § Displays](../../docs/architecture.md#displays) and the code in
`compositor/src/control.rs`. Its path is in the launch environment as
`CABOOSE_DISPLAY_CONTROL`, and [`guest/desktop-mcp/seat.py`](../desktop-mcp/seat.py) is its
client:

```sh
set -a; . /run/caboose/display.env; set +a
python3 /opt/caboose/seat.py windows
python3 /opt/caboose/seat.py click 640 360
python3 /opt/caboose/seat.py key ctrl+s
python3 /opt/caboose/seat.py screenshot --out /tmp/seat.png
```

## In the guest

Both guest images build the binaries in a first Docker stage and install them with the
passthrough driver. Neither enables a unit at boot; the host starts the displays.

- **microVM** (`guest/image`): `caboose-display.service` is the owner's display, started
  by the host at each wake; `caboose-display-agent.service` is the agent seat, started
  when an agent task or the app's Agent space needs it. The agent seat runs
  `--listen 0.0.0.0:14601 --socket wayland-caboose-agent --x-display 101 --no-audio
  --no-games --env-file /run/caboose/agent-display.env` on its own D-Bus session bus
  (`/run/user/1000/agent-bus`, from `caboose-agent-bus.service`) with its own
  notification endpoint, so the agents' notifications never reach the owner. Both units
  turn applications' accessibility on and start the seat's accessibility bus once it is
  ready, so the screen and desktop tools can read each seat separately.
- **Container** (`guest/container`): `caboose-session start` starts the owner's display
  and `caboose-session start-agent` the agent seat, with the same arguments, as
  `caboose`; `caboose-session ready` waits for the owner's display.

`caboose-display-ready [TIMEOUT] [PORT] [ENV_FILE]` exits 0 once the instance on `PORT`
(default `14600`; `14601` for the agent seat) answers a hello made with the token in
`/run/caboose/display-token` and has written its launch environment (`ENV_FILE`, by default
`/run/caboose/display.env`, or `/run/caboose/agent-display.env` for `14601`), and fails after
`TIMEOUT` seconds (default 60). The hello answers before Xwayland is up, and the launch
environment is written once it is.

On a Debian 13 system with the release binaries built, `install.sh [TARGET_DIR]`
installs the runtime libraries, the binaries, both units (not enabled), the readiness
check, and the D-Bus notification endpoint and monitor from
[guest/notifications](../notifications). The monitor forwards notifications through the
host, separately from the display protocol. Run `guest/notifications/check-container.sh`
to exercise the monitor without a VM; `guest/notifications/check.sh` checks a running
guest.

### Window decoration check

`guest/display/scripts/dev.sh python3 scripts/check-decorations.py` starts private
compositors and GTK 3 windows on Wayland and X11. It verifies that default titlebars
are absent while menus and explicit custom headerbars remain visible. Build the
debug compositor first (`cargo build` in the dev container). The dev image includes
PyGObject and GTK 3 introspection for this check. After deploying a new compositor,
reopen a CLI launcher such as OpenCode: the phone supplies its single window header,
while the terminal menu remains usable. Existing app processes must be reopened.

### X11 foreground regression

`scripts/check-x11-focus.py` runs against a disposable, initially empty seat. Source
that seat’s launch environment and run:

```sh
python3 scripts/check-x11-focus.py --control "$CABOOSE_DISPLAY_CONTROL" \
  --wayland-command weston-simple-shm
```

The fixture creates a passive X11 client and a globally active `WM_TAKE_FOCUS` client,
checks Return delivery, injects stale foreground properties and a property burst,
then checks Wayland and empty-seat transitions and notification convergence. It uses
Python, libX11 and libXtst; the supplied command creates a native Wayland window.
It closes its own clients on success or failure and refuses an occupied seat. Run
the identical fixture on the previous compositor as a negative control: stale
foreground metadata fails its foreground assertion. No owner display is involved.

### X11 core wheel delivery check

`scripts/check-x11-scroll.py --control /path/to/private/control.sock --compositor-pid PID` compares one
XTest wheel-down press/release with two separate ordinary wheel scrolls through the
compositor control socket at the same point. Source the private seat's launch
environment first so `DISPLAY` and `XAUTHORITY` match that control socket. The check
requires Python 3, libX11 and libXtst and refuses a nonempty seat. Before creating
any X resource it verifies the control peer PID, matching private authority path,
and X socket ownership by that compositor or its directly spawned Xwayland. It creates its own
X11 parent and child, selects only core pointer events on its own child, asserts one
button-5 press/release pair for each path, and destroys both windows on exit. It does
not use XI event selection or RECORD on another application's windows. Run only on
a disposable compositor: it creates windows and injects input into that private seat.
This check covers ordinary wheel delivery; it does not measure a toolkit's response
to precise scroll values.

Add `--record-oracle` to validate the passive RECORD reader against that owned
fixture. The check reads back the registered client and event ranges, then requires
RECORD's core wheel type/button/time/recipient tuples to equal the tuples received
by the fixture. `python3 scripts/test_x11_record.py` checks fixed 32-byte RECORD
headers (including GenericEvents advertising a larger body), byte order, ABI layout,
and exclusion of keys and unrelated generic extensions. The reader requires Xlib
thread initialization before opening any display, as the fixture does. It records
at most 256 pointer metadata entries and closes its context, thread and displays.

`--xi2-oracle observe` additionally selects XI2 master pointer motion, buttons and
device changes on the fixture's own child, requiring libXi. It preserves the core
oracle first, then compares two consecutive compositor wheels: the actual vertical
valuator delta must equal the source device's advertised scroll increment. It queries
the X pointer position before and after, records device/source IDs and scroll classes,
and compares received XI2 pointer headers against RECORD AllClients restricted to the
owned child. RECORD does not contain the full valuator payload; the owned XI2 client
supplies that independent oracle. No other application's XI selection is changed.

The fixture also models a consumer that discards the first sample after a source-device
switch, as Chromium's X11 event handling does. `--xi2-consumption switching` requires repeated
source switches and zero consumed deltas despite an advancing valuator;
`--xi2-consumption stable` requires no switch during the second wheel and one consumed
increment. `--moving-anchor` also moves the second wheel's position within the owned
child and verifies its root and local coordinates. These product assertions use the
owned client's events independently of RECORD. The separate `--xi2-oracle` modes require
the same assertions plus successful recording; they fail when RECORD misses delivery.
XI2 RECORD observation is unavailable in the pinned 24.1.6 private fixture despite
verified owned-client delivery; an empty observer result does not mean no delivery.
`python3 scripts/test_x11_scroll_xi2.py` checks the LP64 Xlib/XInput2 layouts, packed
valuator masks, scroll-class increments and both baseline-consumption sequences without
opening a display. Bound the runtime fixture with `timeout --kill-after=2 20` on a
private compositor; it does not change the compositor or any application settings.

The consumer semantics are pinned to Chromium commit
[`f0e7f7419b34`](https://github.com/chromium/chromium/tree/f0e7f7419b34b221aa949b302d6629c4dba8fb06):
`ui/events/platform/x11/x11_event_source.cc` invalidates a source's scroll baseline
on `SlaveSwitch`, and `ui/events/devices/x11/device_data_manager_x11.cc` consumes zero
for its first sample. Xwayland 24.1.6's `hw/xwayland/xwayland-input.c` selects the
absolute pointer for motion without a relative event and its relative pointer for
scrolling; `dix/getevents.c::UpdateFromMaster` emits the source-switch notification.
The official `xwayland-24.1.6.tar.xz` SHA-256 is
`737e612ca36bbdf415a911644eb7592cf9389846847b47fa46dc705bd754d2d7`.
This consumer fixture does not establish which Chromium revision an application embeds.

`scripts/check-pointer-scroll-clients.py --control /path/to/private/control.sock
--compositor-pid PID --token-file /private/runtime/token --port 15499` validates real
Chromium content scrolling under X11 and native Wayland. It requires the existing
Chromium binary and Python websockets, verifies private socket/process/authority pairing
before launching either client, and refuses a nonempty seat. It uses separate temporary
profiles and the local `pages/pointer-scroll.html`, with no external content or CDP input.
At display scale 1.5, protocol pointer messages must move the page's pointer, deliver a
button drag and release, and scroll actual content with both ordinary wheels and precise
deltas while the anchor moves. Fixture-generated event counts and `scrollY` are the
oracle; the page does not implement scrolling itself. Run in the private networkless
container under a 20-second process deadline. The script closes its session and browser
process groups, and the harness reaps its compositor and entire container.

`--scale` selects the output scale (default 1.5); `--precise-delta` selects each of
three precise samples (default 24). The result includes these inputs, DOM wheel delta
sums/mode and actual `scrollY`. On a fresh private seat for each run, compare
`--precise-delta 24` with `--precise-delta 2` to exercise the phone's direct-content
calibration, then repeat at scales 1 and 3. Subtract the `wheel` snapshot from `precise`
for both DOM deltas and content displacement. The X11 and native Wayland results are
reported separately; acceptance requires movement, not a universal pixel gain.
The [phone unit trace](../../docs/display.md#direct-content-scroll-units) describes
how to map the measured content distance back through a presented surface. Retain
image digest, compositor hash and Chromium version alongside results. This fixture
uses protocol pointer input; native `wl_touch` scrolling remains a separate device check.

### Fullscreen output resize regression

`scripts/check-output-resize.py` checks native Wayland and X11 GTK3 windows on a
private, initially empty compositor. The harness must isolate its network namespace
and home, start the compositor with a private token and sockets, and source that
compositor's launch environment. Run with a 20-second fixture deadline:

```sh
timeout -k 2 20 python3 scripts/check-output-resize.py \
  --control "$CABOOSE_DISPLAY_CONTROL" --compositor-pid "$PRIVATE_COMPOSITOR_PID" \
  --token-file "$PRIVATE_TOKEN_FILE" --port 15499
```

The check requires GTK3 PyGObject and Python `websockets` with the sync API. It
validates control/Wayland socket peers and the matching child Xwayland before
creating clients. Each backend creates fullscreen, maximized and ordinary windows.
The assertions cover same-id portrait mode changes, an identical output announcement
(no additional client configure events), downstream output-origin movement, and
removed-output fallback. Fullscreen/maximized state and window identities persist;
ordinary window sizes/positions remain unchanged. Frame acknowledgements keep the
private clients rendering. It sends no pointer, keyboard or focus commands and
closes its connections and GTK children on exit. The harness must reap the private
compositor/Xwayland too; never run it against an owner's display. The unchanged
compositor fails the same-id portrait size assertion.

The pure `DesktopGeometryTests`/`FullscreenGeometryTests` and iOS hosted
`DesktopSurfaceLayoutTests` check ordinary top fitting, fullscreen centering during
rotation/settling, and consistent input, popup and text-drop geometry. These are
presentation checks; they do not establish a scroll-delivery fix.

### Internal marker regression

The production `passthrough` check verifies local-decode admission. The historical
marker binding/forwarding check is retained separately in
`scripts/check-marker-binding.py`. It is explicitly opt-in and requires
`CABOOSE_DISPLAY_BIN` pointing to compositor and probe binaries built together from
pinned legacy source `7f3b94796bcc1e691ac39a5754048fe26ddd158f`. Record both binary
SHA-256 hashes with the run and use a disposable fixture environment; this is not a
production launch recipe:

```sh
CABOOSE_DISPLAY_BIN=/path/to/isolated/test-binaries python3 scripts/check-marker-binding.py --legacy-marker-binding
```

It intentionally fails against the current production admission policy; it adds no
runtime override to the compositor. Source tests in `video::marker` and `video::tests`
cover marker detection, geometry, internal binding fields, decode order and the
reconnect presentation fence without accepting a production passthrough stream.

`.github/workflows/check-video.yml` builds the declared display test image, tests video
internals, builds compositor/probe from the checked source, then runs admission with
those exact binaries. Its separate VAAPI job builds `guest/vaapi/Dockerfile`, which
includes FFmpeg and Xvfb, and runs state tests plus four selected codec roundtrips.
These hosted software checks do not establish native phone decode or overlay correctness.

Device checks accept `--token-file` and `--display-env` for isolated test instances,
and `--expect-no-devices` verifies the agent seat omits capability and ignores offers.
They reject unknown check names, bound helper processes, and open input/video nodes as
`caboose` to check the owner's actual access before exercising them as root. Containers
support the private microphone only; kernel input, camera and UHID checks require a VM.
