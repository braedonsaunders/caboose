# Caboose architecture

Caboose is your phone's computer: a persistent Linux machine that runs on a server, wakes
when you open the app, parks itself with its memory intact when you leave, and is shared
by you and your agents. On the phone it is not a remote desktop. Each Linux window arrives
as its own native iOS surface.

This document is the contract between the iOS app, the host and the guest. Change it in
the same pull request as any code that changes a contract.

## 1. Overview

Caboose has three components:

| Component | Path | What it is |
| --- | --- | --- |
| The computer | `guest/` | A Debian 13 (amd64) machine, booted as a Cloud Hypervisor microVM or run as a container. It runs Caboose Display, the file service, the agent runner and the integration services. |
| The host | `apps/host/` | `caboose-host`, TypeScript on Node 22. It owns the computer's lifecycle, authenticates clients, relays display streams, and serves the HTTP and WebSocket API and the web console (`apps/web/`). |
| The app | `apps/ios/` | Caboose for iOS and iPadOS (Swift, iOS 26+). It renders each Linux window natively and integrates the computer with Files, Shortcuts, Spotlight, widgets, Live Activities and notifications. |

Each component has its own README with how to build, run and test it.

```
 iPhone / iPad / external display               server (Linux, /dev/kvm or a container GPU)
 ┌──────────────────────────────┐               ┌───────────────────────────────────────────┐
 │ Caboose app (Swift)          │  HTTPS + WSS  │ caboose-host (TypeScript, Node 22)         │
 │  ├ Shell: home, app cards,   │ ────────────▶ │  ├ Owner token auth                        │
 │  │  windows on iPad / TV     │  /v1/*        │  ├ Lifecycle: wake, lease, park, restart   │
 │  ├ CabooseKit                │  /v1/display  │  ├ Display relay: WS ⇄ guest WS (bytes)    │
 │  │  ├ CabooseDisplaySession  │  /v1/control  │  ├ Files relay: HTTP ⇄ guest file service  │
 │  │  ├ VideoToolbox, Metal    │               │  ├ Agents, catalog, media, phone handoff   │
 │  │  └ Touch, trackpad,       │               │  └ APNs: alerts and Live Activities        │
 │  │    keyboard, clipboard    │               │        │ guest agent (exec)                │
 │  ├ Agent space               │               │        │ TCP 14600 / 14601 / 14700         │
 │  └ Files, Shortcuts,         │               │ ┌──────▼───────────────────────────────┐   │
 │    Spotlight, widgets,       │               │ │ The computer (Debian 13)             │   │
 │    Live Activities           │               │ │  ├ caboose-display        :14600     │   │
 └──────────────────────────────┘               │ │  │   owner's display, Xwayland :110  │   │
                                                │ │  ├ caboose-display-agent  :14601     │   │
                                                │ │  │   agent seat, Xwayland :101       │   │
                                                │ │  ├ caboose-files          :14700     │   │
                                                │ │  ├ caboose-agentd (ACP runner)       │   │
                                                │ │  ├ notifications, phone, media       │   │
                                                │ │  └ apps: Chromium, VS Code, terminal,│   │
                                                │ │     LibreOffice, agents, catalog …   │   │
                                                │ └──────────────────────────────────────┘   │
                                                └───────────────────────────────────────────┘
```

Conventions used throughout:

- The computer's user is `caboose` (uid 1000) with home `/home/caboose`. Home-relative
  paths in the API are relative to that directory.
- The host runs guest commands as root over an argument-only channel (the appkit-desk guest
  agent on vsock port 5252 for a microVM, `docker exec` for a container). Anything that acts
  for the owner runs as `caboose` through `runuser`.
- Everything the guest produces (queue files, state files, command output) is untrusted
  input. The host validates it field by field before it reaches a client.

## 2. The computer

### Guest image

The microVM boots a Debian 13 (trixie, amd64) golden image built by `guest/image/`. Each
computer's disk is a reflink copy-on-write clone of the base: it costs no space up front,
and the owner's installs and home persist. A clone is independent of the base once made,
so a new base image reaches new computers only.

The image contains:

- **Applications.** Chromium, Firefox ESR, VS Code, xfce4-terminal, Thunar, Mousepad,
  LibreOffice, Obsidian, Evince, KeePassXC, mpv and other document and media tools;
  developer tools including Git, Neovim, Lazygit, Lazydocker, btop, tmux, mise and modern
  shell tools; Docker; and the Claude Code, Codex, OpenCode and Gemini CLIs, with desktop
  launchers for terminal tools and agents. Mesa provides software Vulkan and OpenGL when the
  computer has no GPU. Fonts are Inter, JetBrains Mono and Noto (including CJK and colour
  emoji). Optional applications come from the catalog (below).
