# Caboose Display

Caboose's display server: a headless Wayland compositor that renders every window on the
phone's GPU and presents it as its own phone-resident image, for the phone and TV to show
as native surfaces. The computer runs two instances, one for the owner and one for agents.
The design, the deployment and the wire contract are [docs/display.md](../../docs/display.md).

This directory is a Cargo workspace:

| Path | What |
| --- | --- |
| `protocol/` | `caboose-display-protocol`: Caboose Display Protocol v0. Framing, the canonical CBOR codec, every message, and the golden vector set. No dependencies |
| `compositor/` | `caboose-display`: the compositor |
| `probe/` | `caboose-display-probe`: a headless client that drives windows and reports windows, input, clipboard, drag and drop, sound and server CPU; also the readiness check |
| `vectors/` | Golden vectors every client replays (see [vectors/README.md](vectors/README.md)) |
| `scripts/check.py` | Scripted checks against real applications |
| `wlcs/`, `scripts/check-wlcs.py` | Runs WLCS, Mir's Wayland conformance suite, against the compositor with its own adapter ([wlcs/README.md](wlcs/README.md)) |
| `scripts/scroll-bench.py` | Wheel-scrolls a window through the control socket and reports its commits, presents, render time and upload bytes per present |
| `scripts/gpu-windows-check.sh` | Checks the GPU compositor's window pictures and wire costs against foot, xterm, GTK 3 and Wine |
| `systemd/`, `install.sh`, `caboose-display-ready` | Running it in a guest |
| `Dockerfile`, `scripts/dev.sh` | The build and test environment |

## What the compositor does

- **Wayland and X11 applications.** A headless [Smithay](https://github.com/Smithay/smithay)
  compositor with xdg-shell (toplevels and popups), xdg-decoration (applications are told
  the phone draws the frame, so they draw no title bar of their own), viewporter,
  fractional scale, cursor-shape, linux-dmabuf and wl_shm. With the computer's render
  node (`vgem`), dma-buf feedback names it and phone-resident buffers (`MOD_REMOTE`) are
  shown directly through the GPU stream ([docs/gpu-buffers.md](../../docs/gpu-buffers.md)).
  Xwayland runs with a window manager, so X11 applications are windows too, with a per-boot
  MIT-MAGIC-COOKIE in an Xauthority file.
- **One GPU image per window** (`src/render.rs`, `src/present.rs`, `src/picture.rs`,
  `src/upload.rs`). Every toplevel, dialog, popup and X11 window is announced with
  `window.create`. The compositor composes nothing across windows:
  - A window whose tree is a single phone-resident client buffer covering its geometry
    presents that buffer directly (`State::present_remote_buffer`).
  - A window whose application renders into its own phone Vulkan swapchain presents on its
    own surface.
  - Every other window (wl_shm, subsurfaces, popups, X11 windows) is composed by the
    compositor as an OpenGL ES client on Zink over the Caboose Vulkan ICD into double-buffered
    `MOD_REMOTE` GBM images at the buffer's own density, and presented with `BUFFER_PRESENT`
    under the compositor's own PID. On the agent seat or when no phone executor is attached,
    the routing layer presents the computer's CPU Vulkan device (lavapipe) and the compositor
    renders into ordinary textures for `control.sock` screenshots. When the executor changes,
    the compositor rebuilds its renderer and repaints every window from its client buffers.
- **Popups keep their alpha.** A popup (an xdg popup, or an X11 override-redirect menu or
  tooltip) is announced with `alpha: true` and rendered into its own transparent image
  with premultiplied alpha.
- **Damage-only uploads.** Each `wl_shm` buffer has its own GPU staging buffer laid out
  with the buffer's stride (`src/upload.rs`). An update copies only the client's damaged
  rectangles into the staging buffer before uploading those rectangles to the texture, so
  the driver's changed-block flush sends only the blocks that differ from that buffer's
  previous upload.
- **Paced by the client.** Frame callbacks are released on the client's `vsync` while the
  window's image pool has room, so applications draw at the rate the screen can show. A
  window whose display sends no vsync gets frame callbacks once a second.
- **Input.** Pointer (buttons as a pressed set, precise and wheel scrolling), multitouch
  (`wl_touch`, one frame per message), physical keys by USB HID position and synthetic keys by keysym (mapped to the keymap, with the
  modifiers a level needs), and text: commits and pre-edit text go to the focused surface
  through text-input-v3, whose enable/disable is reported with `text_input` (also to a
  client that connects after a field was focused); deletions are BackSpace/Delete
  presses, one per grapheme cluster. Surfaces without text-input-v3 (X11 apps, many
  terminals) get the commit as key presses. The virtual pointer publishes paired absolute
  and relative motion in one frame, retaining one Xwayland source device for XI2 scrolling.
  Relative deltas use logical coordinates and receive no additional acceleration.
- **Window hints** (`src/hints.rs`). idle-inhibit, content-type, xdg-activation,
  keyboard-shortcuts-inhibit and xwayland-keyboard-grab become window fields and
  `window.activate` for the phone to act on ([docs/display.md](../../docs/display.md#window-hints)).
- **Reconnecting.** Every hello carries the process's random `epoch` (16 hex characters,
  from `/dev/urandom` at start), so a client can tell that window ids still name the same
  windows. A hello's `window.create` messages are all written before the next client
  message is read, so the `pong` to a ping sent after the hello follows them. A new hello
  replaces the previous connection, which may be the same client's dead one.
- **Clipboard** (text, PNG and JPEG images, files). The phone's `clipboard` becomes the
  selection Wayland and X11 applications paste; what they copy reaches the phone in the
  types its hello lists (and a new client is sent the current copy on connect). Copies
  are checked against the contract (types, signatures, 12 MiB together) both ways;
  applications get 5 s to hand over a copy and 30 s to take a paste, each on its own
  thread. Files from the phone must be in the transfer area
  (`~/.cache/caboose/transfers`, see [guest/files](../files/README.md)) and are opened
  without following links before they are offered. Copying between Wayland and X11 applications on the computer
  works through Xwayland's window manager. When a focused window closes, focus returns to
  the window focused before it. X11 foreground metadata (`_NET_ACTIVE_WINDOW`)
tracks the seat’s focused X11 window and clears for Wayland or no focus. Stale XWM
property updates are reconciled on notifications, without a polling timer.
- **Drag and drop** (`src/dnd.rs`, `src/xdnd.rs`). A drop from the phone becomes a real
  drag over the application under the finger: an XDND session from the compositor's own X
  client for an X11 window, whose answer goes back as `drop.status` while it hovers, or a
  compositor-owned Wayland drag on the seat's pointer, which enters the Wayland surface only
  once `drop.perform` has brought the content (files in the transfer area), because
  applications read a drag as it enters. The drag is released once the application accepts
  and has read the content. A Wayland application's
  drag is announced with `drag.start`; on `drag.take` the compositor moves it off every
  window, reads it as it reads a copy while the phone's input waits, sends `drag.data`,
  and lets the release end it as not dropped.
- **Sound.** The compositor runs its own PulseAudio on a private socket with a null sink
  as the only, so default, output, and gives launched applications `PULSE_SERVER`. While a
  client that plays Opus is connected (`hello.audio_decoders`), `parec` records the sink and
  each 20 ms of 48 kHz stereo goes out as an `audio` message, timestamped on the pictures'
  clock; silence stops being sent after a second, and nothing records with no listener.
  A PulseAudio an earlier instance left on the socket is ended at start, a server that
  exits is started again on the same socket, and a recorder that stops is started again
  while a client listens. `--no-audio` turns it off.
- **Sessions.** One client at a time; a new authenticated client replaces the previous
  one. Window ids survive reconnects. A client that sends nothing for `--client-timeout`
  (30 s) is closed.
- **Video decoding** ([docs/gpu-media.md](../../docs/gpu-media.md),
  [guest/vaapi](../vaapi/README.md)). Launched applications get `LIBVA_DRIVER_NAME=caboose`
  when the Caboose VA-API driver is installed: on the GPU seat it decodes on the phone
  through the GPU stream and latches into the application's Vulkan image, and otherwise it
  decodes on the computer into the application's own surfaces.
- **Game handoff** ([docs/game-handoff.md](../../docs/game-handoff.md), `src/game.rs`). The
  compositor listens on the game socket (`$CABOOSE_GAME_SOCKET`, default
  `$XDG_RUNTIME_DIR/caboose-game.sock`) for `caboose-game-run`
  ([guest/game](../game/README.md)), binds each launcher to the toplevel its process made
  (SO_PEERCRED), and tells it whether the connected client runs games. A client whose hello
  says `wasm: true` gets `game.create` after the window's `window.create` and
  `game.destroy` when the game ends, and the window presents no pictures meanwhile.
  `--no-games` turns it off (the agent seat).
- **Phone devices** ([docs/devices.md](../../docs/devices.md), `src/devices`). For a client
  whose hello says `devices: true`, a hub thread makes the phone's hardware the computer's:
  gamepads, the motion device and buttons through uinput (gamepads through the host's
  uinput on a container computer, `--host-pads` and `--pad-link`), the motion sensors (IIO) and
  battery as HID devices through UHID, cameras and depth as v4l2loopback devices, and the
  microphone as a source in the display's PulseAudio. It tells the phone with
  `device.open` and `device.close` when applications start and stop using a device, and
  writes `$XDG_RUNTIME_DIR/caboose-devices.json`. `--no-devices` turns it off (the agent
  seat).

Limitations: the clipboard carries text, PNG and JPEG images and files, not rich text or
other image types; notifications are not sent on the display protocol; and characters that
are not on the keymap cannot be typed into X11 applications without IBus support.

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

`cargo test -p caboose-display --test advertisement` starts the compositor and fails when
anything it advertises does not work: every Wayland global must have a check that binds it at
its advertised version and uses it (a global without a check fails), every hello feature must be
documented and backed by what it names, and the hint protocols are followed to the window
messages the phone acts on. It needs the runtime image (the `Dockerfile` here: libEGL, a Vulkan
device, Xwayland) and reports what it skipped where that is missing.

Unit tests cover the protocol (canonical encoding, the stream decoder on split and
malformed input, and the committed vectors against the encoder), the pixel conversion
(reference colours, damage-only and threaded conversion, changed-block detection), the
encoders (parameter sets on keyframes), keysym mapping on the real `us` keymap, grapheme
→ byte conversion for deletions, flow control, the launch environment, configuration and
per-instance state directories, the Xauthority format, the control socket's key
combinations and text escapes, the clipboard's checks and type choice, bounded pipe
transfers, and the transfer area's path and link checks.

`scripts/check.py` starts the compositor with real applications and drives it with the
probe. Every check asserts on what arrived, not on a picture:

| Check | What it proves |
| --- | --- |
| `auth` | a wrong token gets `bye(auth)`; the right one gets windows |
| `physical-key` | a physical HID position and an unknown-position keysym fallback reach weston-terminal |
| `wayland-terminal` | text typed from the client reaches weston-terminal exactly (key fallback) |
| `x11-terminal` | the same through Xwayland into xterm |
| `taskbar` | an X11 window a shell started, with a class no desktop entry has and a `_NET_WM_PID` from another namespace, reports the X server's PID for its process and its `_NET_WM_ICON`, and its icon change follows as an update (`scripts/x11-icon-window.py`) |
| `two-windows` | two applications are announced as two windows |
| `chromium-text-input` | touch reaches the page; text-input-v3 is enabled and its commit arrives exactly |
| `chromium-touch-fling` | a timed native finger swipe scrolls a real Chromium page, then continues after release without client-generated wheel events |
| `reconnect` | window ids survive a reconnect |
| `replace` | a second client takes over; the first gets `bye(replaced)` |
| `storm` | 48 broken connections while a window animates (closed at once, left silent, handshakes cut short, a wrong token, clients killed mid-session): the next client is served as usual, and the server's threads and memory are back where they were |
| `takeover` | six clients take the display from each other in turn: each is told of the window, each one replaced gets `bye(replaced)` |
| `app-crash` | two of three applications (one an X11 app) are killed: their windows go, the survivor stays, the next client gets it |
| `stalled-client` | a client stops reading while sound plays: memory does not grow, the server closes it after `--client-timeout`, the next client is served |
| `popup` | a `<select>` list is its own popup window with the page as parent, with alpha over an opaque toplevel |
| `text-input-on-connect` | a client that connects after a field was focused is still told text input is enabled |
| `autocorrect` | `text` with `delete_before` (autocorrect, the delete key) edits a Chromium field exactly, one grapheme cluster per deletion |
| `clipboard-wayland` | the phone's text pastes into Chromium (Ctrl+V), and Chromium's copy (Ctrl+A, Ctrl+C) reaches the phone |
| `clipboard-x11` | an X11 copy (xclip) reaches the phone on connect, and the phone's copy reaches X11 |
| `clipboard-bridge` | on the computer, a Wayland copy (wl-copy) pastes into X11 and an X11 copy into Wayland |
| `clipboard-image-wayland` | a PNG copied with wl-copy reaches a phone that takes images byte for byte (and not a text-only phone); the phone's PNG pastes with wl-paste byte for byte |
| `clipboard-image-x11` | the same through Xwayland with xclip |
| `drop-wayland` | a file the phone uploaded, then text, dropped on a Chromium page's drop zone (a real Wayland drag, entered with the content): received by the page; a drop where the page refuses is rejected and never reaches it. |
| `drop-x11` | the same with Chromium on X11, through XDND |
| `drag-out` | a pointer drag of a Chromium page's draggable text that the phone takes: the phone is told of it, receives the text, and the release drops nothing on the page |
| `clipboard-files` | a file manager's copy (`x-special/gnome-copied-files`) reaches the phone as a `text/uri-list`; a file the phone uploaded to the transfer area pastes as both lists, and a file outside it is refused |
| `audio` | a tone played into the session's default output reaches the probe as stereo Opus it decodes, at the tone's level, and the silence before it is not sent |
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

`scripts/check-finger-scroll.py` checks finger scrolling through Xwayland
([docs/input.md](../../docs/input.md)). It runs Chromium on X11 at scale 2 (a
1338×1902 display) with pages/finger-scroll.html and pans twice, ten precise scrolls of
40 window pixels 16 ms apart (the probe's `wheel:` action), then turns a mouse wheel one
click (`notch:`). It fails unless each pan scrolls the page 200 CSS pixels (within 5%)
and stops with the finger (within 50 ms), and the click scrolls an animated step. It
needs the computer's Xwayland ([guest/xwayland](../xwayland/README.md)); `--step` and
`--samples` change the pan:

    guest/display/scripts/dev.sh python3 scripts/check-finger-scroll.py [--step PX] [--samples N]

### Checking the pictures

`scripts/gpu-windows-check.sh` runs in a disposable container of a computer image, on the
computer's own Vulkan device (lavapipe, presented as a GPU by the routing layer), without
a phone:

    guest/display/scripts/gpu-windows-check.sh IMAGE BIN LIBS [OUT]

It starts `caboose-display` and `caboose-display-probe`, opens `foot` (Wayland `wl_shm`),
`xterm` (X11 core), `scripts/gtk-reference.py` (an odd-sized 300×161 GTK 3 window that
also renders itself offscreen to a reference PNG) and `wine winver` (after `wineboot -i`),
takes each window's picture through `control.sock` (`screenshot`), and checks pixel-for-pixel
equality (`differing_px == 0` against GTK's offscreen reference and X11's `import -window`
for `xterm` and `wine`, and bounded glyph damage for `foot`), zero renders/uploads/presents
over 5 s of idle, and per-glyph damage and uploaded bytes across 20 typed characters in
`foot` and `xterm`.

Two scripted checks outside this directory exercise both instances together:
`guest/computer-use/check/check-a11y.sh` runs the owner's display and the agent seat in Docker
and drives them with the computer-use tools, and `apps/host/scripts/e2e.sh` checks a hello on
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
`LIBVA_DRIVER_NAME=caboose` and
`GST_VA_ALL_DRIVERS=1` when the VA-API driver is installed, and the GPU variables it was started with (`GALLIUM_DRIVER`,
`MESA_D3D12_DEFAULT_ADAPTER_NAME`, `LIBVA_DRIVER_NAME`). Started with the private GPU
sockets and with the phone's driver installed, it routes applications to the phone's GPU
instead: `VK_ADD_DRIVER_FILES`, `CABOOSE_GFXSTREAM_SOCKET`,
`CABOOSE_GFXSTREAM_SURFACE_SOCKET`, `CABOOSE_GPU_EXECUTOR_SWITCH=1`, `CABOOSE_GPU_ROUTING=1`,
`NODEVICE_SELECT=1`, `CABOOSE_GPU_ON_LOSS=auto`,
and `GSK_RENDERER=vulkan`,
([docs/gpu-live.md](../../docs/gpu-live.md#applications)). It also serves an input method,
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
| `--audio-bitrate BPS` | `128000` | Opus bitrate |
| `--env-file PATH` | | Where to write the application environment once ready |
| `--client-timeout SECS` | `30` | Close a client that has sent nothing for this long; `0` never |
| `--display WxH@HZxS` | `1920x1080@60x1` | The display used before a client connects, when no client has announced displays before (the last announced are kept in `~/.local/state/caboose/<socket>.displays` and used at the next start) |

| Variable | Effect |
| --- | --- |
| `XDG_RUNTIME_DIR` | Required. Holds the Wayland socket and the instance's state directory |
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
  --display 1179x2556@120x3 --server-pid "$(pidof -s caboose-display)"
caboose-display-probe --check --url ws://127.0.0.1:14601/ --token-file /run/caboose/display-token
```

`--url` selects the instance (default `ws://127.0.0.1:14600/`). `--type`, `--click` and
`--touch` send input once a window shows, and `--actions` replays a sequence of keys,
text, taps and clicks (`--window` picks the window, and `close` closes it); `--audio` and
`--wasm` set what the probe announces, and with `--wasm` the report lists the games handed
to it; `--json` prints a machine-readable report; `--check` exits 0 as soon as the server
answers a hello. `caboose-display-probe --help` lists every option.

## Control socket

Each instance listens on `control.sock` in its private directory
(`$XDG_RUNTIME_DIR/caboose-display/<Wayland socket name>/`, mode 0600) and serves only
processes of its own user. It is how the computer's own tools see and drive a seat, Wayland
and X11 windows alike: `windows` (each window's id, kind, title, app id, process, X window
for Xwayland, geometry, root surface and focus, bottom to top), `focus`, `click`, `press`,
`release`, `move`, `scroll`, `key`, `type`, `settle`, `screenshot` and `frames` (the
seat's timeline: each window's commits and sent pictures, and input, in CLOCK_MONOTONIC
microseconds, for [frame lab](../framelab/README.md)). Requests are single
lines and answers single JSON lines (a screenshot's is followed by the PNG); the full list is
in [docs/architecture.md § Displays](../../docs/architecture.md#displays) and the code in
`compositor/src/control.rs`. Its path is in the launch environment as
`CABOOSE_DISPLAY_CONTROL`, and [`guest/computer-use/helpers/seat.py`](../computer-use/helpers/seat.py) is its
client:

```sh
set -a; . /run/caboose/display.env; set +a
/usr/libexec/caboose/seat windows
/usr/libexec/caboose/seat click 640 360
/usr/libexec/caboose/seat key ctrl+s
/usr/libexec/caboose/seat screenshot --out /tmp/seat.png
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
check, and the D-Bus notification endpoints from [guest/notifications](../notifications).
The owner's endpoint records notifications, which reach the phone through the host,
separately from the display protocol. Run `guest/notifications/check-container.sh` to
exercise the endpoints without a VM; `guest/notifications/check.sh` checks a running guest.

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
[docs/input.md](../../docs/input.md#scrolling) gives the distance each client scrolls
for precise and wheel input. Retain
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

Device checks accept `--token-file` and `--display-env` for isolated test instances,
and `--expect-no-devices` verifies the agent seat omits capability and ignores offers.
They reject unknown check names, bound helper processes, and open input/video nodes as
`caboose` to check the owner's actual access before exercising them as root. Containers
support the private microphone only; kernel input, camera and UHID checks require a VM.