- **Caboose Display.** `caboose-display` and its units, installed but not enabled. The
  host starts them (see [Displays](#displays)).
- **Codec passthrough.** The VA-API driver `caboose_drv_video.so` from `guest/vaapi`, and
  `/dev/udmabuf` for its decode surfaces ([codec-passthrough.md](codec-passthrough.md)).
- **Agent runner.** `caboose-agentd` at `/opt/caboose/agentd` (Node with the pinned ACP
  TypeScript SDK), `uv` for agents published as Python packages, and the desktop tools
  (`/opt/caboose/desktop-mcp.mjs`, `/opt/caboose/a11y.py`). See [Agents](#5-agents).
- **Services.** The file service, the notification monitor and endpoints, phone handoff
  (`caboose-open`, `caboose-share`, an `iPhone` print queue) and media handoff.
- **Guest agent.** The appkit-desk guest agent (vsock 5252), which runs as root with
  root's home.

`/home/caboose/.cache` is a 512 MiB tmpfs in the microVM, so the queues under
`~/.cache/caboose` do not survive a cold boot.

### Published images

A `v*` tag publishes the computer to GHCR in two forms (`.github/workflows/release.yml`):
`caboose-computer`, the container image, and `caboose-base`, an OCI artifact whose three
layers are titled `base.raw.zst` (the zstd-compressed disk), `vmlinux` and `initrd`. The
release's `caboose-host` image sets `CABOOSE_BASE_IMAGE` and `CABOOSE_CONTAINER_IMAGE` to
both, pinned by digest.

On start, a microVM host whose disk root lacks any of the three files fetches them from
`CABOOSE_BASE_IMAGE` with an anonymous registry pull. Every blob, and a manifest that is
pinned by digest, is verified against its SHA-256 digest while it streams; the disk is
decompressed and written sparse, through a `.part` file renamed only after verification.
Files already present are never fetched. A container host pulls `CABOOSE_CONTAINER_IMAGE`
when Docker lacks it and the reference names a registry. Neither runtime ever replaces an
image that is present, so a host moves to a new image only when its operator changes the
reference and removes the old files.

While the image is being fetched, `POST /v1/session` (and anything that wakes) answers 409
with its progress ("Downloading the computer's image (42%)"). A failed fetch puts the
computer in `error` with the reason in `lastError`, and the next wake retries it.

### Guest components

Caboose's own guest plumbing (the file service, the notification monitor and endpoints, and
phone handoff) is a bundle listed in `guest/components/manifest.json` and installed by
`guest/components/install.sh`. Both image builders run the installer, and the host runs the
same installer to update computers whose disks predate the host:

- After each wake, once the owner's display is ready, the host hashes the bundled files in
  manifest order and compares the hash with `/usr/local/share/caboose/components.version`
  in the guest. On a mismatch it runs the installer as root over the guest channel (`vm` or
  `container` mode). The installer adds only missing Debian packages, never touches the
  owner's home, is safe to repeat, and writes the marker only after it succeeds.
- The update runs in the background and does not block the display. While it runs it holds
  a lease, and park or restart is rejected with 409. A failure is retried on the next wake.
- `GET /v1/computer` reports `upgrade: null | { state, version?, message? }`, and
  `/v1/control` sends `computer.upgrade` with `state` `checking`, `updating`, `succeeded` or
  `failed`.
- A container created without the port 14700 mapping cannot reach the file service; the
  management status warns that it must be recreated (keep its home volume).

The bundle does not include Caboose Display or its units, which come with the image.

### Runtimes

The computer runs as a **microVM** by default: Cloud Hypervisor through appkit-desk, with
the image files `base.raw`, `vmlinux` and `initrd` in `CABOOSE_IMAGE_ROOT`, its overlay at
`overlays/owner.raw` and its memory snapshot at `overlays/owner.snapshot`.

Where a GPU can reach a container but not a VM, `CABOOSE_RUNTIME=container` runs the
computer as a Docker container built from `guest/container/` (`caboose-computer:latest` by
default) instead. The container gets the GPU named by `CABOOSE_GPU`, detected from the
host's devices when unset or `auto`:

| `CABOOSE_GPU` | Detected by | Host | Container gets | Rendering / encode |
| --- | --- | --- | --- | --- |
| `wsl` | `/dev/dxg` | Windows + WSL2, any vendor | `/dev/dxg`, `/usr/lib/wsl` (read-only) | Mesa D3D12; NVENC on NVIDIA |
| `nvidia` | `/dev/nvidiactl` or `/dev/nvidia0` | Linux + NVIDIA container toolkit | `--gpus all`, `/dev/udmabuf` when present | GL + NVENC |
| `dri` | `/dev/dri/renderD128` | Linux, Intel or AMD | `/dev/dri`, `/dev/udmabuf` when present | Mesa + VA-API |
| `none` | otherwise | any | nothing | CPU |

The container is created with `--init`, `--restart no`, `--shm-size 2g`, the computer's
memory and CPU limits, DNS `1.1.1.1` and `9.9.9.9`, its home at `/home/caboose` from
`CABOOSE_CONTAINER_HOME` (a named volume or an absolute host path, `caboose-home` by
default), and any extra `CABOOSE_CONTAINER_ARGS`. It publishes ports 14600, 14601 and
14700 on `127.0.0.1` only. Its session script provides:

```
caboose-session start        # CUPS and the print queue, the owner's session bus,
                             # notification monitor and endpoint, and the owner's display
caboose-session ready        # wait for the owner's display, then its accessibility bus
caboose-session start-agent  # the agent seat: its bus, endpoint, display and accessibility bus
caboose-session start-files  # the file service on 14700
```

| | microVM | Container |
| --- | --- | --- |
| Park | Memory snapshot to disk (`parkWithMemory`) | `docker pause` (cgroup freezer); memory stays in RAM |
| Wake | Restore from the snapshot | `docker unpause`, or `docker start` / `docker run` |
| Survives a host or Docker restart | Yes: the snapshot resumes | No: the next wake boots fresh with the home intact |
| Installed packages | In the disk overlay | In the container's writable layer, kept across a Caboose restart |
| Restart | Shut down, drop the snapshot, cold boot | `docker stop`, `docker update` with the new limits, start |
| Isolation | Virtual machine | Container |

The microVM is the default because it isolates the computer as a VM and its parked state
survives host restarts.

### Network fencing

A microVM's network is a persistent TAP device, `caboose0`. The host is `192.0.2.1/30`
and the guest `192.0.2.2/30`, with NAT to the host's other interfaces and DNS `1.1.1.1`. At
each wake the host also sets the guest's clock over the guest agent.

The guest is fenced in chains the host owns, each jumped to first from its built-in chain:

| Chain | Hook | Rules |
| --- | --- | --- |
| `CABOOSE-IN` | `INPUT -i caboose0` | Established and related traffic returns; everything else is dropped. The guest can open nothing on the host. |
| `CABOOSE-FWD` | `FORWARD -i caboose0` | Established and related traffic returns; new connections to private and reserved ranges are rejected; the rest returns to normal forwarding. |

The rejected ranges are `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`,
`169.254.0.0/16` (link-local and cloud metadata), `100.64.0.0/10` (CGNAT and Tailscale),
`127.0.0.0/8`, `0.0.0.0/8`, `192.0.0.0/24`, `198.18.0.0/15`, `224.0.0.0/4` and
`240.0.0.0/4`. `CABOOSE_GUEST_LAN=allow` removes them, so the guest can reach the local
network. The host opens the relay connections to the guest itself.

A container computer gets the same fence on its own Docker bridge network, `caboose`
(interface `caboose-br0`): `CABOOSE-CIN` from `INPUT` and `CABOOSE-CFWD` from
`DOCKER-USER`, which Docker never rewrites.

### Displays

Two Caboose Display instances run in the computer, both as `caboose`:

| | Owner's display | Agent seat |
| --- | --- | --- |
| Unit (microVM) | `caboose-display.service` | `caboose-display-agent.service` |
| WebSocket | `0.0.0.0:14600` | `0.0.0.0:14601` |
| Wayland socket | `wayland-caboose-0` | `wayland-caboose-agent` |
| Xwayland | `:110` | `:101` |
| Applications | Wayland first, X11 through Xwayland as a fallback | The same |
| Sound | Its own PulseAudio, sent as Opus | None (`--no-audio`) |
| Session bus | `/run/user/1000/bus` | `/run/user/1000/agent-bus` |
| Notification endpoint | `caboose-notification-daemon.service` | `caboose-agent-notification-daemon.service` |
| Launch environment | `/run/caboose/display.env` | `/run/caboose/agent-display.env` |
| Started | At every wake | On demand: by an agent task, or by a client opening `/v1/display?seat=agent` |

Each instance writes its launch environment once it is ready: `WAYLAND_DISPLAY`,
`DISPLAY`, `XAUTHORITY`, toolkit backends (`GDK_BACKEND`, `QT_QPA_PLATFORM`,
`MOZ_ENABLE_WAYLAND`, `SDL_VIDEODRIVER`, `ELECTRON_OZONE_PLATFORM_HINT`),
`CABOOSE_DISPLAY_CONTROL` (its control socket, below), plus `LIBVA_DRIVER_NAME=caboose` when
the passthrough driver is installed. Each keeps its X authority, Xwayland shim, PulseAudio
socket and control socket under `$XDG_RUNTIME_DIR/caboose-display/<wayland socket name>/`.
The units set `ACCESSIBILITY_ENABLED=1`, `GNOME_ACCESSIBILITY=1` and
`QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1`, and start the seat's AT-SPI bus (`a11y.py bus`) before
any application: the accessibility bus of the seat's session bus, with its socket named
after the seat's X display and published as `AT_SPI_BUS` on its Xwayland, so Wayland and
X11 applications on a seat share one bus and the two seats never share one.

**Control socket.** Each instance serves `control.sock` (mode 0600, only to processes of
its own user) for the computer's own tools: the screen routes and the agents' desktop tools
see and drive a seat through it, Wayland and X11 windows alike. One request per line, one
JSON answer per line; positions are in the compositor's logical space, which X11 clients
also see as their root window's.

| Request | Answer |
| --- | --- |
| `windows` | `{ windows: [{ id, parent, kind, title, app_id, pid, x11, rect: [x, y, w, h], surface: [x, y, w, h], display, scale, focused }], focused, bounds }`, bottom to top. `x11` is the X window of an Xwayland window, else null; `surface` is the root surface, client-side shadows included |
| `focus ID` | Gives the window the keyboard |
| `click X Y [BUTTON [COUNT]]`, `press X Y [BUTTON]`, `release X Y [BUTTON]`, `move X Y` | The seat's pointer, delivered to the topmost window at that position |
| `scroll X Y DX DY` | Wheel clicks at that position |
| `key COMBO…` | Key combinations to the keyboard's window (`ctrl+s`, `alt+F4`, `Return`) |
| `type TEXT` | Text to the keyboard's window, through text-input-v3 where the application has it, else as key presses; `\n`, `\t` and `\\` are escapes |
| `settle` | Releases pending frame callbacks, so applications on a seat nobody watches draw now |
| `screenshot [ID]` | `{ png: N, rect }` followed by N bytes: one window, or every window composed over the displays |

`guest/desktop-mcp/seat.py` is its client, as a library and a command.

Each instance serves one client at a time; a new authenticated client replaces the
previous one. Its readiness probe is:

```
caboose-display-ready [TIMEOUT] [PORT]   # default 60 s, port 14600
```

It exits 0 once the instance on `PORT` answers a hello made with the current display
token. The host starts the owner's display with
`systemctl start caboose-display.service && caboose-display-ready 60 14600` (microVM) or
`caboose-session start` and `ready` (container), then reads `/run/caboose/display.env`. A
wake fails if the display writes no launch environment.

### Display token

The host generates a display token of 32 random bytes (64 hex characters) and writes it,
without a trailing newline, to `/run/caboose/display-token`, owned by `caboose` with mode
0600. A microVM gets a new token at every boot or resume. A container gets one the first
time the host wakes it after the host starts, and again after each restart.

Both display instances re-read the file on every hello, and the file service reads it on
every request. The token reaches the app only inside the authenticated `/v1/session`
response; the host relays display bytes without inspecting them.

### Guest services

**File service.** `guest/files/caboose-files.py` (`/opt/caboose/files/`,
`caboose-files.service`) runs as `caboose` on TCP 14700 and requires
`Authorization: Bearer <display token>` on every request. The host starts it at each wake
before the owner's display, and waits up to 60 s for it to listen; a computer without the
service still wakes. The protocol is in [Files](#files).

**Notifications.** `caboose-notifications.service` runs `monitor.py`, which observes
`org.freedesktop.Notifications.Notify` calls on the owner's session bus and writes each as a
private record in `/home/caboose/.cache/caboose/notifications/<uuid>.json`:
`{ id, app, summary, body, created }`, with `app` at most 200 characters, `summary` 500,
`body` 1000 and `created` in Unix seconds. It keeps the newest 100 records. `daemon.py`
owns the notification name on each seat's bus. The agent seat has its own bus, so its
notifications never enter the owner's queue.

**Phone handoff.** `guest/phone` installs `caboose-open URL` and `caboose-share FILE...`,
registers `caboose-phone.desktop` as the handler for the `mailto`, `tel`, `sms`, `facetime`,
`facetime-audio`, `maps` and `geo` schemes (the default web browser is unchanged; explicit
`http(s)` links are accepted too), adds **Share to iPhone** to Thunar, and configures an
`iPhone` CUPS queue that converts print jobs to PDF and hands them off the same way.
Requests are queued in `/home/caboose/.cache/caboose/phone/queue` and files are snapshotted
in `phone/files/<id>`, private to the owner. Files are limited to 10 MiB, the queue to 100
pending requests, and both expire after 24 hours. See [Phone handoff](#phone-handoff).

**Media handoff.** `guest/media-handoff` installs a Chromium extension, ID
`cklinclacpchpdgickgonlhnldfmkhbh` (fixed by the public key in its manifest), and its native
messaging host `com.caboose.media`. See [Media handoff](#media-handoff).

### Catalog

`guest/catalog/catalog.json` is the source of optional applications, packs and release
pins. Debian applications install from Debian 13's signed repositories. Craft releases have
fixed URLs, byte counts and SHA-256 hashes. No pin changes automatically; a changed pin
makes an update available for the owner to choose.

The host runs the installer (`guest-catalog.py`) as root through the guest channel on both
runtimes. Downloads go directly from the guest, are size- and SHA-256-checked before APT
installs them, and are kept in `/var/lib/caboose/catalog` for rollback. Release installs
also install `mesa-vulkan-drivers` and `libgl1-mesa-dri`. Debian applications cannot be
rolled back. Installed versions come from dpkg; failures and interrupted operations are
recorded in the guest and reported on the next listing.

Only one catalog operation runs at a time, and it holds a computer lease. A second
operation, a park, a restart or a Craft job receives 409 while one runs. A pack installs
its entries in order and continues past individual failures. The listing reports the last
observed state while the computer is parked and never wakes it. `/v1/apps` discovers
installed desktop entries independently.

Craft applications (`ai.storyteller.<name>.desktop`) are launched on the owner display's
Xwayland, with `WAYLAND_DISPLAY` removed and `GDK_BACKEND`, `WINIT_UNIX_BACKEND` and
`XDG_SESSION_TYPE` set to X11.

## 3. Host

`caboose-host` is TypeScript on Node 22, built on `@braedonsaunders/appkit-desk`. It owns no
display logic: display streams are relayed, not parsed.

### Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `CABOOSE_OWNER_TOKEN` | generated | The owner's bearer token; unset, the host generates one into `${CABOOSE_IMAGE_ROOT}/owner-token` (mode 0600) on first start and reuses it |
| `CABOOSE_BIND` | `127.0.0.1` | Listen address |
| `CABOOSE_PORT` | `7310` | Listen port |
| `CABOOSE_IMAGE_ROOT` | `/var/lib/caboose` | Golden image, overlays, snapshot and host state |
| `CABOOSE_MEMORY_MB` | `6144` | Initial memory setting |
| `CABOOSE_VCPUS` | `4` | Initial vCPU setting |
| `CABOOSE_IDLE_MS` | `600000` | Initial idle time before parking |
| `CABOOSE_VMM_PATH` | `/usr/local/bin/cloud-hypervisor` | Cloud Hypervisor binary |
| `CABOOSE_RUNTIME` | `microvm` | `microvm` or `container` |
| `CABOOSE_GPU` | `auto` | Container GPU: `auto`, `wsl`, `nvidia`, `dri` or `none` |
| `CABOOSE_BASE_IMAGE` | unset (release: pinned) | OCI reference of the microVM image, fetched when the disk root lacks it ([Published images](#published-images)) |
| `CABOOSE_CONTAINER_IMAGE` | `caboose-computer:latest` (release: pinned) | Container image; pulled when missing if it names a registry |
| `CABOOSE_CONTAINER_NAME` | `caboose-owner` | Container name |
| `CABOOSE_CONTAINER_HOME` | `caboose-home` | Volume or absolute host path for `/home/caboose` |
| `CABOOSE_CONTAINER_ARGS` | empty | Extra `docker run` arguments, whitespace-separated |
| `CABOOSE_GUEST_LAN` | `deny` | `allow` lets the guest reach private ranges |
| `CABOOSE_AGENT_REGISTRY_URL` | the public ACP registry | `http(s)` URL of `registry.json` |
| `CABOOSE_AGENT_IDLE_MS` | `600000` | How long a runner keeps its agent after a turn |
| `CABOOSE_WEB_ROOT` | `apps/web/dist` | The built web console |
| `CABOOSE_APNS_KEY_PATH`, `_KEY_ID`, `_TEAM_ID`, `_TOPIC` | unset | APNs provider; all four or none |

Host state lives in `CABOOSE_IMAGE_ROOT`: `owner-token` when generated, `caboose.json` (computer settings),
`push-devices.json`, `activities.json` and `agent-registry.json`, each replaced atomically
with mode 0600, and `overlays/owner.resources.json`, the resources the microVM was booted
with.

### Lifecycle

The computer has one state: `parked`, `waking`, `running`, `parking`, `restarting` or
`error`. Wake, park and restart are serialized, so none can race another or a launch.

- **Wake** (`POST /v1/session`, and routes that wake on demand) starts or restores the
  computer, configures its network and clock, writes the display token, starts the file
  service, starts the owner's display and reads its launch environment. A microVM whose
  snapshot cannot be restored is reported as an error rather than cold-booted.
- **Leases.** Each open display or control WebSocket holds a lease, as do running agent
  tasks, catalog operations, Craft jobs, agent installs and sign-ins, and each `/v1/fs`
  request until its response completes. With no lease, the computer parks after the
  `idleMs` setting. HTTP polling of `/v1/computer` holds no lease, so leaving the web
  console open does not keep the computer awake.
- **Park** keeps memory, so every application is where it was on resume. An explicit park
  closes all client sockets first and ignores leases.
- **Restart** is a cold boot that keeps the disk and discards memory. It first tries a 5 s
  disk flush. If the guest does not answer, the confirmed restart proceeds and
  `lastError` carries a warning even when the new boot succeeds. It closes client sockets,
  fails running and paused agent tasks with "Stopped when the computer restarted.", and
  never deletes the computer's disk.

While running, the microVM's appkit-desk lease is renewed every 20 s.

### Authentication

Every `/v1` route and WebSocket upgrade requires `Authorization: Bearer <owner token>`; the
host compares SHA-256 digests of the candidate and the token in constant time. Requests
without it get 401. Every route is scoped to the authenticated principal's computer.

The built web console is served from `CABOOSE_WEB_ROOT` with an SPA fallback for non-API
`GET`s. Static files are public. The console keeps the owner token in session storage and
sends it only as an `Authorization` header.

### Conventions

Request and response bodies are JSON unless stated. A JSON body must be an object of at
most 64 KiB (15 MiB for `POST /v1/agent/tasks`). Errors are `{ error: string }`:

| Status | Meaning |
| --- | --- |
| 400 | Invalid input, including unknown fields where a route rejects them |
| 401 | Missing or wrong owner token |
| 404 | Unknown route, task, agent, element or device |
| 409 | The computer is not running (or is restarting), its display is not ready, or a conflicting operation is in progress |
| 502 | The guest or the agent registry failed an operation; the message says why |
| 503 | Push or Live Activities are not configured |

Routes marked **wakes** start or resume a parked computer. Other routes that need the
guest answer 409 while it is not running.

### Session and display

| Method | Path | Purpose |
| --- | --- | --- |
| `POST` | `/v1/session` | **Wakes.** → `{ state: "running", display: { path: "/v1/display", token, protocol: "caboose-display" }, computer: { name, image, memoryMb, vcpus } }`. `image` is `"Debian 13"`, or `"Debian 13 · GPU"` for a container with a GPU |
| `POST` | `/v1/session/park` | Park now → `{ state }`. 409 while a catalog operation or Craft job runs |
| `GET` | `/v1/display` | **WebSocket**, subprotocol `binary` (required). Relay to the owner's display, port 14600 |
| `GET` | `/v1/display?seat=agent` | **WebSocket**, subprotocol `binary`. Starts the agent seat if needed, then relays to port 14601; closes with 1011 `agent seat unavailable` if it does not start |
| `GET` | `/v1/control` | **WebSocket.** JSON events (below). `?foreground=1` marks the app's foreground connection; `?phone=1` subscribes to phone handoff events |
| `GET` | `/v1/apps` | Launchable applications from the guest's desktop entries: `[{ id, name, icon (PNG data URL), categories, exec }]` |
| `POST` | `/v1/apps/:id/launch` | Start a desktop entry on the owner's display with its launch environment → `{ launched: true }` |
| `POST` | `/v1/open` | `{ url }` → `{ opened: true }`. Open an `http(s)` URL (at most 8192 characters, no spaces or control characters) with the default handler on the owner's display |
| `GET` | `/v1/health` | microVM: `{ host, kvm, desk, machine }` with appkit-desk's stats; container: `{ host, runtime: "container", gpu, container, running, machine }`; both add `image`. `machine` is `{ memoryMb, availableMemoryMb, cpus, disk: { totalBytes, freeBytes } \| null }`: the machine the computers share, with `disk` the volume holding `CABOOSE_IMAGE_ROOT` (null when it cannot be read). `image` is `{ state: "ready" \| "fetching" \| "failed" \| "missing", reference: string \| null, receivedBytes?, totalBytes?, message? }`: the computer's image ([Published images](#published-images)); `missing` means no reference to fetch from |
| `GET` | `/v1/host` | How the host was started (below) |

A WebSocket upgrade answers 401 without the owner token, 404 for another path, 409 unless
the computer is running and not restarting, and 400 for `/v1/display` without the `binary`
subprotocol. Upgrades do not wake the computer; a client calls `/v1/session` first.

### The display relay

The relay is a byte pipe between a client WebSocket and a guest WebSocket. It accepts only
binary messages (a text message closes the socket with 1003), allows payloads up to
16 MiB, gives the guest connection 10 s to open, and applies backpressure in both
directions: each side is paused until the other has flushed. When either side closes, so
does the other. Each client connection gets its own guest connection.

### Control socket events

On connect the host sends `computer.state`, then `computer.settings`, then
`media.playing` if a video is being offered. Afterwards it broadcasts:

| Event | Payload | When |
| --- | --- | --- |
| `computer.state` | `{ state }` | Every lifecycle transition |
| `computer.settings` | `{ computer: <management status> }` | Settings or their applied state change |
| `computer.upgrade` | `{ upgrade: { state, version?, message? } }` | A guest component update starts, finishes or fails (see [Guest components](#guest-components)) |
| `notification` | `{ id, app, summary, body, created }` | A desktop notification on the owner's display |
| `fs.changed` | `{ anchor }` | The home changed (see [Files](#files)) |
| `catalog.progress` | `{ id, operation, phase, message?, stage?, value? }` | A catalog operation is `queued`, `installing`, `finished` or `failed`; `stage` and `value` (0–1 or null) report download progress |
| `catalog.changed` | `{ id? }` | After each application in an operation, and once when the operation ends |
| `job.progress` | `{ job: { id, kind, title, status, detail } }` | A Craft job starts, succeeds or fails |
| `agent.task.*` | see [Agents](#tasks) | Agent task activity |
| `media.playing`, `media.stopped` | see [Media handoff](#media-handoff) | |
| `phone.open`, `phone.share`, `phone.print` | see [Phone handoff](#phone-handoff) | Only to sockets opened with `?phone=1` |

### Management

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/v1/computer` | Management status and settings. Never wakes or leases |
| `PATCH` | `/v1/computer/settings` | Update any of `name`, `memoryMb`, `vcpus`, `idleMs`, `defaultAgent` → management status |
| `POST` | `/v1/computer/restart` | `{ "confirm": true }` (required) → management status after the computer and owner's display are ready again |

Management status:

```ts
{
  state: "parked" | "waking" | "running" | "parking" | "restarting" | "error",
  settings: { name: string, memoryMb: number, vcpus: number, idleMs: number, defaultAgent: string | null },
  limits: { memoryMb: { min: 512, max: 65536 }, vcpus: { min: 1, max: 32 }, idleMs: { min: 60000, max: 86400000 } },
  activeResources: { memoryMb: number, vcpus: number } | null,
  restartRequired: boolean,
  clients: { display: number, control: number },
  tasks: { running: number, paused: number },
  capabilities: { restart: boolean, push: boolean },
  lastError: string | null
}
```

- `name` is 1–80 characters without control characters, trimmed on save. Numeric settings
  are integers within `limits`. `defaultAgent` is null or the id of an agent in the
  registry or installed in the computer; the first agent install sets it when it is null.
- Unknown fields or invalid values return 400 and change nothing. Settings are written to
  `caboose.json` before they take effect; the `CABOOSE_*` values are only the initial
  defaults.
- Name and idle changes apply at once. Memory and vCPU changes apply at the next cold boot,
  not at a resume from a snapshot. `activeResources` describes the running or parked
  computer, or is null before its configuration is known. `restartRequired` is true when
  the computer has saved state and its active resources differ from the settings.
- Restart answers 400 without `confirm: true`, 409 while another restart, a catalog
  operation or a Craft job is in progress. Clients confirm with the owner before sending
  it and allow 300 seconds for the response. Lifecycle failures are reported in
  `lastError`.

`GET /v1/host` returns `{ version, node, runtime, gpu, image, push, liveActivities,
settings }`: the host package and Node versions, `"microvm"` or `"container"`, the
container's GPU kind (null for a microVM), the container image or the golden image path,
whether APNs and Live Activities are configured, and `settings: [{ name, value, default }]`
for the non-secret `CABOOSE_*` variables read at startup (container-only variables appear
only for a container). It never includes the owner token, APNs credentials, extra
container arguments or URL credentials. The values are fixed until the host restarts.

### Files

The `/v1/fs` routes relay to the guest file service without buffering a whole file. Each
**wakes** the computer and holds a lease until its response completes. The host forwards
the `Content-Type`, `Content-Length`, `Range`, `If-Match` and `If-None-Match` request
headers and the `Content-Type`, `Content-Length`, `Content-Range`, `Accept-Ranges` and
`ETag` response headers.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/v1/fs/list?path=…` | List a directory → `{ items: [<item>] }` |
| `GET` | `/v1/fs/stat?path=…` | One item → `<item>` |
| `GET` | `/v1/fs/content?path=…` | Stream a file; one `Range: bytes=…` range, suffix ranges included |
| `PUT` | `/v1/fs/content?path=…` | Stream a file in (known length or chunked) |
| `POST` | `/v1/fs/mkdir?path=…` | Create a directory → 201 |
| `POST` | `/v1/fs/move?path=…` | `{ destination }`: move or rename |
| `DELETE` | `/v1/fs/item?path=…` | Move an item to the freedesktop home Trash |
| `GET` | `/v1/fs/changes?anchor=…` | The change journal since `anchor` |
| `POST` | `/v1/fs/open` | **Wakes.** `{ path, app? }` → `{ opened: true }`: open a home-relative item on the owner's display, with its default handler or with the desktop entry `app` (`*.desktop`) |
| `POST` | `/v1/files` | **Wakes.** `{ name, data (base64), open? }` → `{ path }`: save into `~/Downloads` under a unique name (`name (2).ext`, …) and optionally open it |

- `path` and `destination` are relative to `/home/caboose`; the empty path is the home.
  Absolute paths, `.` and `..` components, NULs, symlinks and special files are rejected,
  and each directory is opened without following symlinks. Names beginning
  `.caboose-upload-` are reserved for uploads in progress and never listed.
- An item is `{ name, kind: "file" | "directory", size, mtime, etag, contentType,
  identity }`. `mtime` is Unix milliseconds. `etag` is opaque and quoted, and changes when
  the file is modified or replaced. `identity` identifies the inode (`<dev>:<ino>`), which
  lets a client reconcile a rename; hard links share it.
- `GET content` answers 206 with `Content-Range` for a range, or 416 when the range cannot
  be satisfied.
- `PUT content` writes to a temporary file and moves it into place. `If-None-Match: *`
  creates (412 if the file exists); `If-Match: <etag>` replaces (412 on a version
  mismatch); a replacement without a precondition answers 428. The version check happens
  immediately before the move, but Linux applications do not take the service's lock, so
  it is not atomic with a concurrent direct write.
- `move` and `item` accept an optional `If-Match`. `move` refuses an existing destination
  (409). A move to Trash across filesystems can fail; it never deletes permanently.
- `changes` returns `{ anchor, changed, reset, events: [{ path, removed, cookie }] }`.
  Anchors are opaque and scoped to one run of the service. The journal holds at most
  10000 events. A missing, expired, overflowed or previous-run anchor answers
  `reset: true`, and the client re-enumerates. Rename events carry the inotify `cookie`
  that pairs the old and new path.
- While the computer runs and at least one control socket is connected, the host polls the
  journal every second and broadcasts `fs.changed { anchor }` when something changed.
- `POST /v1/files` holds the whole body in memory; new clients use `PUT /v1/fs/content`.
  `POST /v1/fs/open` checks the path through the file service (its status is returned on
  failure) before opening it.

### Catalog routes

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/v1/catalog` | `{ packs, apps }`: each catalog entry with `installedVersion`, `canRollback`, `lastError`, `interrupted`, `iconData`, `pinnedVersion`, `updateAvailable` and `progress` |
| `POST` | `/v1/catalog/:id/install`, `/update`, `/rollback` | Queue an operation → 202 `{ accepted: true }` |
| `DELETE` | `/v1/catalog/:id` | Queue removal → 202 |
| `POST` | `/v1/catalog/packs/:id/install` | Queue every application in a pack → 202 |
| `POST` | `/v1/catalog/:id/run` | **Wakes.** Run a Craft job (below) |

Catalog mutations answer 409 while the computer is not running, another catalog operation
runs, or a Craft job runs; 404 for an unknown application or pack.

**Craft jobs.** A client stages inputs under `.caboose-jobs/<job>/` through `/v1/fs`, where
`job` is 32 lowercase hex digits and inputs are named `input-0.<ext>`, `input-1.<ext>`, ….
It then sends `{ job, inputs, format }` to `POST /v1/catalog/:id/run`. Only these fixed
operations exist:

| `:id` | Operation | Inputs | `format` | Outputs |
| --- | --- | --- | --- | --- |
| `photocraft` | `photocraft-cli convert` | 1–20 images | `png`, `jpg`, `tif`, `webp` | One per input |
| `pdfcraft` | `pdfcraft-cli combine` | 2–20 PDFs | `pdf` | One |
| `lightcraft` | `lightcraft-cli render` | One photo | `jpg`, `png`, `tif`, `webp` | One |
| `filmcraft` | `filmcraft-cli --project … export` | One `.fcproj` | `mp4`, `mov` | One |

The application must be installed (404 otherwise). The host runs a fixed argument vector as
`caboose` in the job directory, holds a lease, and answers `{ job, outputs, warnings }`:
outputs are home-relative paths `.caboose-jobs/<job>/output-<n>.<format>`, and warnings are
the CLI's output tails (at most 20 of 1000 characters). A job may run for 57.5 minutes; on
timeout the guest kills its process group. A job id that is already running, or a catalog
operation in progress, answers 409; a failed CLI answers 502 with its output. The host
broadcasts `job.progress` with `kind: "craft"` on start and on success or failure, and
publishes the same job to Live Activities. A FilmCraft project's media must be at its
original paths in the computer; the CLI reports offline media as a failure. The operations
follow the pinned releases' CLIs:
[PhotoCraft v0.16.0](https://github.com/storytold/photocraft/blob/v0.16.0/book/src/automation/cli.md),
[PDFCraft v0.14.0](https://github.com/storytold/pdfcraft/blob/v0.14.0/apps/pdfcraft-cli/src/main.rs),
[LightCraft v0.14.0](https://github.com/storytold/lightcraft/blob/v0.14.0/apps/lightcraft-cli/src/main.rs) and
[FilmCraft v0.13.0](https://github.com/storytold/filmcraft/blob/v0.13.0/docs/agents.md).

### Screen

The owner's display can be read and acted on through its accessibility tree, so a client
(such as the phone's on-device model) can work with what the owner sees
without pixels:

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/v1/screen/elements` | `{ window: { title, app }, elements: [{ id, role, name, states, bounds: { x, y, width, height } }], note? }`: the focused window's visible controls, at most 200; `note` says why the list is empty |
| `POST` | `/v1/screen/act` | `{ element, action: "press" \| "focus" \| "set-text", text? }` → `{ ok: true }`; 404 when the element is gone. `text` is at most 10000 characters |
| `POST` | `/v1/screen/type` | `{ text }` (1–10000 characters) → `{ ok: true }`: type into the focused window |
| `POST` | `/v1/screen/keys` | `{ keys }` → `{ ok: true }`: up to 10 space-separated combinations such as `ctrl+s` or `ctrl+shift+t Return`; common names (`enter`, `esc`, `cmd`, `pageup`, …) map to keysym names |

Element ids are opaque and valid until the window changes. Bounds are in the seat's logical
coordinates. The routes run `/opt/caboose/a11y.py` and `/opt/caboose/seat.py` as `caboose`
with the owner display's launch environment. They take the windows, the focused one and
each window's process from the seat's [control socket](#displays), read Wayland and X11
applications alike through AT-SPI, and type and press keys with the seat's own keyboard.
The helper reads only an application whose windows are all on the requested seat, so the
agent seat never reads or presses the owner's windows, and the reverse.

### Phone handoff

The host drains the guest's phone queue (`caboose-phone drain`, at most 50 events) every
second while the computer is running and at least one control socket opened with
`?phone=1` is connected. It validates each event and sends it to those sockets:

- `phone.open { url }`: a URL of at most 8192 characters with no spaces or control
  characters, in one of the schemes `http`, `https`, `mailto`, `tel`, `sms`, `facetime`,
  `facetime-audio`, `maps`, `geo`.
- `phone.share` and `phone.print`: `{ id, path, name, size, contentType }`. `id` is 32
  lowercase hex digits and `path` must be exactly
  `/home/caboose/.cache/caboose/phone/files/<id>`. `name` is 1–200 characters without
  separators or control characters, `size` at most 10 MiB, and `contentType` a MIME type.
  Print content is `application/pdf`.

Delivery is at most once: events drained while no phone socket can receive them are not
replayed. The owner token scopes the connection to the owner's computer.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/v1/phone/files/:id` | `{ data: base64 }`: the staged file, read in 48 KiB chunks through the guest channel. Never takes a guest-supplied path and never wakes the computer |

### Media handoff

The extension watches every `<video>` in every http(s) page and frame and offers the most
recently started playing video (or, if none plays, the most recently started one). The
native host keeps `/home/caboose/.cache/caboose/media.json` equal to it (atomically
replaced, removed when nothing is offered or the browser closes), records its pid in
`media-host.pid`, and applies commands from `media-command.json`.

| Offered as | When | Played on the phone from |
| --- | --- | --- |
| `kind: "hls"`, `src` | `currentSrc` is http(s) and its path ends in `.m3u8` | `src`, natively |
| `kind: "video"`, `src` | any other http(s) `currentSrc` | `src`, natively |
| `kind: "page"` | `currentSrc` is a `blob:` the page assembled (MediaSource) | the page, in the phone's browser; the position does not carry over |

Not offered: DRM (EME) playback, `data:` and MediaStream sources (calls, cameras), muted
looping videos (page decoration), videos inside shadow roots, and other browsers. `src` is
the page's own URL for the media; cookies, headers and short-lived signed URLs may not work
off the computer, which the phone reports as a playback failure.

The media state, in the guest file and as the host sends it:

```ts
{
  id: string,              // /^[A-Za-z0-9._-]{1,64}$/, "<tab>.<frame>.<nonce>-<n>"; stable for one
                           // tab, frame, element and source; a new source is a new id
  page: string,            // the tab's http(s) URL
  title: string,           // media session title, else the document or tab title; "" if none
  src?: string,            // http(s) only, never blob:; present for "hls" and "video", absent for "page"
  kind: "page" | "hls" | "video",
  position: number,        // seconds
  duration: number | null, // seconds; null for live or not yet known
  paused: boolean,
  updatedAt: number        // ms since the epoch: when `position` holds (see below)
}
```

The extension reports on `play`, `playing`, `pause`, `seeked`, `ended` and `emptied`, and
every 5 seconds while playing. In the guest file `updatedAt` is the guest-clock sample
time. The host reads the file, with the guest's clock so skew does not matter, about once
a second, and only while the computer is running and at least one display client is
connected. Reads go straight to the guest: they never wake the computer, hold a lease or
delay parking. A file whose native host is no longer running is ignored. What the host
sends has `position` extrapolated to the moment it is sent while playing (capped at
`duration`) and `updatedAt` set to that moment on the host's clock.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/v1/media` | `{ media: <state> \| null }`; null unless the computer is running. Never wakes or leases |
| `POST` | `/v1/media/:id/control` | `{ action: "pause" \| "play", position?: number }` → `{ sent: true }` |

Control validates strictly (400): the raw `:id` path segment must match
`/^[A-Za-z0-9._-]{1,64}$/`, the body may contain only `action` and `position`, and
`position` (seconds, 0–10⁷) is allowed only with `play`, which seeks there and plays. A
computer that is not running answers 409; control does not wake it. The host writes
`{ seq, id, action, position? }` to `/home/caboose/.cache/caboose/media-command.json` as
`caboose`, with `seq` increasing and millisecond-based so it keeps increasing across host
restarts. `sent` means the command reached the computer; an id the browser no longer has
is ignored there, and the next state shows the result.

Control-socket events: `media.playing { media }` on every change of the state (including
each 5-second report while playing, and once when polling starts), and
`media.stopped { id }` when that video stops being offered (it ended, its tab closed, the
browser closed, another video replaced it, or the computer stopped running).

The handoff on the phone: on `media.playing`, offer the video; to hand off, play it natively
from `position`, then `POST …/control { action: "pause" }`; when the phone stops,
`POST …/control { action: "play", position: <phone position> }`.

### Desktop notifications

While the computer runs, the host drains the owner's notification queue every second as
`caboose`, reading at most 32 KiB per record and deleting each file it reads. Records with
a malformed field, or created more than 120 seconds from the host's clock, are discarded.
Each valid record is broadcast as `notification` and, when APNs is configured, pushed as a
`desktop` alert. Linux notifications carry no reliable window identifier, so tapping one
opens the app.

### Push notifications

The host has an optional APNs provider, configured with a P-256 `.p8` key path, key ID, team
ID and app topic. Partial or invalid configuration stops the host at startup.
`capabilities.push` in `/v1/computer` reports whether it is configured; without it these
routes answer 503.

| Method | Path | Purpose |
| --- | --- | --- |
| `POST` | `/v1/devices/push` | `{ token, environment: "sandbox" \| "production", kinds }` → `{ registered: true }`. `token` is hex; `kinds` is a subset of `approval`, `task`, `desktop` without duplicates. Registering a token again replaces its settings |
| `GET` | `/v1/devices/push` | `{ devices: [{ id, environment, kinds }] }`. `id` is the first 16 hex digits of the token's SHA-256; tokens are never returned |
| `DELETE` | `/v1/devices/push` | `{ token }` → `{ removed: true }` |
| `DELETE` | `/v1/devices/push/:id` | Remove the registration with that fingerprint → `{ removed: true }`; 404 when none matches |

Alerts are sent only when no control socket opened with `?foreground=1` is connected. The
app opens its foreground control socket with that flag and closes it when it goes to the
background; other control clients do not suppress alerts.

| Kind | Trigger | Alert | Custom keys |
| --- | --- | --- | --- |
| `approval` | `agent.task.approval` | "Approval requested", the request summary; category `AGENT_APPROVAL` | `taskId`, `approvalId` |
| `task` | `agent.task.finished` with `succeeded` or `failed` | "Task finished" or "Task failed", the summary | `taskId` |
| `desktop` | a desktop notification | its summary (or app), its body | none |

Alert bodies are at most 700 characters. Alerts for a task share the thread
`task-<id>`. An APNs 410 `Unregistered` response removes the registration unless it was
registered again while the request was in flight. Provider tokens are refreshed after 50
minutes, and each request times out after 15 s. Delivery is best effort.

### Live Activities

Live Activities use the same APNs configuration and answer 503 without it.

| Method | Path | Purpose |
| --- | --- | --- |
| `POST` | `/v1/activities` | `{ activityId, jobId, token, environment }` → `{ registered: true }`: an ActivityKit update token. The host then sends the job's latest saved state, so a late registration catches up |
| `DELETE` | `/v1/activities` | `{ activityId }` → `{ removed: true }` |
| `POST` | `/v1/activities/start-token` | `{ deviceId, token, environment }` → `{ registered: true }`: a push-to-start token |
| `DELETE` | `/v1/activities/start-token` | `{ deviceId }` → `{ removed: true }` |
| `POST` | `/v1/jobs/activity` | `{ start: boolean, job: { id, kind, title, status, detail } }` → `{ sent: true }`: publish a job's state |

Ids and kinds match `/^[A-Za-z0-9._-]{1,100}$/`; tokens and `deviceId` are hex. `title`
is 1–200 characters and `detail` at most 500. `status` is `running`, `paused`, `succeeded`,
`failed` or `cancelled`; the last three end the activity.

The activity's attributes are `JobAttributes { jobID, kind, title }` and its content state
`{ status, detail }`. The host sends `update` and `end` events (topic
`<topic>.push-type.liveactivity`) to every activity registered for the job; an end sets a
dismissal date one hour later and removes the registration once delivered. A `start`
event goes to every push-to-start token when a job starts while no foreground control
socket is connected. Agent tasks publish themselves (`kind: "agent"`) as they start, reply,
pause, resume and finish; Craft jobs publish with `kind: "craft"`. The registrations and
the latest 200 job states are stored in `activities.json`.

## 4. Display

Caboose Display (`guest/display`, Rust and Smithay) is a headless Wayland compositor with
Xwayland. It composites nothing: each toplevel and popup is its own stream, and the phone
or TV places them as native surfaces. It encodes each window's changes (H.264, HEVC or AV1,
with lossless PNG tiles for small changes and a sharpening pass once content is still),
paces frames on the client's vsync, carries clipboard text, named cursors, touch,
text-input-v3 and the keyboard, and sends sound as Opus on the same clock as video. Video an
application decodes through the Caboose VA-API driver reaches the client as its own
compressed stream, layered into the window when the application presents each frame.

- [display.md](display.md) specifies the Caboose Display Protocol: framing (a type byte, a
  little-endian length and one canonical CBOR map), the hello and display token, pacing and
  acknowledgement, every message, audio and video streams. `guest/display/vectors/` pins
  every message byte for byte, and both the Rust codec and CabooseKit test against them.
- [codec-passthrough.md](codec-passthrough.md) specifies the contract between the VA-API
  driver and the compositor.

The app connects through `/v1/display` with the token from `/v1/session`. The host relays
the stream and never decodes it.

## 5. Agents

An agent is any program that speaks the [Agent Client Protocol](https://agentclientprotocol.com)
(ACP) and is listed in the public [ACP registry](https://github.com/agentclientprotocol/registry).
Caboose has no list of its own and no code for any particular agent: it runs whatever the
registry describes, inside the computer, signed in with the owner's own accounts. The host
holds no model keys. An agent works on its own seat, so it never moves the owner's pointer
or types into the owner's windows.

### The registry

The host fetches `registry.json` (`CABOOSE_AGENT_REGISTRY_URL`, by default
`https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json`) when it is first
needed and again after an hour, revalidating with its ETag. The last good copy is kept in
memory and in `agent-registry.json`; when a fetch fails it is served with
`registry.error`, and the fetch is retried after a minute. Before any successful fetch the
list is empty and says why.

Each agent is resolved for `linux-x86_64`, preferring a binary the registry pins by
SHA-256, then `npx`, then `uvx`, then a binary without a checksum:

| Distribution | Started as |
| --- | --- |
| `npx` | `npx -y <package> <args>` |
| `uvx` | `uvx <package> <args>` |
| `binary` | `<cmd> <args>` inside `~/.local/share/caboose/agents/<id>/<version>/`, after downloading `archive` over HTTPS, checking its `sha256` when given, and unpacking it (`.zip`, `.tar.gz`, `.tar.bz2`, `.tar.xz`, or a raw executable) |

with the registry's `env`. Entries without such a distribution, with a command that leaves
its directory, or with a package name that looks like an option are not offered.

**Install** prefetches an agent into the computer (the npm or uv cache, or the binary),
starts it once to learn its sign-in methods, and records the version in
`~/.local/share/caboose/agents/<id>/installed.json`. A task runs the installed version;
installing again moves to the registry's current one. An agent that is not installed runs
the registry's current version, fetched on first use. An installed agent that leaves the
registry stays listed and runnable.

Everything under `/home/caboose` belongs to `caboose`. Before an install, a sign-in or a
runner start, the host gives anything in the home that is not owned by `caboose` back to
it: one `find -xdev` pass as root, at most once every five minutes and again after a
restart. A root-owned leftover, such as a cache written by a hand-run command, would
otherwise break the next npm, uv or agent run.

The owner can give an agent extra environment, such as an API key, in
`/home/caboose/.config/caboose/agents/<registry id>.env`: `KEY=VALUE` lines, `#` comments
and blank lines, no shell expansion, one pair of matching quotes around a value removed.
The file must belong to `caboose` with mode 0600, or the runner ignores it and logs why. It
is applied after the registry's `env` for tasks, installs and sign-ins, and its values are
never written to transcripts or logs. Clients edit it with `PUT /v1/agents/:id/env`: the
runner merges the change (`caboose-agentd set-env`) and keeps the file's other lines. The
host keeps no copy.

### The runner

`caboose-agentd` (`guest/agentd`, installed at `/opt/caboose/agentd`) is the ACP client.
The guest channel carries command arguments, not stdin, so the host never speaks ACP
itself: it starts one runner per task, detached (`setsid`), as `caboose`, and the two
exchange files in the task directory `/home/caboose/Agents/<task id>/`. The file formats are
specified in `guest/agentd/README.md`; in short:

- The host writes `task.json` `{ agent: <resolved spec>, cwd, approvals, idleMs,
  craftServers }`, prompts as `inbox/<turn, 6 digits>.prompt.json`, cancels as
  `inbox/cancel-<n>.json`, and decisions as `approvals/<requestId>.decision`. The runner
  writes `transcript.jsonl`, `approvals/<requestId>.json` and `session`; the launch script
  records `pid` and `exit-code`. Every file is written whole and renamed into place.
- `initialize` advertises file reads and writes (resolved paths, refused outside
  `/home/caboose`, at most 10 MB), no terminals, and terminal sign-in.
- Each turn is `session/prompt` with a text block, and each attachment as an `image` block
  when the agent accepts images and it is a PNG, JPEG, GIF or WebP under 10 MB, otherwise
  as a `resource_link` to its `file://` path.
- The transcript is the same for every agent: `user` (a turn began), `session`
  (`continuity: new | resume | load | recap`), `text` and `thought`, `tool` and
  `tool_update` (title, kind, status), `plan`, `mode`, `permission`, `usage`, and exactly
  one of `turn_end` (ACP `stopReason` and the turn's last message as `summary`),
  `turn_failed` or `auth_required` per turn, each with its turn number.
- After a turn the runner keeps the agent and its session for `CABOOSE_AGENT_IDLE_MS`
  waiting for a reply, then exits 0. A later reply starts a new runner, which reopens the
  conversation with `session/resume` if the agent advertises it, else `session/load` (the
  replayed history is not written again), else `session/new` with a recap of the earlier
  turns at the start of the prompt; that turn's summary says so.

### Tasks

- **Start.** `POST /v1/agent/tasks` names an agent by registry id, or uses the owner's
  `defaultAgent`. The ids `claude` and `codex` are accepted as `claude-acp` and
  `codex-acp`. The host resolves the agent (installed version first), starts the agent seat,
  writes the attachments, `task.json` and the first prompt, and starts the runner. The
  task's `prompt` stays as the owner wrote it.
- **Approvals.** With `approvals: "ask"`, each ACP `session/request_permission` becomes
  `approvals/<requestId>.json` `{ tool, kind, summary, input, options: [{ id, name, kind }],
  requestedAt }` and waits, with no time limit (the task's lease keeps the computer awake),
  for the owner's decision `{ allow, message?, optionId? }`: the named option, else the
  agent's `allow_once` (`allow_always`) or `reject_once` (`reject_always`). Request ids are
  UUIDs minted by the runner and validated by the host. ACP has no field for a reason, so a
  denial's `message` is kept in the transcript and not shown to the agent. With
  `approvals: "auto"` (the default) the runner answers `allow_once` (else `allow_always`)
  itself; agents keep their own modes and settings.
- **Replies.** A finished task (succeeded, failed or cancelled) can be continued. If its
  runner is still waiting, the prompt goes to the same session; otherwise the reply starts
  a new runner, which takes the prompt from the inbox (a runner that neither takes it nor
  exits within 20 s is stopped). Each turn appends to the same `transcript.jsonl`; the task
  keeps its id, `prompt` and `startedAt`, returns to `running`, and `turns` counts the
  turns. Output the earlier turn writes after it was cancelled is not shown as the new
  turn's.
- **Cancel** writes a cancel to the inbox. The runner sends `session/cancel`, answers
  waiting permission requests `cancelled`, and ends the turn with
  `stopReason: "cancelled"`; an agent that has not stopped after 15 s is terminated, and
  the next reply starts it again. The host reports the task cancelled at once.
- **Pause and resume** stop and continue the task's whole process group (SIGSTOP and
  SIGCONT). The app pauses running tasks while the owner takes over the agent seat.
- **Signed out.** An ACP `auth_required` error (code -32000) from `session/new`, `load`,
  `resume` or `prompt` fails the task with `summary: "Sign in to <name> first."` and
  `signIn`, the agent's sign-in methods; after signing in, a reply retries.
- **Polling.** While any task is live the host runs one guest command per second for all of
  them: new transcript bytes from each task's offset (1 MiB per tick shared between tasks,
  read as base64 so offsets stay exact), the runner's exit code, and pending approval
  requests. A runner that exits before its turn ends fails the task with the end of its
  stderr.
- **Restore.** Each task directory records its agent, prompt, approval mode and turn
  count, so a restarted host rebuilds the task list from the guest: a task whose last turn
  ended is finished with that turn's result, one whose runner is still working takes the
  lease again, and either can be replied to. A task directory without `task.json` is listed
  but cannot be continued.
- **Lifetime.** Tasks keep running while the phone is locked. The host holds a lease while
  any task is running or paused, so the computer is not parked under a working agent.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/v1/agents` | The agents this computer can run (below). Never wakes the computer; shows the last known installed state while it is parked |
| `POST` | `/v1/agents/:id/install` | → `{ agent }`. Prefetch the registry's current version and learn its sign-in methods; can take up to 15 minutes. 404 for an id not in the registry, 409 while the computer is not running or has no runner, 502 when the install fails |
| `PUT` | `/v1/agents/:id/env` | `{ set?: { NAME: value }, remove?: [NAME] }` → `{ env: [NAME] }`. Names are shell-style; values are one line of at most 8192 characters. 400 for invalid input, 409 while the computer is not running |
| `POST` | `/v1/agents/:id/sign-in` | `{ methodId }` → `{ started: true, method: { id, name, description?, type } }`. 400 for an unknown method |
| `POST` | `/v1/agent/tasks` | `{ prompt, agent?, approvals?: "ask" \| "auto", craftMcp?: boolean, attachments?: [{ name, type?, data (base64) }] }` → `{ id }`. 400 when no agent is given and no default is set; 404 for an id that is not in the registry or installed |
| `GET` | `/v1/agent/tasks` | Recent tasks, newest first |
| `POST` | `/v1/agent/tasks/:id/reply` | `{ prompt }` → `{ task }`. 409 while the task is running or paused, or for a task that cannot be continued; 404 for an unknown task |
| `POST` | `/v1/agent/tasks/:id/approvals/:requestId` | `{ allow: boolean, message?, optionId? }` → `{ resolved }`; `false` when that request is no longer waiting |
| `POST` | `/v1/agent/tasks/:id/cancel` | → `{ cancelled }` |
| `POST` | `/v1/agent/tasks/:id/pause` | → `{ paused }`; the task becomes `paused` |
| `POST` | `/v1/agent/tasks/:id/resume` | → `{ resumed }` |

Prompts are 1–32000 characters after trimming. Attachments are at most 4 files and 10 MB
decoded together; names are made safe and unique, and files are written to the task's
`attachments/` directory. `message` is at most 2000 characters and `optionId` 200. Agent
routes answer 409 while the computer is not running or when its image has no runner, and
502 when the registry has never been fetched and the agent is not installed.

`GET /v1/agents`:

```ts
{
  agents: Array<{
    id: string, name: string, version: string,   // the registry's current version
    description: string, icon: string | null, website: string | null, repository: string | null, license: string | null,
    distribution: "npx" | "uvx" | "binary",
    installed: { version: string } | null,
    signIn?: Array<{ id: string, name: string, description?: string, type: "agent" | "terminal" }>,  // once known
    signInStatus?: { methodId: string, status: "running" | "succeeded" | "failed", message?: string, startedAt?: string, finishedAt?: string },
    env?: string[]                               // variable names its environment file sets; never values
  }>,                                            // registry order; installed agents no longer in the registry last
  defaultAgent: string | null,
  registry: { fetchedAt: string | null, error?: string }
}
```

A task record:

```ts
{
  id: string,
  agent: string,                  // registry id
  agentName?: string,             // the registry's name for it
  prompt: string,                 // the first prompt, as written
  status: "running" | "paused" | "succeeded" | "failed" | "cancelled",
  startedAt: string,              // ISO 8601
  finishedAt?: string,            // absent while running
  summary?: string,               // the last turn's result; absent while running
  turns: number,                  // 1, plus one per reply
  approvals: "ask" | "auto",
  pendingApproval?: { id: string, tool: string, summary: string, options?: Array<{ id: string, name: string, kind: string }> },  // oldest request waiting
  attachments?: string[],         // absolute guest paths
  signIn?: Array<{ id: string, name: string, description?: string, type: "agent" | "terminal" }>  // when the agent was signed out
}
```

Control-socket events:

| Event | Payload |
| --- | --- |
| `agent.task.started` | `{ id, agent, agentName?, prompt }` |
| `agent.task.output` | `{ id, kind: "text" \| "tool" \| "error", text }`: each agent message, each new tool call by title, and a failed turn's error |
| `agent.task.paused`, `agent.task.resumed` | `{ id }` |
| `agent.task.finished` | `{ id, status: "succeeded" \| "failed" \| "cancelled", summary, signIn? }` |
| `agent.task.replied` | `{ id, prompt, turn }` |
| `agent.task.approval` | `{ id, request: { id, tool, summary, options? } }`, once per request |
| `agent.task.approval.resolved` | `{ id, requestId, allow }` |

### Signing in

Agents announce their sign-in methods in ACP `initialize`, which the runner records when an
agent is installed, probed or run. Sign-in runs on the owner's display, with the launch
environment from `/run/caboose/display.env`, which the host passes to the runner:

- **`agent`:** the runner calls ACP `authenticate`; the agent opens the computer's browser
  at its own sign-in page, with its callback on the computer's localhost, and the owner
  completes it on the phone.
- **`terminal`:** the runner opens a terminal window running the agent's own program with
  the method's `args` in place of the registry's, and its `env` over the registry's. Exit
  status 0 is success; the runner then initializes the agent again.

Progress is reported as `signInStatus` in `GET /v1/agents`
(`~/.local/share/caboose/agents/<id>/sign-in.json`). Credentials stay wherever the agent
keeps them in the owner's home.

### The agent seat

Every task runs on the agent seat. The runner's environment is the seat's launch
environment from `/run/caboose/agent-display.env`, with `DISPLAY=:101`,
`XDG_RUNTIME_DIR=/run/user/1000` and the seat's session bus
`DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/agent-bus`. GUI applications an agent
starts appear on the seat, and their notifications stay on its bus.

The app shows the seat in its Agent space, view-only. **Take Over** pauses the running
tasks and gives the owner input; **Hand Back**, or leaving the window, resumes them, so the
owner and an agent never type into the same application at once.

### Desktop tools

`caboose-desktop-mcp` is a stdio MCP server. The runner passes it to every agent as
`caboose-desktop` in ACP `session/new`, with the seat's launch environment:
`CABOOSE_AGENT_DISPLAY` (the seat's `DISPLAY`), `WAYLAND_DISPLAY`, `CABOOSE_DISPLAY_CONTROL`,
`XAUTHORITY`, `XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS`, the toolkit backends and the
video passthrough variables.

| Tool | Does |
| --- | --- |
| `elements` | The focused window's controls (role, name, states, bounds) from the AT-SPI tree |
| `find` | Elements whose name contains a query, optionally of one role |
| `click_element`, `set_text` | Press an element, or replace an editable element's text, by id |
| `read_text` | The focused window's readable text, page text included |
| `screenshot` | PNG of the seat or one window |
| `list_windows`, `focus` | Windows with kind, title, application, geometry and focus; give one the keyboard |
| `click`, `drag`, `type`, `key`, `scroll` | Pointer and keyboard by coordinates |
| `launch` | Start an application on the seat with accessibility enabled |

The accessibility tools come first in the list because they need no screenshot and no
model round trip. They use `a11y.py`, which reads only applications whose windows are all on
the seat, so an agent cannot list, read or press the owner's windows. The coordinate tools
and `screenshot` use the seat's control socket through `seat.py`, so they reach Wayland and
X11 applications alike and work while nobody watches the seat; coordinates are the seat's
logical pixels, the same as the screenshot's and the elements' bounds.

At task creation the host also snapshots installed catalog entries that declare an `mcp`
command and offers each as a `caboose-<catalog id>` stdio server in ACP new, load and
resume requests. Commands and arguments are passed directly, never through a shell. The
catalog declares such servers for PhotoCraft, LightCraft, FilmCraft, VectorCraft, PDFCraft,
EffectCraft, DesignCraft, WordCraft, GridCraft, DeckCraft, CADCraft, SoundCraft and
FigCraft. `craftMcp: false` on task start omits them for that task and its replies. What an
agent can use depends on its support for ACP MCP servers and on each application's tools.

### Screen tools

The `/v1/screen` routes ([Screen](#screen)) give the owner's own clients the same
accessibility view of the owner's display. They act only on the owner's display, on the
owner's command.

### Files and attachments

Attachments are written to the task directory through the guest channel as `caboose`. Agents
read and write files through ACP, limited to `/home/caboose`, and see the same home the
owner sees in Files.

## 6. iOS app

Caboose for iOS is SwiftUI over UIKit surfaces, iOS 26+, with the project generated by
XcodeGen. `apps/ios/README.md` covers its layout, build and device checks in detail.

### Rendering

**CabooseKit** (a Swift package without UI dependencies) implements one display client,
`CabooseDisplaySession`, behind the `DisplaySession` window model the app works against.
It speaks the Caboose Display Protocol: canonical CBOR, per-window video with
acknowledgements and keyframe recovery, video streams layered into windows, Opus sound on
one playback clock with them, and vsync pacing. Each window fills a `RemoteWindow` and its
Metal `WindowSurface`. Decoding uses `VTDecompressionSession` for H.264, HEVC and, where the
device has a hardware decoder, AV1, and ImageIO for PNG and WebP tiles. Every write to a
window's texture is a blit on one shared Metal queue, which runs command buffers in commit
order, so no draw waits for the GPU before the next frame is decoded and acknowledged.
CabooseKit is unit-tested on macOS, including the protocol's golden vectors.

- **Shell.** On iPhone each Linux window is an app card: full screen, with native
  app-switcher gestures between cards and a home grid of Linux apps with their real
  icons. Home's Shelf offers optional catalog apps, and Library groups packs and lets the
  owner install, update, roll back or remove them; progress follows the control socket. On
  iPad and external displays the same windows float, resize and stack, with a dock and a
  menu bar. Transient windows (menus, dialogs, tooltips) are positioned relative to their
  parent, never as separate cards.
- **Lifecycle.** The display socket closes when the app goes to the background; the
  computer parks on idle and resumes on the next foreground. The last frame of every window
  is cached, so reopening is instant while the stream reconnects.
- **Computer settings.** A Computer sheet (from Home, the parked screen and the failure
  screen) edits the management settings, shows `restartRequired`, parks, and restarts after
  confirmation; Park Now lands on a parked screen with Wake.

### Input

- **Touch.** Native Wayland windows take real multi-touch. Xwayland windows get pointer
  gestures: tap, drag and long press, with a two-finger tap or a long press for a right
  click and swipes that scroll with momentum. A tap shows the keyboard when the app
  answers it with a text cursor or text-input-v3 focus, and hides it otherwise. Dialogs are
  fitted and centred on the phone.
- **Pointer.** A hardware trackpad and mouse work through `UIPointerInteraction` and
  `GCMouse`.
- **Keyboard.** The iOS keyboard works through `UITextInput`, so autocorrect, QuickPath,
  dictation, emoji and marked-text input (Chinese, Japanese, Korean) work. The remote text
  is unknown, so the client keeps a `TypingBuffer` of what was typed since the last click,
  Return or non-text key, assumes the remote caret is at its end, and turns each edit iOS
  makes into BackSpaces and keystrokes from where the old and new text differ. Where an app
  has text-input-v3, the keyboard follows its state, its content purpose turns autocorrect
  off for terminals and passwords, and marked text is a preedit. Otherwise autocorrect and
  capitals are on for prose and off in terminals and code editors, with an `Aa` toggle on
  the key bar.
- **Pencil.** The client defines `pencil` samples (pressure, tilt, azimuth, hover), but the
  compositor does not advertise the `pencil` feature, so Apple Pencil acts as touch and
  Linux applications receive no pressure or tilt.

### Agent space

- **Ask bar.** Starts tasks with the default agent or any installed one, optionally asking
  before acting. Pending approvals show on the task card and as a banner over every screen,
  with the agent's always-allow option when it has one. Finished tasks take replies, and a
  task whose agent was signed out offers its sign-in methods. A window's menu hands the
  window (screenshot, title, app) to an agent as an attachment.
- **Agent seat.** The Agent space watches the seat with a second `CabooseDisplaySession`
  on `/v1/display?seat=agent` that plays no sound, so there is one stream of sound: the
  owner's display. Take Over and Hand Back pause and resume tasks.
- **Settings › Agents** lists the registry (installed agents first): install or update,
  sign in on the computer's screen, add or remove environment variables such as an API key,
  and choose the default agent. Registry icons are SVG, which iOS does not draw, so agents
  show their initials.
- **On-device model.** Where Apple Intelligence is available, the Ask bar also offers the
  phone's Foundation Models model. It runs on the device and sends nothing to a model
  provider. Its tools act through the host: launch an app (`/v1/apps/:id/launch`), open a
  page or search (`/v1/open`), type or press keys (`/v1/screen/type`, `/v1/screen/keys`),
  look at the focused window and press a control by name (`/v1/screen/elements`,
  `/v1/screen/act`), park the computer, and delegate anything that needs several steps,
  code, files or judgement to a computer agent as a task. It acts on the accessibility tree
  rather than on pixel coordinates. `apps/ios/OnDeviceEval` evaluates it on a device.

### Notifications

The control socket's `notification` events become local notifications while the app runs.
When the host has APNs configured, Computer settings offers per-device switches for
approvals, task results and desktop notifications. Enabling them requests permission and
registers the device's APNs token (`POST /v1/devices/push`). Approval notifications carry
actions that call the approval route; task notifications open the task. Signing out
unregisters the device.

### Live Activities and widgets

The app starts a Live Activity for each running agent task and registers its update token
with `POST /v1/activities`, and registers the device's push-to-start token with
`POST /v1/activities/start-token`. It also updates or ends an activity while in the
foreground, and unregisters both on sign-out. The widget extension renders the Lock Screen
and Dynamic Island presentations and opens the agent task on tap.

The WidgetKit extension reads the pairing from the shared Keychain access group and fetches
the computer's state and running agent count without waking it; WidgetKit schedules its
refreshes. It provides a configurable favourite-app widget and Control Center control that
launch the selected app, an Ask Agent control that opens the Ask bar, and a power toggle
that wakes or parks the computer.

### Shortcuts and Spotlight

App Intents wake or park the computer, open a Linux app, open a URL on the computer, ask a
computer agent (an approval-gated task, returning a task link), open, get or save computer
files, and run the four Craft operations. App shortcuts offer phrases to Siri and
Shortcuts. App and file entities use the authenticated host API. File paths are relative to
the home; saving creates new files and refuses to overwrite.

Craft intents stage their inputs under `.caboose-jobs/<job>` through `/v1/fs`, call
`POST /v1/catalog/:id/run`, download the outputs, and move the job directory to Trash after
success. A failed or interrupted job's directory is kept for inspection. CLI warnings are
returned to the shortcut.

File search lists the home recursively through `/v1/fs`, skipping unreadable or removed
directories and the top-level `.caboose-jobs` directory, and sorts by modification time.
It suggests the 200 most recent files; a text query searches all of them. On wake and on
`fs.changed`, while a control connection is active, the app replaces its 200 Spotlight file
entries; a connection failure during a scan leaves the previous entries in place. The app
also indexes the current app list, opens an indexed app or file when it is selected, and
removes its index on sign-out.

### Files

The File Provider extension registers a domain named for the paired computer, enumerates
its home through `/v1/fs`, downloads on demand, and uploads coordinated edits with
`If-Match` and `If-None-Match`. It keeps stable item identifiers in its extension storage
across moves, signals the working set when the app receives `fs.changed`, and
re-enumerates after an expired anchor. The system generates previews for downloaded files;
there are no server-side thumbnails. Files access wakes a parked computer, and an
unreachable host is reported to Files as unreachable.

### Open in place

The app's alternate-handler document types come from `guest/catalog/catalog.json`:
`apps/ios/scripts/document-types.py --write` updates the checked-in snapshot, and the build
checks it before generating the app's Info.plist. Extensions without a recorded system
type identifier get an imported Caboose UTI. Only associations recorded in the catalog are
declared; an empty file-type list does not mean an app cannot open a type.

A file URL delivered to the app opens a chooser of catalog applications that list its
extension or type (installable ones included, with progress) and other installed apps. For
an external file, Caboose coordinates a read, streams a snapshot to
`Caboose Documents/<uuid>/<filename>` through `/v1/fs`, stores the security-scoped bookmark
and the paired computer's identity in the app group, and launches the chosen desktop entry
with the file. A copy delivered into the app's Inbox is identified as a copy, and the
chooser warns that changes cannot return to its source. The Share extension offers the same
chooser and asks for an in-place representation; if the provider offers only a temporary
copy, it warns that edits cannot be written back and proceeds only after the owner chooses
Open Copy. A file from Caboose's own File Provider is translated through the provider's
shared identifier index and opens its existing computer path without a copy; if the index
is unavailable, opening fails rather than making another copy. Project files can reference
media separately; opening one document does not upload those dependencies.

For an external original with a persistent bookmark, the app compares a hash of a
coordinated local snapshot and the remote ETag with the last synchronized versions. A
change on one side is copied to the other; changes on both sides present Keep Original or
Keep Computer Copy. Downloads are version-checked again before a coordinated replacement,
and writes to the computer carry `If-Match`. A version that changes during an attempt fails
it, and the file is checked again rather than a winner being chosen silently. The app
reconciles after `fs.changed` and when it resumes or reconnects; iOS does not run it
continuously while suspended. Failures and stale bookmarks are shown in the app. A deleted
or renamed computer copy is reported as a sync error and is not rebound automatically.

The app, Share extension and File Provider share the `group.com.braedonsaunders.caboose`
app group and a Keychain access group.

### Share, drop and print

- **Share extension.** `CabooseShare` takes pages, text, photos and files from the iOS
  share sheet: `POST /v1/open` for a page, an upload into Downloads (optionally opened on
  the computer), or a new agent task with them attached.
- **Drop.** Text dropped on an owner window focuses it, clicks at the drop point and types
  the text through the display session. A dropped file or image (at most 50 MiB) is saved
  to `~/Downloads` with `POST /v1/files` and opened with Linux's default handler, which is
  not necessarily the window it was dropped on. Transfer failures are shown on the phone.
  Dropping a file into a specific Linux application, and dragging out of Linux, are not
  supported.
- **Phone handoff.** The app opens its foreground control socket with `?phone=1`. It
  prompts before opening a URL, sharing or printing, never acts silently, and defers
  prompts while inactive. After the owner agrees it downloads a staged file with
  `GET /v1/phone/files/:id` (behind the `PhoneFileDownloading` protocol), then presents the
  share sheet or the AirPrint dialog, and deletes its temporary copy when the sheet
  finishes.

## 7. Security model

- **Owner token.** One bearer token (`CABOOSE_OWNER_TOKEN`, or generated into the state
  directory with mode 0600) authorizes every `/v1` route and WebSocket. The host speaks plain HTTP on loopback by default; HTTPS and WSS belong in
  front of it before traffic crosses a network. The app and its extensions keep the pairing
  in a shared Keychain access group; the web console keeps it in session storage.
- **Display token.** A random per-wake token in `/run/caboose/display-token` (mode 0600,
  owned by `caboose`) authorizes the guest's display and file services. It reaches a
  client only inside an authenticated `/v1/session` response.
- **Control sockets.** Each seat's control socket is a Unix socket in a directory only
  `caboose` can open, and the compositor serves only peers of its own user. It is never
  exposed outside the computer.
- **Fencing.** The guest cannot open connections to the host, and by default cannot reach
  private, link-local, CGNAT or reserved ranges. Display and file ports are reachable only
  from the host: over the TAP device for a microVM, on `127.0.0.1` for a container.
- **Guest input.** The host treats the guest as able to produce malformed data. Phone
  events, media state, notification records, task transcripts and approval requests are
  validated and bounded, and the host never relays a guest-supplied file path.
- **Guest commands.** The host passes arguments, never shell strings built from client
  input; Craft jobs and catalog operations run fixed argument vectors, and catalog MCP
  commands are restricted to plain words.
- **Privileged host container.** The Compose deployment (`deploy/compose.yaml`) runs the
  host in a privileged container for KVM, loop mounts and TAP networking. Its TAP,
  forwarding and NAT rules live in the container's network namespace, and the guest can
  reach the networks available to that container. Run it only on a trusted host.
- **Agents.** Agents run inside the computer as `caboose` with the owner's own credentials.
  The host holds no model keys, never stores agent environment values, and keeps agents on
  their own seat and session bus.

## 8. Decisions

- **Per-window streams, not a desktop picture.** Each Linux window is its own stream, so
  the phone and TV can present it as a native surface. The compositor composites nothing.
- **A purpose-built compositor.** Caboose Display owns the window model, encoding, pacing,
  touch, text input and sound clock end to end, so each can be designed for a phone
  client ([display.md](display.md)).
- **Relay, do not transcode, on the host.** The host never decodes pixels, so one host
  serves many computers and latency stays guest to phone.
- **Cloud Hypervisor, copy-on-write overlays and park-with-memory.** Resuming exactly where
  the owner left off is part of the product. The container runtime exists only for GPUs a
  VM cannot have, and gives up durable parking and VM isolation to get them.
- **A separate agent seat.** Agents get their own display and session bus, so they never
  take the owner's pointer, keyboard or notifications.
- **Agents through ACP and its registry.** Caboose runs any registered agent with no
  per-agent code, inside the computer and under the owner's own accounts.
- **Files through a dedicated service.** The guest command channel carries arguments only,
  so bulk file transfer uses a token-authenticated streaming service that the host relays
  without buffering.
- **AGPL-3.0-or-later.** Caboose is self-hostable and open source.
