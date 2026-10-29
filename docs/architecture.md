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
| The computer | `guest/` | A Debian 13 (amd64 or arm64) machine, booted as a Cloud Hypervisor or Virtualization.framework microVM, or run as a container. It runs Caboose Display, the file service, the agent runner and the integration services. |
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
 │  │  ├ TerminalConnection     │  /v1/terminal │  ├ Terminal relay: WS ⇄ guest terminal     │
 │  │  ├ VideoToolbox, Metal    │               │  ├ Agents, catalog, media, phone handoff   │
 │  │  └ Touch, trackpad,       │               │  └ APNs: alerts and Live Activities        │
 │  │    keyboard, clipboard    │               │        │ guest agent (exec)                │
 │  ├ Agent space               │               │        │ TCP 14600 / 14601 / 14700 / 14701 │
 │  └ Files, Shortcuts,         │               │ ┌──────▼───────────────────────────────┐   │
 │    Spotlight, widgets,       │               │ │ The computer (Debian 13)             │   │
 │    Live Activities           │               │ │  ├ caboose-display        :14600     │   │
 └──────────────────────────────┘               │ │  │   owner's display, Xwayland :110  │   │
                                                │ │  ├ caboose-display-agent  :14601     │   │
                                                │ │  │   agent seat, Xwayland :101       │   │
                                                │ │  ├ caboose-files          :14700     │   │
                                                │ │  ├ caboose-terminal       :14701     │   │
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

Profile tasks can use host-scoped memory and routine MCP tools over a bounded task-directory
mailbox; the host owns the task/profile binding and durable request receipts. The mailbox
never carries an owner or phone bearer token. See [agent routines](agent-routines.md#agent-tools-and-durability).

## 2. The computer

### Guest image

The microVM boots a Debian 13 (trixie, amd64 or arm64) golden image built by `guest/image/`. Each
computer's disk is a reflink copy-on-write clone of the base: it costs no space up front,
and the owner's installs and home persist. A clone is independent of the base once made,
so a new base image reaches new computers only.

The image contains:

- **Applications.** Chromium, Firefox ESR, VS Code, xfce4-terminal, Thunar, Mousepad,
  LibreOffice, Obsidian, Evince, KeePassXC, mpv and other document and media tools;
  developer tools including Git, Neovim, Lazygit, Lazydocker, btop, tmux, mise and modern
  shell tools; Docker; official Claude Desktop (including Claude Code) and ChatGPT
  (including Codex); and the Claude Code, Codex, OpenCode and Gemini CLIs, with separate
  desktop launchers for terminal tools and agents. Mesa provides software Vulkan and OpenGL when the
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
both, pinned by digest for its own architecture. Images build on native amd64 and arm64
runners. Host and container tags select the matching architecture; base artifacts use
`<version>-amd64` and `<version>-arm64` tags (`<version>` remains the amd64 alias).
Native host bundles carry the corresponding image pins and are checked on native runners.
Prereleases do not replace `latest`.

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

Caboose's own guest plumbing (the file and terminal services, the notification monitor and
endpoints, phone handoff and the agent runner) is a bundle listed in `guest/components/manifest.json` and installed by
`guest/components/install.sh`. Both image builders run the installer, and the host runs the
same installer to update computers whose disks predate the host:

- After each wake, once the owner's display is ready, the host hashes the bundled files in
  manifest order and compares the hash with `/usr/local/share/caboose/components.version`
  in the guest. On a mismatch it runs the installer as root over the guest channel (`vm` or
  `container` mode). The installer adds missing Debian dependencies and preserves working
  `node` and `npm` commands, including npm bundled with NodeSource's `nodejs`. It never
  touches the owner's home, is safe to repeat, and writes the marker only after it succeeds.
- The update runs in the background and does not block the display. While it runs it holds
  a lease, and park or restart is rejected with 409. A failure is retried on the next wake.
- Container services are identified as their owner, including when restricted container
  root cannot read that user's process arguments. A stale pid file is repaired from the
  exact service script; readiness requires that process to own its listening socket.
- `GET /v1/computer` reports `upgrade: null | { state, version?, message? }`, and
  `/v1/control` sends `computer.upgrade` with `state` `checking`, `updating`, `succeeded` or
  `failed`.
- A container created without the port 14700 mapping cannot reach the file service; the
  management status warns that it must be recreated (keep its home volume). One created
  without the 14701 mapping needs nothing: the host reaches its terminal service on the
  container's address on its bridge network.

The runner and its pinned runtime dependencies install at `/opt/caboose/agentd`; an upgrade
replaces its script atomically and reuses dependencies whose exact versions already match.
An active runner finishes with the code it loaded; the next runner uses the installed code.
The bundle does not include Caboose Display or its units, which come with the image.

### Runtimes

The computer runs as a **microVM** by default: Cloud Hypervisor on Linux or
Virtualization.framework on Apple Silicon macOS 14+, through appkit-desk, with
the image files `base.raw`, `vmlinux` and `initrd` in `CABOOSE_IMAGE_ROOT`, its overlay at
`overlays/owner.raw` and its memory snapshot at `overlays/owner.snapshot`.

The macOS bundle includes a signed `appkit-desk-vz` helper and a menu bar app. A per-user
LaunchAgent runs the host at login; its data lives under `~/Library/Application Support/Caboose`.
It runs as the login user without root privileges. The helper gives each guest its own
user-space network and presents a virtio serial device, even when console logging is off.
Transient sockets live in a private `/tmp/caboose-<uid>/<image-root-hash>` directory to stay
within macOS's Unix socket path limit. The installer retains settings, accounts, disks and
memory snapshots across upgrades. The menu opens the local console with the one-time setup
code while the host is unclaimed; it never puts the owner token in a link.

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
default), and any extra `CABOOSE_CONTAINER_ARGS`. It publishes ports 14600, 14601, 14700
and 14701 on `127.0.0.1` only. Its session script provides:

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

Each Linux microVM computer has its own persistent TAP device and /30 in `192.0.2.0/24`: the
computer on slot *n* (see Computers) uses `caboose<n>`, with the host at `192.0.2.(4n+1)`
and the guest at `192.0.2.(4n+2)`. The owner's computer is slot 0: `caboose0`,
`192.0.2.1/30` and `192.0.2.2/30`. Each guest gets NAT to the host's other interfaces and
DNS `1.1.1.1`. At each wake the host also sets the guest's clock over the guest agent.

The guest is fenced in chains the host owns, each jumped to first from its built-in chain:

| Chain | Hook | Rules |
| --- | --- | --- |
| `CABOOSE-IN` | `INPUT -i caboose<n>` | Established and related traffic returns; everything else is dropped. The guest can open nothing on the host. |
| `CABOOSE-FWD` | `FORWARD -i caboose<n>` | Established and related traffic returns; new connections to `192.0.2.0/24` (every computer) and to private and reserved ranges are rejected; the rest returns to normal forwarding. |

Both chains are shared by every computer and refilled only when their rules differ, so
waking one computer never leaves another unfenced.

The rejected ranges are `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`,
`169.254.0.0/16` (link-local and cloud metadata), `100.64.0.0/10` (CGNAT and Tailscale),
`127.0.0.0/8`, `0.0.0.0/8`, `192.0.0.0/24`, `198.18.0.0/15`, `224.0.0.0/4` and
`240.0.0.0/4`. `CABOOSE_GUEST_LAN=allow` removes them, so the guest can reach the local
network; it never removes `192.0.2.0/24`, so one computer can never reach another. The host
opens the relay connections to the guest itself.

A container computer gets the same fence on its own Docker bridge network: `caboose`
(interface `caboose-br0`) for the owner's computer, `caboose-<n>` (`caboose-br<n>`) for
the others, which Docker isolates from each other. `CABOOSE-CIN` hooks `INPUT` and
`CABOOSE-CFWD` hooks `DOCKER-USER`, which Docker never rewrites.

On macOS, each VM has an independent user-space network at `10.0.2.15/24` with gateway
`10.0.2.2`. Its fence rejects guest connections to the host and private/reserved ranges;
`CABOOSE_GUEST_LAN=allow` does not enable LAN access on this backend. Display, files and
terminal use ephemeral listeners on host loopback that relay into the guest through
appkit-desk. Those listeners and their active connections close when the computer parks,
restarts, is deleted, or fails to wake. They reopen on wake; guest service tokens still
authorize every connection.

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
| Game handoff | `$XDG_RUNTIME_DIR/caboose-game.sock` | None (`--no-games`) |
| Session bus | `/run/user/1000/bus` | `/run/user/1000/agent-bus` |
| Notification endpoint | `caboose-notification-daemon.service` | `caboose-agent-notification-daemon.service` |
| Launch environment | `/run/caboose/display.env` | `/run/caboose/agent-display.env` |
| Started | At every wake | On demand: by an agent task, or by a client opening `/v1/display?seat=agent` |

Each instance writes its launch environment once it is ready: `WAYLAND_DISPLAY`,
`DISPLAY`, `XAUTHORITY`, toolkit backends (`GDK_BACKEND`, `QT_QPA_PLATFORM`,
`MOZ_ENABLE_WAYLAND`, `SDL_VIDEODRIVER`, `ELECTRON_OZONE_PLATFORM_HINT`),
`CABOOSE_DISPLAY_CONTROL` (its control socket, below), `CABOOSE_GAME_SOCKET` on the owner's
display ([game-handoff.md](game-handoff.md)), plus `LIBVA_DRIVER_NAME=caboose` when the
passthrough driver is installed. Each keeps its X authority, Xwayland shim, PulseAudio
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

Both display instances re-read the file on every hello, the file service on every request,
and the terminal service on every connection. The token reaches the app only inside the authenticated `/v1/session`
response; the host relays display bytes without inspecting them.

### Guest services

**File service.** `guest/files/caboose-files.py` (`/opt/caboose/files/`,
`caboose-files.service`) runs as `caboose` on TCP 14700 and requires
`Authorization: Bearer <display token>` on every request. The host starts it at each wake
before the owner's display, and waits up to 60 s for it to listen; a computer without the
service still wakes. The protocol is in [Files](#files).

**Terminal service.** `guest/terminal/caboose-terminal.py` (`/opt/caboose/terminal/`,
`caboose-terminal.service` in the microVM, `caboose-components-services` in the container)
runs as `caboose` on TCP 14701, Python with the image's `python3-websockets`. Every request
needs `Authorization: Bearer <display token>`. Each WebSocket on `/` is one session: a login
shell (`caboose`'s shell, `-bash`) in `/home/caboose` on its own pseudo-terminal, with
`TERM=xterm-256color`, `COLORTERM=truecolor`, `TERM_PROGRAM=Caboose` and the owner
display's launch environment, so a program started from it opens on the owner's display.
Sessions outlive their connection: at most 16 exist, and a new one past that hangs up the
one left unattached longest. Each keeps its last 256 KiB of output for reattaching, and while
nobody is attached its output is read and kept, so the shell never blocks. Stopping the
service hangs up every shell; what a shell started with `nohup` or `setsid` keeps running.
`GET /sessions` and `GET /hangup?session=` serve the host's session routes.
`GET /start?cols=&rows=&argv=` (argv a base64url JSON list of 1–64 strings, the first an
absolute path) starts a session running that program instead of a shell, with the same
environment, and answers `{ session }` for a client to attach to; the agent runner uses it
for a terminal sign-in on the phone ([Signing in](#signing-in)). The protocol is in
[Terminal](#terminal).

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

**Native bridge.** `guest/bridge` answers Linux applications' desktop portal and MPRIS
calls from the phone: the FileChooser and Settings portals (`caboose-portal`, with
`xdg-desktop-portal-gtk` for the rest and as the fallback without a phone), and
`caboose-bridge`, the host's commands and the owner seat's daemon for Now Playing and the
appearance. GeoClue's static source serves a shared location. See
[native-bridge.md](native-bridge.md).

**Media handoff.** `guest/media-handoff` installs a Chromium extension, ID
`cklinclacpchpdgickgonlhnldfmkhbh` (fixed by the public key in its manifest), and its native
messaging host `com.caboose.media`. See [Media handoff](#media-handoff).

### Catalog

The Library is every application a computer can add: Caboose's curated entries
(`guest/catalog/catalog.json`: Craft releases and Debian applications) and Flathub's desktop
applications. A Flathub application that is also a curated entry (`flathub` in `catalog.json`)
is shown once, as the curated entry. Every operation is on one application.

- **Storefront.** The Library's front page is shelves: Popular (every application by installs
  in the last month, a curated entry counted by its Flathub twin's), then one per category
  with Caboose's entries first and the category's most installed Flathub applications after,
  15 to a shelf.
- **Lists.** A search, or a shelf's whole category, is one ranked list: curated matches first,
  then Flathub's by popularity, or with a query by relevance weighted by popularity.

- **Flathub.** The host keeps its own index of Flathub's desktop applications for the
  computer's architecture: name, summary, developer, licence, verified publisher, display
  categories, keywords, the runtime the stable branch builds against, and installs in the last
  month. It is fetched from Flathub's public search API (every page, about 3,300 apps) on first
  use and daily after, validated field by field, and kept in `CABOOSE_IMAGE_ROOT/flathub`;
  a failed refresh keeps the last index. Icons are Flathub's 128-pixel PNGs, fetched once
  each and kept beside it. Search needs no running computer and never wakes one. Without a
  query, Flathub apps are ordered by installs; with one, every word must match the name,
  keywords, id, summary or developer, and relevance is weighted by popularity.
- **Craft releases** follow each app's latest GitHub release
  (`storytold/<id>`, `<id>-<version>-linux-<x86_64|aarch64>.deb`). A release is offered only
  when its asset's published SHA-256 and size are present; prereleases and drafts are not. The
  host checks GitHub at most every six hours, keeps the last verified release on disk, and keeps
  offering it when GitHub is unreachable or a newer tag has no verifiable asset.
- **Debian applications** install from Debian 13's signed repositories. Debian applications the
  Library discovered through AppStream before it offered Flathub stay listed, updatable and
  removable: their package and AppStream identity are kept in their operation record.

**Updates.** Installed applications update themselves. Once a day while a computer runs (never
waking one), the host first updates the shared runtimes, then asks the guest which Flathub apps
have a newer commit and which curated Debian packages APT can upgrade, compares each Craft app's
installed version with its latest release, and runs an ordinary `update` operation for each.
`updateAvailable` reports what the last check found and `update` installs it at once.

The host runs the installer (`guest-catalog.py`) as root through the guest channel on both
runtimes. A Craft release downloads directly from the guest and is size- and SHA-256-checked
before APT installs it with `mesa-vulkan-drivers` and `libgl1-mesa-dri`; the `.deb` is deleted
once installed. A Flathub app installs into the computer's system Flatpak installation through
libflatpak, from the Flathub remote whose repository file (with its signing key) ships in
`guest/flatpak`. Installed versions come from dpkg and Flatpak; failures and interrupted
operations are recorded in the guest and reported on the next listing. A guest operation lock,
retained by package-manager children, distinguishes active work from an interrupted worker. A
retry of failed or interrupted Debian work completes pending dpkg configuration before trying
the requested operation again, even when dpkg already reports the application installed.

### Runtime depot

Flatpak apps run on shared runtimes (GNOME, KDE, Freedesktop), each about a gigabyte. A host
downloads each runtime once, for every computer: none is installed ahead of an app that needs it.

- **One installation, read-only everywhere.** The depot is a Flatpak installation owned by the
  host: the Docker volume `caboose-depot` on the container runtime, mounted read-only at
  `/var/lib/caboose/depot` in each computer. `/etc/flatpak/installations.d/caboose-depot.conf`
  names it; the installer adds it as the dependency source of every app transaction, so an app
  installs into its own computer and runs on the depot's runtime in place.
- **Written only by the host's builder.** Before a Flathub install or update, the host adds the
  app's runtime (with its GL driver, locale and codec extensions) through a builder: a
  throwaway container from the computer image with the depot writable, running
  `depot-builder.py`. No computer can modify a runtime another computer runs. Builds are
  serialized; a second request for the same runtime waits for the first.
- **Daily maintenance.** The builder updates every runtime. A superseded runtime's deployed
  files stay for 14 days for apps that started on it and still run. A runtime no computer has
  reported using for 30 days is removed; a computer whose apps still need it after a long sleep
  gets it back on its next listing, before an app needs it.
- **Without the depot** (a microVM host, or a container created before the depot existed), an
  app's runtime installs into the computer itself.

**Flatpak in a container.** Flatpak runs each app in bubblewrap, which needs user and mount
namespaces and gives the app its own `/proc`. A container computer gets them as follows:

- The host creates containers with `guest/container/caboose-seccomp.json`, which allows the
  namespaces and the mounts inside them (the kernel still requires `CAP_SYS_ADMIN` in the
  owning user namespace, which the container's root lacks).
- The kernel lets a sandbox mount a fresh `/proc` only where a fully visible one exists, and
  Docker masks parts of the container's. In container computers `/usr/bin/bwrap` is
  `guest/flatpak/caboose-bwrap` (the real one is diverted to `/usr/bin/bwrap.distrib`), which
  gives each sandbox the container's `/proc` read-only instead. A Flatpak app there can see
  the computer's processes, and read the `/proc` entries of its user's other processes, which
  Flatpak elsewhere hides; nothing of the host is exposed, and Docker's masks stay.
- bubblewrap's own lock on nested user namespaces (`--disable-userns`, which writes
  `/proc/sys/user/max_user_namespaces`) needs that fresh `/proc`, so the wrapper drops it and
  `--assert-userns-disabled`. Flatpak's seccomp filter still refuses every app `unshare`,
  `setns`, `clone` with `CLONE_NEWUSER` and `clone3`; `check-flathub.sh` proves each refusal
  inside a running app.
- A sandbox root starts (Flatpak's own setup, such as `ldconfig`) begins in a user namespace
  of its own, since the container's root cannot make the others.

A container created before this profile cannot start the sandbox: the guest probes it as the
computer's user, and the Library lists Flathub apps there with `unavailable` saying the computer
must be recreated (its home is kept). On hosts that confine containers with Docker's default
AppArmor profile, which denies `mount`, the probe fails the same way. A microVM computer needs
none of this: its root holds every capability inside the VM.

Only one catalog operation runs at a time, and it holds a computer lease. A second
operation, a park, a restart or a Craft job receives 409 while one runs. The listing reports the last
observed state while the computer is parked and never wakes it. `/v1/apps` discovers
installed desktop entries independently. Listings include the active operation's progress;
a host that rediscovers it holds a lease and observes it until it ends. A command-channel
timeout alone does not mark a still-active guest operation failed or release its lease.

Download progress measures bytes received: a Craft release's file against its published
size, a Flatpak transaction's or the depot builder's transferred bytes against the
transaction's download size. `value` is that download fraction, capped at 1; it is never an overall installation
percentage. `downloadedBytes` and `totalBytes` accompany it. Preparation, verification,
repository refresh, package installation, package configuration (including triggers) and
removal are indeterminate, with `value: null`. Package setup can continue after dpkg
reports the application's version; only the installer finishing completes the operation.
The Shelf names the current stage. The Library also shows download bytes and offers
Retry for failed or interrupted operations even when the application is already installed.

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
| `CABOOSE_DATABASE_URL` | unset | Postgres for accounts and tenants; unset, an embedded PGlite database in `${CABOOSE_IMAGE_ROOT}/identity` |
| `CABOOSE_AUTH_SECRET` | generated | The session-signing secret (32 characters or more); unset, generated into `${CABOOSE_IMAGE_ROOT}/auth-secret` |
| `CABOOSE_BIND` | `127.0.0.1` | Listen address |
| `CABOOSE_PORT` | `7310` | Listen port |
| `CABOOSE_IMAGE_ROOT` | `/var/lib/caboose` | Golden image, overlays, snapshots and host state |
| `CABOOSE_MEMORY_MB` | `6144` | Initial memory setting of the owner's computer and of new computers |
| `CABOOSE_VCPUS` | `4` | Initial vCPU setting, likewise |
| `CABOOSE_IDLE_MS` | `600000` | Initial idle time before parking, likewise |
| `CABOOSE_VMM_PATH` | `/usr/local/bin/cloud-hypervisor` | Cloud Hypervisor binary |
| `CABOOSE_RUNTIME` | `microvm` | `microvm` or `container` |
| `CABOOSE_GPU` | `auto` | Container GPU: `auto`, `wsl`, `nvidia`, `dri` or `none` |
| `CABOOSE_BASE_IMAGE` | unset (release: pinned) | OCI reference of the microVM image, fetched when the disk root lacks it ([Published images](#published-images)) |
| `CABOOSE_CONTAINER_IMAGE` | `caboose-computer:latest` (release: pinned) | Container image for every computer; pulled when missing if it names a registry |
| `CABOOSE_CONTAINER_NAME` | `caboose-owner` | The owner's computer's container name; others are `caboose-<id>` |
| `CABOOSE_CONTAINER_HOME` | `caboose-home` | Volume or absolute host path for `/home/caboose`; other computers use it with `-<id>` appended |
| `CABOOSE_CONTAINER_ARGS` | empty | Extra `docker run` arguments, whitespace-separated |
| `CABOOSE_GUEST_LAN` | `deny` | `allow` lets the guest reach private ranges |
| `CABOOSE_AGENT_REGISTRY_URL` | the public ACP registry | `http(s)` URL of `registry.json` |
| `CABOOSE_AGENT_IDLE_MS` | `600000` | How long a runner keeps its agent after a turn |
| `CABOOSE_MAX_RUNNING` | `4` | microVM computers that may run at once; waking another waits for one to park |
| `CABOOSE_PUBLIC_URL` | unset | Where phones reach the host from anywhere (an `http(s)` URL, optionally with a path, without credentials, query or fragment); first in `/v1/host/reach`, and the console auth base URL (auth defaults to loopback when unset) |
| `CABOOSE_MDNS` | `on` | `off` stops the LAN advertisement ([Reachability](#reachability)) |
| `CABOOSE_WEB_ROOT` | `apps/web/dist` | The built web console |
| `CABOOSE_APNS_KEY_PATH`, `_KEY_ID`, `_TEAM_ID`, `_TOPIC` | unset | APNs provider; all four or none |

Host state lives in `CABOOSE_IMAGE_ROOT`, each file replaced atomically with mode 0600:

- `owner-token` and `auth-secret` when generated, `setup-code` until the host is set up,
  `identity/` (the embedded accounts database, mode 0700),
  `phones.json` (phone sign-ins, by SHA-256 of their tokens) and `agent-registry.json`.
- The owner's computer's `caboose.json` (settings), `push-devices.json` and
  `activities.json` at the root, where a host from before several computers kept them.
- Every other computer's own `caboose.json`, `push-devices.json` and `activities.json`
  in `computers/<id>/`.
- For microVMs, `overlays/<id>.raw` (the disk), `overlays/<id>.snapshot` (parked memory)
  and `overlays/<id>.resources.json` (the resources it was booted with).

Computer slots and ownership live in `caboose_computers` and `caboose_people` in the identity database.

### Computers

A host runs several computers. The owner's computer always exists, with id `owner` and
slot 0, and cannot be deleted. Every other computer has an id `c-` followed by 10 hex
digits, and the lowest free slot from 1 to 63. The slot names its network (see Network
fencing) and, for a container, its loopback ports: 20000 + 10 × slot for the owner's
display, plus 1 for the agent seat and plus 2 for the file service. Each computer has its
own disk, settings, lifecycle, leases, agents, catalog, notifications and phones; nothing
of one is reachable from another. microVM computers share one appkit-desk host, so at most
`CABOOSE_MAX_RUNNING` run at once and further wakes queue.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/v1/computers` | `{ computers: [{ id, createdAt, …management status }], canCreate, limits: { computers, running } }`. `createdAt` is null for an owner's computer made before the host recorded it; `running` is null for the container runtime |
| `POST` | `/v1/computers` | `{ name, memoryMb?, vcpus?, idleMs? }` → 201 with the new computer, parked. Unset values come from `CABOOSE_MEMORY_MB`, `CABOOSE_VCPUS` and `CABOOSE_IDLE_MS`. 409 when all 63 slots are taken |
| `GET` | `/v1/computers/:id` | One computer, as listed |
| `DELETE` | `/v1/computers/:id` | `{ "confirm": true }` (required) → `{ deleted: true }`. Waits for queued work and for a components upgrade the host started, then closes the computer's sockets, ends its tasks and deletes its disk, snapshot, files, network, phones and pairing codes. 409 for the owner's computer, or while a catalog operation or Craft job someone started runs on it (the message says which; retry when it finishes) |
| any | `/v1/computers/:id/<route>` | Any computer route (§ Session and display through § Live Activities, and the agent routes of § 5), served by that computer (`/v1/computers/:id/session`, `/v1/computers/:id/fs/list`, `/v1/computers/:id/display`, …) |
| `POST` | `/v1/computers/:id/pairing` | → 201 `{ code, expiresAt }`: a pairing code for one phone (below) |
| `GET` | `/v1/computers/:id/phones` | `{ phones: [{ id, name, createdAt, lastUsedAt }] }`: the phones signed in to the computer. `lastUsedAt` is written at most once a minute |
| `DELETE` | `/v1/computers/:id/phones/:phone` | → `{ revoked: true }`. Signs the phone out: its token stops working, its open sockets close, and its push and Live Activity registrations are removed |
| `POST` | `/v1/pair` | **No token.** `{ code, deviceName }` → 201 `{ token, computer: { id, name } }`. Trades a pairing code for the phone's own token. `deviceName` is 1–60 characters without control characters. 404 for an unknown, used or expired code; 429 for 60 s after 20 wrong codes |

The routes without a computer in the path serve the caller's own computer: the owner's
computer for the owner token and the operator, and the phone's computer for a phone token.
They answer another administrator 403.

On a host with accounts, `GET /v1/computers` lists only the computers the caller manages,
and each carries `tenantId`, `personId` and the display label `person`. `POST /v1/computers`
requires a `tenantId` the caller administers and a `personId` belonging to it. Older callers
may supply a nonempty `person` name, which creates a distinct person in the same transaction.
`PATCH /v1/computers/:id` changes `personId`; moving to another `tenantId` also requires a
person in that destination and operator access. People are renamed through their own route. Quotas
are checked whenever a computer is made, resized (`PATCH …/computer/settings`), moved or
woken (see Accounts and tenants); a computer over quota answers 409 with what it would be
given and the quota.

**Pairing.** The console asks for a code and shows it as a QR code and as
`caboose://connect?host=<origin>&code=<code>`. A code is 8 characters from
`ABCDEFGHJKMNPQRSTVWXYZ23456789`, works once, expires after 10 minutes and lives only in the
host's memory. The app trades it through `POST /v1/pair` at the first of the link's
addresses that answers, then keeps the token like any other. Phone tokens are `cbp_`
followed by 43 base64url characters, shown only in the `/v1/pair` response; the host keeps
their SHA-256.

### Reachability

How a phone finds and reaches the host. `GET /v1/host/reach` lists every address a phone can
use, best first, and a pairing link carries them all: the first as `host=`, the rest as
`alt=`. The app probes the addresses without credentials and selects the first returning the
host’s anonymous health response; this filters captive portals but does not authenticate the
host. A paired phone can add or remove alternate
addresses in Computer settings, including while offline, without changing its token or Files
identity. It chooses among the saved addresses at each wake.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/v1/host/reach` | → `Reach` (below). Operator or owner token only |
| `PUT` | `/v1/host/reach/tailscale` | `{ enabled: boolean }` (nothing else) → `Reach`. Turns Tailscale's HTTPS `serve` for this host on or off. 400 for any other body; 409 with the reason when Tailscale is not installed, is signed out, has HTTPS certificates off for the tailnet, cannot read its Serve configuration, or already serves something else on HTTPS port 443 (which is never replaced or removed, including routes sharing the port). Operator or owner token only |

```ts
type Reach = {
  addresses: Array<{ url: string, kind: 'public' | 'tailscale' | 'lan' }>,  // public, then Tailscale, then LAN
  mdns: { enabled: boolean, name: string | null },
  tailscale: { installed: boolean, loggedIn: boolean, name?: string, serving: boolean, httpsUrl?: string, error?: string },
}
```

- **Public:** `CABOOSE_PUBLIC_URL`, for a host behind its own domain and HTTPS.
- **Tailscale:** `https://<machine>.<tailnet>.ts.net` while `serve` sends HTTPS on 443 to
  `http://127.0.0.1:<port>`. Tailscale terminates TLS with the tailnet's certificate. The host
  finds the `tailscale` CLI on `PATH` or in the macOS app and runs it as the host's user.
  `error` explains what stops it from serving.
- **LAN:** `http://<address>:<port>` for each IPv4 address on a real interface. Loopback,
  link-local, container and VM bridges (`docker*`, `br-*`, `caboose*`, `veth*`, `tap*`,
  `virbr*`, `vmnet*`, `bridge*`), VPN tunnels (`tailscale*`, `utun*`, `tun*`, `wg*`) and
  Apple's peer-to-peer links are left out. A host bound to loopback has no LAN address; one
  bound to a specific address lists only that address.

While the host listens beyond loopback and `CABOOSE_MDNS` is on, it advertises DNS-SD
service `_caboose._tcp` over mDNS, IPv4 only, on the same LAN interfaces:

| TXT key | Value |
| --- | --- |
| `v` | `1`, the record's version |
| `id` | 16 hex characters, random and kept in `${CABOOSE_IMAGE_ROOT}/host-id`, so a phone recognises a host whose address or name changed |
| `name` | The owner computer's name, or `Caboose on <machine name>` while it is still `Caboose`; also the instance name |
| `path` | `/`, the API's base path |

The record's host name is `caboose-<first 8 characters of id>.local`. A client must treat
unknown keys as reserved and a higher `v` as possibly incompatible.

### Lifecycle

The computer has one state: `parked`, `waking`, `running`, `parking`, `restarting` or
`error`. Wake, park and restart are serialized, so none can race another or a launch.

- **Wake** (`POST /v1/session`, and routes that wake on demand) starts or restores the
  computer, configures its network and clock, writes the display token, starts the file
  service, starts the owner's display and reads its launch environment. A microVM whose
  snapshot cannot be restored is reported as an error rather than cold-booted.
- **Leases.** Each open display, control or terminal WebSocket holds a lease, as do running agent
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

### Accounts and tenants

Accounts belong to **administrators**, who use the web console. The people whose computers
they run need none: each person has a stable record within a tenant, and each assigned
computer references that person. A person may optionally link to an administrator account;
that link itself grants no console access. A **tenant** is a household or a team: its computers, its administrators, and quotas on
what its computers are given between them. The first account is the host's **operator**,
who sees every tenant, makes tenants and sets quotas; the owner token has the same reach.

Accounts, sessions, tenants and memberships are AppKit's identity schema
(`@braedonsaunders/appkit-db`, with its migrations), signed in through
`@braedonsaunders/appkit-auth` (Better Auth, email and password); invitations are
Caboose's own table. Caboose people and computer ownership are relational tables in the
same database, with a composite foreign key enforcing that a computer’s person belongs
to its tenant. Deleting a person or tenant with computers is refused. They live in Postgres when `CABOOSE_DATABASE_URL` is set, and
otherwise in an embedded PGlite database in `identity/`, served to the host over a Unix
socket only its user can open. The socket lives in a short, private temporary directory
removed when the database closes. Quotas are `tenants.settings.quotas`.

**Setting the host up.** Until the first account exists the host is unclaimed. It writes a
one-time code to `${CABOOSE_IMAGE_ROOT}/setup-code` (mode 0600) and logs
`Set up Caboose: http://<address>:<port>/setup?code=<code>`. The `/setup` page is served
only with that code, including on loopback: a local reverse proxy can relay remote visitors
without forwarding headers. The setup API requires the same code. Once claimed the page
redirects to `/`. Claiming atomically creates the operator’s account, first tenant and
person and assigns the existing owner computer to that person. Other unassigned legacy
computers join that tenant and remain marked Assignment required until a person is selected.
It deletes the code file and signs the browser in. An owner-token console shows a persistent
setup banner while unclaimed; its authenticated setup-link endpoint returns the existing
one-time link. New tenants and computers require completed setup. Existing computers and
phone tokens keep working during setup.

On first database-backed startup, the host imports `computers.json` in one transaction,
retaining computer ids, slots, creation times and existing tenant assignments. Each known
legacy person name creates its own person record, never merging people merely by name.
Unknown assignments remain explicitly pending. The JSON file stays intact as a migration
backup and is not subsequently read as authority; the database supplies the registry.
Back up the identity database alongside computer disks. Unassigned legacy computers are
visible to the operator and their existing tenant administrators, not to other tenants.

**Invitations** are links an administrator copies: `/invite?token=<token>`, single-use,
valid for seven days, kept as a SHA-256. A new administrator chooses a name and password;
someone with an account confirms it with their password. A tenant keeps at least one
administrator.

**Quotas** are `memoryMb`, `vcpus` and `diskGb`, each null for no limit. Memory and vCPUs
count what the tenant's computers are set to be given; disk counts what their microVM disks
and parked memory use on the host (a container's disk is not measured). Memory and vCPUs are
checked when a computer is made, resized or moved, and all three when it wakes.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/v1/setup` | **No account.** `{ claimed, codeRequired }` |
| `POST` | `/v1/setup` | **No account.** `{ name, email, password, tenantName, code }` → 201, with the session cookie. `code` is required from every address; 409 once claimed |
| `POST` | `/v1/setup/link` | Owner token only; `{ path }` containing the one-time setup link; 409 once claimed |
| `GET`, `POST` | `/v1/tenants/:id/people` | Lists `{ people: [{ id, tenantId, name, userId, createdAt }] }`; creates a phone user with `{ name }`, no login required |
| `PATCH`, `DELETE` | `/v1/people/:id` | Rename `{ name }` or delete a person in an administered tenant; deletion refuses assigned computers |
| any | `/v1/auth/*` | Better Auth: `POST /v1/auth/sign-in/email { email, password }`, `POST /v1/auth/sign-out`, `GET /v1/auth/get-session`, `POST /v1/auth/change-password`. Sign-up is closed; accounts come from setup and invitations |
| `GET` | `/v1/me` | `{ kind: "owner" \| "admin", user: { id, name, email } \| null, operator, setupRequired, tenants: [{ id, name, quotas, createdAt }] }` |
| `GET`, `POST` | `/v1/tenants` | The tenants the caller administers, each with `usage: { computers, memoryMb, vcpus, diskBytes }`; the operator makes one with `{ name, quotas? }` |
| `GET`, `PATCH`, `DELETE` | `/v1/tenants/:id` | One tenant; `PATCH { name?, quotas? }` (quotas: the operator only); `DELETE` (the operator, once it has no computers) |
| `GET` | `/v1/tenants/:id/administrators` | `{ administrators: [{ userId, name, email, operator, joinedAt }] }` |
| `DELETE` | `/v1/tenants/:id/administrators/:userId` | Takes an administrator off the tenant; 409 for its last |
| `GET`, `POST` | `/v1/tenants/:id/invites` | Waiting invitations; `POST { email }` → 201 `{ invite, token }`, the token shown only here |
| `DELETE` | `/v1/tenants/:id/invites/:invite` | Withdraws an invitation |
| `GET` | `/v1/invites/:token` | **No account.** `{ tenantName, email, expiresAt, accountExists }` |
| `POST` | `/v1/invites/:token/accept` | **No account.** `{ name?, password }` → the session cookie; `name` for a new account |

A tenant an administrator does not administer answers 404, as if it were not there.

### Authentication

A request is from one of three kinds of caller:

- **The owner token**, `Authorization: Bearer <owner token>`, compared as SHA-256 digests in
  constant time. It reaches every route and every computer, as the operator does.
- **An administrator**, by the session cookie Better Auth sets at sign-in (30 days,
  renewed daily). An administrator reaches the computers and tenants they administer; only
  the operator reaches `/v1/health`, `/v1/host`, `/v1/host/*` and the computer routes without
  a computer in the path.
  Cookie transport follows the browser's address: HTTPS uses Secure-prefixed cookies;
  direct LAN HTTP uses host-only HTTP cookies. Both use the same accounts and session
  store, even when `CABOOSE_PUBLIC_URL` advertises HTTPS. Sign-out clears the matching
  transport's cookies.
- **A phone token**, which reaches only its own computer's routes, without a computer in the
  path; `/v1/health`, `/v1/host`, `/v1/host/*`, `/v1/me`, `/v1/tenants…` and `/v1/computers…` answer it 403.

`POST /v1/pair`, setup, invitations and `/v1/auth/*` need none of these. Any other `/v1`
route, and every WebSocket upgrade, answers 401 without one.

The built web console is served from `CABOOSE_WEB_ROOT` with an SPA fallback for non-API
`GET`s. Static files are public, except `/setup` before the host is claimed. The console
signs in with an account; signed in with the owner token instead, it keeps the token in
session storage and sends it only as an `Authorization` header.

### Conventions

Request and response bodies are JSON unless stated. A JSON body must be an object of at
most 64 KiB (15 MiB for task start and reply). Errors are `{ error: string }`:

| Status | Meaning |
| --- | --- |
| 400 | Invalid input, including unknown fields where a route rejects them |
| 401 | Missing or unknown token or session |
| 403 | A phone, or an administrator who is not the operator, on a route that is not theirs |
| 404 | Unknown route, task, agent, element or device |
| 409 | The computer is not running (or is restarting, or being deleted), its display is not ready, a conflicting operation is in progress, or a tenant's quota would be exceeded |
| 429 | Too many wrong pairing codes, or sign-in attempts |
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
| `GET` | `/v1/apps` | Launchable applications from the guest's desktop entries: `[{ id, name, icon (PNG data URL), categories, exec, actions }]`. `actions` is the entry's desktop actions (`Actions=` with a `[Desktop Action …]` group, a Name, and an Exec unless the entry is D-Bus activated): at most 16 `{ id, name }`, ids `[A-Za-z0-9-]{1,64}`, names at most 100 characters |
| `POST` | `/v1/apps/:id/launch` | Start a desktop entry on the owner's display with its launch environment → `{ launched: true }`. An optional `{ action }` runs one of its `actions` instead (GLib runs its Exec or activates it over D-Bus); 400 for an invalid id, 404 for an entry or action the computer does not have |
| `POST` | `/v1/open` | `{ url }` → `{ opened: true }`. Open an `http(s)` URL (at most 8192 characters, no spaces or control characters) with the default handler on the owner's display |
| `GET` | `/v1/health` | microVM: `{ host, hypervisor: "cloud-hypervisor" \| "virtualization", kvm, desk, machine }` with appkit-desk's stats (`kvm` applies only to Cloud Hypervisor); container: `{ host, runtime: "container", gpu, container, running, machine }`; both add `image`. `machine` is `{ memoryMb, availableMemoryMb, cpus, disk: { totalBytes, freeBytes } \| null }`: the machine the computers share, with `disk` the volume holding `CABOOSE_IMAGE_ROOT` (null when it cannot be read). `image` is `{ state: "ready" \| "fetching" \| "failed" \| "missing", reference: string \| null, receivedBytes?, totalBytes?, message? }`: the computer's image ([Published images](#published-images)); `missing` means no reference to fetch from |
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
| `catalog.progress` | `{ id, operation, phase, message?, stage?, value?, downloadedBytes?, totalBytes? }` | A catalog operation is `queued`, `installing`, `finished` or `failed`. Stages are `preparing`, `downloading`, `verifying`, `refreshing`, `installing`, `configuring`, `removing` and `finished`. Only `downloading` has a measured `value` (0–1) and byte counts; other stages have `value: null` |
| `catalog.changed` | `{ id? }` | After each application in an operation, and once when the operation ends |
| `job.progress` | `{ job: { id, kind, title, status, detail } }` | A Craft job starts, succeeds or fails |
| `agent.task.*` | see [Agents](#tasks) | Agent task activity |
| `media.playing`, `media.stopped` | see [Media handoff](#media-handoff) | |
| `phone.open`, `phone.share`, `phone.print` | see [Phone handoff](#phone-handoff) | Only to sockets opened with `?phone=1` |
| `bridge.request`, `bridge.cancel` | see [native bridge](native-bridge.md#host) | A Linux application's file request, and its withdrawal. Only to sockets opened with `?phone=1` |
| `now-playing.changed`, `now-playing.stopped` | see [native bridge](native-bridge.md#now-playing-relay) | The computer's media player for Now Playing, while a display client is connected |

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
  clients: { display: number, control: number, terminal: number },
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
**wakes** the computer and holds a lease until its response completes. Disconnecting a client
cancels its relay, including when it disconnects while waiting for the computer. A relay
with no transfer progress for 60 seconds is cancelled: the host returns 504 if the response
has not started, or closes an incomplete response. Active transfers have no total duration
limit. The host forwards
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

### Terminal

A terminal is a WebSocket relayed to the guest's terminal service. Each connection is one
session; the session, a shell on the computer, outlives it.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/v1/terminal?cols=&rows=` | **WebSocket.** A new session of `cols` × `rows` (1–1000 × 1–500) |
| `GET` | `/v1/terminal?cols=&rows=&session=<id>[&offset=<n>]` | **WebSocket.** Reattach to a session, resized to `cols` × `rows`; `offset` is how much of its output this client already holds |
| `GET` | `/v1/terminal/sessions` | `{ sessions: [{ id, title, command, cwd, cols, rows, created, attached }] }`, oldest first: the title the shell last set, the foreground program and its directory (each null when unknown), `created` in Unix milliseconds |
| `DELETE` | `/v1/terminal/sessions/:id` | Hang up the session's shell → `{ hungUp: true }`; 404 when it has ended |

The upgrade answers 409 while the computer is not running, unless the query has `wake=1`,
which **wakes** it first; 400 for an invalid query, and 429 when the client (the owner, or
one phone) already has 8 terminals open. Session ids are 32 hex characters.

- **Messages.** Binary messages are terminal bytes: the client's are input, the host's are
  output. Text messages are JSON control messages. The client sends
  `{ type: "resize", cols, rows }` and `{ type: "hangup" }`. The host sends
  `{ type: "hello", session, offset, reset, modes? }` first, then output, and
  `{ type: "exit", code }` or `{ type: "exit", code: null, signal }` when the shell ends,
  before closing with 1000. The host checks every control message field by field in both
  directions and re-encodes it; anything else closes the socket with 4400 (from the client)
  or 1011 (from the guest).
- **Reattach.** Output is a byte stream; `hello.offset` is the position of the first byte
  that follows. With `offset` in the query and still kept (the last 256 KiB), the stream
  continues from it with `reset: false`. Otherwise the client clears its terminal
  (`reset: true`), applies `modes` (`{ "<DEC private mode>": set }` for cursor keys, cursor
  visibility, the alternate screen, mouse reporting, focus events and bracketed paste, when
  the kept output no longer sets them) and receives what is kept. A full-screen program on
  the alternate screen is resized and restored so it repaints.
- **Closes.** 4404 `session ended` (it exited, was hung up, or the computer restarted);
  4001 `attached elsewhere` (another connection took the session; one is attached at a
  time); 4408 `idle` (nothing either way for 15 minutes); 1013 `too many terminal
  sessions`; 1011 when the guest cannot be reached. A park closes the socket and keeps the
  session; a restart ends it.
- **Flow.** Each client connection gets its own guest connection. As in the display relay,
  each side is paused until the other has flushed, so a slow client slows the shell rather
  than filling a buffer; payloads are at most 1 MiB. With no client, a session's output is
  kept only in its 256 KiB replay.

### Catalog routes

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/v1/catalog/storefront` | The Library's front page (§ Catalog): `{ groups: [{ id, title, category, apps }], error }`, Popular first (`category` `""`), then each category with apps. Never wakes the computer |
| `GET` | `/v1/catalog/discover?q=&category=&offset=` | The Library, ranked (§ Catalog), 40 at a time: `{ apps, total, offset, limit, categories, error }`. `category` is one of `categories` (Create, Video & Audio, Make, Productivity, Development, Games, Internet, Learn, Science, System, Utilities). `error` explains a Flathub index that could not be fetched; curated entries are still listed. Never wakes the computer |
| `GET` | `/v1/catalog` | `{ apps }`: every curated entry and every other application that is installed, being changed or failed; an application this list leaves out is not installed. Each has `origin` (`caboose`, `flathub` or `debian`), `curated`, `categories`, `developer`, `verified`, `license`, `installs`, `installedVersion`, `latestVersion`, `updateAvailable`, `lastError`, `interrupted`, `active` (a guest operation runs), `unavailable` (why this computer cannot install it, or null), `iconData` and `progress` |
| `POST` | `/v1/catalog/:id/install`, `/update` | Queue an operation → 202 `{ accepted: true }`. A Flathub id is `flathub-<app id>`, URL-encoded |
| `DELETE` | `/v1/catalog/:id` | Queue removal → 202 |
| `POST` | `/v1/catalog/:id/run` | **Wakes.** Run a Craft job (below) |

Catalog mutations answer 409 while the computer is not running, another catalog operation
runs, or a Craft job runs; 404 for an unknown application.

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
follow the releases' CLIs as documented at:
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
replayed. The token scopes the connection to its computer.

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

### Native bridge

File requests from the computer's portal, the phone's appearance and location, and the
computer's Now Playing, relayed with the routes `/v1/bridge/*` and `/v1/now-playing*` and
the control events above. The contract is [native-bridge.md](native-bridge.md#host).

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

Each agent is resolved for the native guest architecture (`linux-x86_64` on amd64,
`linux-aarch64` on arm64), preferring a binary the registry pins by
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

### Persistent agent profiles

Each computer has private host-owned `agent-profiles.json` identity records, available
while the guest is parked. A profile has a UUID, name, description, instructions, registry
agent, approval default, archive flag and owner-editable memories with stable UUIDs.
`GET/POST /v1/agent/profiles` list/create profiles; `GET/PATCH /v1/agent/profiles/:id`
read/edit them. `POST /v1/agent/profiles/:id/memories` adds a memory;
`PATCH/DELETE /v1/agent/profiles/:id/memories/:memoryId` edits/removes one. These routes
use the same computer/tenant authorization as tasks. Writes are serialized and atomically
persisted before acknowledgment; corrupt state fails closed.

A task request can select `profileId`. The host resolves its provider and approval defaults
(ask unless the owner chose auto), snapshots instructions and memories, and uses the fixed
`/home/caboose/AgentWorkspaces/<profile UUID>` working directory. Each conversation still
has its own task directory and transcript. The guest receives the snapshot in
`profile-instructions.txt` with `profileId` in `task.json` and `profile-id` for host restore.
The runner supplies this context on every turn without adding it to the owner's transcript.
Profile edits apply to new conversations; existing conversations retain their admitted
snapshot. An archived profile cannot start a conversation; restoring it retains its memories
and workspace. Raw task requests cannot supply arbitrary instructions or workspace paths.
Stable task-ID retries compare the profile snapshot as well as the original prompt/files.

### The runner

`caboose-agentd` (`guest/agentd`, installed at `/opt/caboose/agentd`) is the ACP client.
The guest channel carries command arguments, not stdin, so the host never speaks ACP
itself: it starts one runner per task, detached (`setsid`), as `caboose`, and the two
exchange files in the task directory `/home/caboose/Agents/<task id>/`. The file formats are
specified in `guest/agentd/README.md`; in short:

- The host writes `task.json` `{ agent: <resolved spec>, cwd, approvals, idleMs,
  craftServers, profileId? }`, prompts as `inbox/<turn, 6 digits>.prompt.json`, cancels as
  `inbox/cancel-<n>.json`, and decisions as `approvals/<requestId>.decision`. The runner
  writes `transcript.jsonl`, `draft.json`, `approvals/<requestId>.json`, `session` and
  `receipts/<turn>.json`; the launch script records `pid` and `exit-code`. The host's
  `delivery.json` journal stores ordered admitted replies, operation fingerprints and the
  current delivery intent and monotonic turn count; `deliveries/<turn>.json` retains each
  published prompt. Journal and prompt publication use file fsync, atomic rename and directory fsync. A runner creates
  an exclusive, fsynced claim before removing an inbox prompt or calling ACP, and atomically
  records completion after fsync of the terminal transcript event.
- `initialize` advertises file reads and writes (resolved paths, refused outside
  `/home/caboose`, at most 10 MB), no terminals, and terminal sign-in.
- Each turn is `session/prompt` with a text block, and each attachment as an `image` block
  when the agent accepts images and it is a PNG, JPEG, GIF or WebP under 10 MB, otherwise
  as a `resource_link` to its `file://` path.
- The transcript is the same for every agent: `user` (a turn began), `session`
  (`continuity: new | resume | load | recap`), `text` and `thought`, `tool` and
  `tool_update` (title, kind, status), `plan`, `mode`, `permission`, `usage`, and exactly
  one of `turn_end` (ACP `stopReason` and the turn's last message as `summary`),
  `turn_failed` or `auth_required` per completed turn, each with its turn number. Interrupted
  runners leave an incomplete claim rather than fabricating a terminal result.
- While a message or thought is arriving, the runner atomically saves `draft.json` at most
  every 200 ms: `{ turn, after, kind: "text" | "thought", text }`, with at most the last
  16000 characters and `after` the transcript byte position before that message. It removes
  the draft before committing the complete message to the transcript. The host reads the
  transcript before the draft, validates every field, and publishes a replaceable snapshot
  only when its position matches the bytes consumed and its turn is current. A draft is
  cleared on commit, turn change, cancellation or finish; it is never another transcript entry.
- After a turn the runner keeps the agent and its session for `CABOOSE_AGENT_IDLE_MS`
  waiting for a reply, then exits 0. A later reply starts a new runner, which reopens the
  conversation with `session/resume` if the agent advertises it, else `session/load` (the
  replayed history is not written again), else `session/new` with a recap of the earlier
  turns at the start of the prompt; that turn's summary says so.

### Persistent routine scheduler

The host's `AgentRoutines` module stores per-computer routine definitions, recurrence
cursors and bounded run history in a private durable file. It uses AppKit recurrence for
IANA timezone schedules. Cursor advancement and a stable task UUID with its exact launch
snapshot are reserved atomically before waking the computer. The runtime adapter acquires
the existing computer lease, restores and looks up that UUID, then revalidates the routine
and profile before idempotent task admission. Paused, deleted, archived or edited records
cannot admit stale reserved work. One outstanding run per routine is allowed; overlap
is skipped. Missed runs use explicit skip with delivery grace or coalesce policies, with
no archive/restore backlog. See [the scheduler contract](agent-routines.md) for the adapter,
delayed-execution policies, persistence/recovery requirements and focused tests.

### Tasks

- **Start.** `POST /v1/agent/tasks` names an agent by registry id, or uses the owner's
  `defaultAgent`. The ids `claude` and `codex` are accepted as `claude-acp` and
  `codex-acp`. The host resolves the agent (installed version first), starts the agent seat,
  writes the attachments, `task.json` and the first prompt, and starts the runner. The
  task's `prompt` stays as the owner wrote it. Internally,
  `AgentTasks.start(input, options?: { id?: string })` accepts a canonical lowercase UUID.
  Repeating that id finds its persisted task, including after a lost launch response; a
  different original payload conflicts. Without an id the host generates one. The task
  directory is admitted by renaming a fully staged directory before launching its runner.
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
  turn's. A reply to a running or paused task waits in the task's `queued` list (at most 10
  replies, 32000 characters, four files and 10 MB decoded together). Files are staged in
  distinct per-message directories and flushed before the queue journal commits. Admission
  is persisted before success is returned, and both replies and files survive a host restart.
  An optional `operationId` is an opaque, task-local string of 1–200 characters without
  control characters. Repeating it with the original prompt and file names, types and
  contents returns the existing task without adding a reply or turn; a changed payload
  conflicts. Task ids and reply operations compare the original request fields, independently
  of later registry or default-agent changes. Each task retains at most 2048 operation
  records in a journal bounded to 1 MiB; new admissions beyond either limit conflict.
  Queue admission, cancellation, Send Now and delivery transitions are serialized per task;
  polling cannot dispatch a second copy of a claimed transition.
  When the turn ends, everything waiting goes to the agent as one turn, the replies
  separated by blank lines, under the same lease and without an `agent.task.finished` for
  the turn in between. Cancel drops what is waiting; a turn that ends signed out keeps it
  for the next reply, which sends it first. Send Now cancels the current turn and delivers
  the waiting prompts and their staged files together, retaining durable admission if
  delivery fails. An intent precedes publication, and a published batch remains in the
  journal until a matching receipt or transcript proves it was taken.
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
  requests. Turn boundaries trigger bounded journal and receipt reconciliation. A runner
  that exits before its turn ends fails the task; a claim or ambiguous delivery reports
  uncertainty, while an unclaimed failure retains the end of its stderr.
- **Restore.** Each task directory records its agent, prompt, approval mode and turn
  count, so a restarted host rebuilds the task list from the guest: a task whose last turn
  ended is finished with that turn's result, one whose runner is still working takes the
  lease again, and either can be replied to. Recovery reads every task directory, restores
  admitted replies in order and resumes proven unclaimed delivery. Completion receipts or
  terminal transcript events reconcile runners loaded before an upgrade, which do not emit
  receipts. Their ambiguous `turn_failed` events remain uncertain, because they cannot
  distinguish an execution interruption from a reported error. A missing inbox by itself
  never proves delivery. An interrupted claim, an agent process dying during ACP, or
  publication without an inbox or result becomes a failed task
  with `delivery: { turn, state: "uncertain", message }`; its intent and remaining replies
  stay on disk. This task does not send further replies: inspect its transcript and published
  prompt before starting another task, because external actions may already have happened.
  Corrupt or oversized journals block mutation instead of discarding their contents. A task
  directory without `task.json` is listed but cannot be continued.
- **Lifetime.** Tasks keep running while the phone is locked. The host holds a lease while
  any task is running or paused, so the computer is not parked under a working agent.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/v1/agents` | The agents this computer can run (below). Never wakes the computer; shows the last known installed state while it is parked |
| `POST` | `/v1/agents/:id/install` | → `{ agent }`. Prefetch the registry's current version and learn its sign-in methods; can take up to 15 minutes. 404 for an id not in the registry, 409 while the computer is not running or has no runner, 502 when the install fails |
| `PUT` | `/v1/agents/:id/env` | `{ set?: { NAME: value }, remove?: [NAME] }` → `{ env: [NAME] }`. Names are shell-style; values are one line of at most 8192 characters. 400 for invalid input, 409 while the computer is not running |
| `POST` | `/v1/agents/:id/sign-in` | `{ methodId, on?: "phone" \| "display" }` → `{ started: true, method: { id, name, description?, type }, attempt }`. `on` defaults to `"display"`. Each start is a new attempt that replaces the agent's running one ([Signing in](#signing-in)). 400 for an unknown method |
| `POST` | `/v1/agents/:id/sign-in/callback` | `{ attempt, url }` → `{ delivered: true, status }`: hands the agent waiting on the computer's loopback the address sign-in `attempt`'s page sent the browser back to. `url` must be `http://localhost:<port>/…` (or `127.0.0.1`, `[::1]`). 400 for any other address or without an attempt, 409 unless `attempt` is the agent's running sign-in on the phone, 502 when nothing answers there |
| `POST` | `/v1/agents/:id/sign-in/cancel` | `{ attempt }` → `{ cancelled }`: stops the agent's running sign-in if it is `attempt`; `cancelled: false` leaves any other attempt running. 400 without an attempt |
| `POST` | `/v1/agent/tasks` | `{ prompt, agent?, approvals?: "ask" \| "auto", craftMcp?: boolean, attachments?: [{ name, type?, data (base64) }] }` → `{ id }`. 400 when no agent is given and no default is set; 404 for an id that is not in the registry or installed |
| `GET` | `/v1/agent/tasks` | Recent tasks, newest first |
| `GET` | `/v1/agent/tasks/:id/transcript` | → `{ entries: TranscriptEntry[], truncated }`: every turn of the task's conversation, read from the end of its `transcript.jsonl` (at most 2 MiB; `truncated` when earlier lines were left out). 404 for an unknown task, 409 while the computer is not running |
| `POST` | `/v1/agent/tasks/:id/reply` | `{ prompt, attachments?: [{ name, type?, data (base64) }], operationId? }` → `{ task }`. While the task is running or paused the reply waits in `task.queued`. 409 for a task that cannot be continued or when too much is already waiting; 404 for an unknown task |
| `POST` | `/v1/agent/tasks/:id/send-now` | → `{ task }`. Stops the current turn and sends its queued prompts and files immediately. 409 when nothing is waiting or a next turn is already starting; 404 for an unknown task |
| `POST` | `/v1/agent/tasks/:id/approvals/:requestId` | `{ allow: boolean, message?, optionId? }` → `{ resolved }`; `false` when that request is no longer waiting |
| `POST` | `/v1/agent/tasks/:id/cancel` | → `{ cancelled }` |
| `POST` | `/v1/agent/tasks/:id/pause` | → `{ paused }`; the task becomes `paused` |
| `POST` | `/v1/agent/tasks/:id/resume` | → `{ resumed }` |

Prompts are 1–32000 characters after trimming. Attachments are at most 4 files and 10 MB
decoded together on both start and reply; names are made safe and unique, and files are written to the task's
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
    signInStatus?: { methodId: string, status: "running" | "succeeded" | "failed", attempt?: string, on?: "phone" | "display",
                     url?: string, terminal?: string, message?: string, startedAt?: string, finishedAt?: string },
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
  signIn?: Array<{ id: string, name: string, description?: string, type: "agent" | "terminal" }>,  // when the agent was signed out
  queued?: string[],              // replies waiting for the current turn to end, oldest first
  queuedAttachments?: string[][], // guest file paths, aligned with queued
  draft?: { turn: number, kind: "text" | "thought", text: string }, // live, replaceable message snapshot
  delivery?: { turn: number, state: "uncertain", message: string }
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
| `agent.task.queued` | `{ id, queued: string[], queuedAttachments?: string[][] }`: the replies waiting for the turn to end changed |
| `agent.task.approval` | `{ id, request: { id, tool, summary, options? } }`, once per request |
| `agent.task.approval.resolved` | `{ id, requestId, allow }` |
| `agent.task.draft` | `{ id, draft: { turn, kind: "text" \| "thought", text } \| null }`: a changed or cleared live snapshot, at the host's one-second polling cadence |
| `agent.task.event` | `{ id, turn, entry: TranscriptEntry }`: each entry of the current turn as the host reads it |

A `TranscriptEntry` is one line of the runner's transcript (guest/agentd/README.md), checked
and trimmed, without the `session` and `mode` bookkeeping; each may carry `at`:

```ts
| { type: "user", turn, text, attachments?: string[] }
| { type: "text" | "thought" | "notice", text }                 // at most 16000 characters
| { type: "tool" | "tool_update", toolId, title, kind, status, detail? }  // ACP tool kind and status
| { type: "plan", entries: Array<{ content, status }> }
| { type: "permission", requestId: string | null, tool, summary, auto }
| { type: "permission_resolved", requestId, allow, message? }
| { type: "usage", used, size, cost?: { amount, currency } }
| { type: "turn_end", turn, stopReason, summary }
| { type: "turn_failed" | "auth_required", turn, message }
```

### Signing in

Agents announce their sign-in methods in ACP `initialize`, which the runner records when an
agent is installed, probed or run. A method is one of two kinds:

- **`agent`:** the runner calls ACP `authenticate`, and the agent opens its own sign-in
  page, usually with its callback on the computer's localhost.
- **`terminal`:** the runner runs the agent's own program with the method's `args` in place
  of the registry's, and its `env` over the registry's, in a terminal. Exit status 0 is
  success; the runner then initializes the agent again.

A sign-in runs `on` the phone or the owner's display:

- **On the phone** (the app's choice), nothing opens on the display. The runner removes the
  desktop's variables (`DISPLAY`, `WAYLAND_DISPLAY`, `XDG_CURRENT_DESKTOP` and the like) and
  puts first on `PATH` its own `xdg-open`, `x-www-browser`, `www-browser`,
  `sensible-browser` and `gnome-www-browser`, with `BROWSER` naming one of them; each
  records the web page it is given instead of opening it, and the latest is `signInStatus.url`.
  The app shows that page in a private in-app browser. When the page sends the browser back
  to the computer's loopback (`http://localhost:<port>/…`), the app does not load it but
  sends it to `POST /v1/agents/:id/sign-in/callback`, and the runner fetches it inside the
  computer, following redirects that stay on the loopback, so the agent's own callback
  server receives it. A `terminal` method runs in a session of the guest terminal service
  (`/start`), reported as `signInStatus.terminal`; the app attaches to it through
  `/v1/terminal` to answer the program's prompts. Its environment reaches the session in a
  file of mode 0600 that the session reads and removes. Providers that refuse to sign in
  inside an app's browser (Google's accounts) need another of the page's options, or the
  display.
- **On the display**, with the launch environment from `/run/caboose/display.env`, which
  the host passes to the runner, an `agent` method's page opens in the computer's browser
  and a `terminal` method in a terminal window.

Every start is a new **attempt**, a UUID the host chooses and returns, recorded in
`signInStatus.attempt`. Starting replaces the agent's running attempt, whatever its `on`
and whoever started it; a caller without an attempt (an app from before them) can only
start. Delivering a callback and cancelling name their attempt and do nothing to any other,
so a sheet left open from an older attempt never reaches a newer one. In the runner,
starting, replacing, cancelling, every record of progress and delivering a callback each
read and act on `sign-in.json` holding the agent's sign-in lock (`sign-in.lock`, created
exclusively; one whose holder process is gone, that was never written, or that is older than
two minutes is taken over, through a second lock so only one process takes it). A runner
records progress only while its attempt is still the agent's and still running; once
replaced, cancelled or finished it hangs up its terminal session, removes its own files and
exits. Each attempt keeps its files (page list, browser commands, scripts) in its own
directory, `agents/<id>/attempts/<attempt>/`, so no cleanup reaches another attempt's.
Stopping an attempt signals the runner's process
group only after reading the runner's command line to confirm it is that attempt's runner,
with SIGKILL after three seconds, and hangs up its terminal session. Progress is reported as
`signInStatus` in `GET /v1/agents` (`~/.local/share/caboose/agents/<id>/sign-in.json`).
Credentials stay wherever the agent keeps them in the owner's home.

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
the server timeline, and vsync pacing. Audio uses an explicit server/host clock anchor,
cleared on interruption; renderer timebase updates never drive backlog recovery. Live
window and motion pictures present immediately, while passthrough video shares the audio
clock. Each window fills a `RemoteWindow` and its
Metal `WindowSurface`. Decoding uses `VTDecompressionSession` for H.264, HEVC and, where the
device has a hardware decoder, AV1, and ImageIO for PNG and WebP tiles. Every write to a
window's texture is a blit on one shared Metal queue, which runs command buffers in commit
order, so no draw waits for the GPU before the next frame is decoded and acknowledged.
CabooseKit is unit-tested on macOS, including the protocol's golden vectors.

The iOS app negotiates whole-window video by default: it omits `video_decoders`, so the
computer encodes video into the same window picture as its controls and returns unsupported
passthrough streams to server decoding. The layered-video client remains explicitly
negotiated for protocol checks. PCM playback uses decoded sample durations to join adjacent
packets despite capture-timestamp jitter; gaps over 200 ms retain the server timeline.
The phone estimates the source sample-clock rate over a bounded rolling arrival window,
then adjusts playback continuously with pitch preservation. This accommodates virtual
machines whose clocks run at a different rate without repeatedly discarding sound.
The initial jitter buffer is 120 ms, grows by 20 ms after underruns up to 240 ms, and
only discards a backlog beyond another 300 ms. Silence resets rate measurement; stopping
playback resets the clock and estimator.

The window picture and its video layers use the same mapping from the confirmed surface
size to the view's bounds, including while a resize stretches the previous picture.
Resize metadata does not change that pixel basis until the replacement frame decodes.
Video clips intersect the window bounds without rescaling the decoded picture. Only the
active presentation hosts a stream's playback layer; an inactive Yard relinquishes it to
the app card, and a detached view releases its layers.

- **Windows.** A Linux window opened from Home or Apps is an app card: full screen, sized
  to the phone. On a device with a vertical toolbar, the card starts with its controls
  hidden and fills the screen. A swipe inward from the toolbar edge reveals the native
  toolbar over the card; a swipe outward on its controls or the Hide window controls button
  hides it. The toolbar uses the selected wallpaper as its background, with the shell's
  dusk colours while no wallpaper picture is available. The opposite edge switches to the
  neighbouring app; where there is no vertical toolbar, either edge switches apps.
  Back, the app switcher, Keyboard and Window Options use the system toolbar. The window
  title is in the switcher; Options includes Ask Agent, redraw and close. The switcher and
  options open system action dialogs outside the toolbar's overflow group. Full Screen
  hides the controls; its accessible top handle brings them back.
  Exit App Full Screen in Options focuses the app, sends an Escape press and release,
  and clears the guest fullscreen and maximized states. It is available even before the
  app reports fullscreen. The tile's menu offers the same action; pulling an app-requested
  fullscreen window back into its tile also sends Escape. Hardware Escape reaches the app.
  Single taps, pointer clicks, double taps and native touch taps use the same bounded
  keyboard-focus request: text-input-v3 decides whether editing began, with the guest's
  text cursor as fallback. A double tap that selects or zooms does not itself request the
  keyboard. Dismissing the keyboard, leaving the view and Return in a non-code app cancel
  the pending request.
  An external display shows the windows floating, resizing and
  stacking, with a dock and Launchpad, as does an iPad's Desktop tab set to Free. Each
  window there has a title bar above it with Close, Minimize and Zoom at its leading edge,
  drawn and hit-tested from one `WindowTitleBar`: Mac-sized circles in a Mac-sized bar under
  a pointer, which show their symbols on hover; under touch, the same circles further apart
  in a bar at least 32 points tall, with their symbols always shown.
  Dragging a title bar to a side edge snaps the window to that half, near a corner to that
  quarter (where quarters are at least 280 × 200 points), and to the top edge maximizes it,
  with an outline of where it will go; elsewhere its edges pull onto the desktop's and its
  neighbours' within ten points. Pulled out of a snap, a window takes back its own size
  under the finger. Each window keeps a place (`FreeDesktopLayout`): the frame last given
  by hand and the work area it was given in, or a snap. Every other desktop size, after a
  rotation, a TV, a zoom or a relaunch, is derived from that pair, keeping the free space
  on each side in proportion, so a layout never drifts and returns exactly when the size
  does. Places are kept on the phone per computer, one arrangement for its own screen and
  one for an external display, at most 64, and only for a window with the same known app
  class that had the place. Minimized windows keep their dock state with their places.
  A window's place is forgotten when it closes while the display session is ready.
  ⌘⌥ with the arrows brings the nearest window that way forward, with ⇧ snaps the front
  window left or right, maximizes it (↑) or restores it (↓); F zooms, M minimizes, W closes,
  A opens Launchpad and Return a terminal.
- **Laptop layout.** Desktop and app cards use the same `LaptopContainer`. On iOS 27.1,
  a view-scoped `UIHingeInteraction` and horizontal division reserved region select the
  upper content and lower controls for a partially folded inner display. A vertical book
  fold does not activate it. Screen Layout offers Automatic, Tablet and Laptop overrides;
  compact viewports keep the ordinary layout. The system keyboard's measured intersection
  with that view takes precedence over the fold, so it cannot cover the upper app. The
  lower panel owns the existing `RemoteTextInputView`/`KeyBar`, with Keyboard, Trackpad
  and Combo choices. Its trailing rail contains window switching, settings,
  power and navigation; the system-wide bars are hidden while Laptop is active. Opening
  a window from the Laptop desktop focuses it there, without a separate full-screen card
  or Full Screen/Exit App Full Screen controls. The
  native keyboard occupies the lower edge; controls never move above the hinge. Combo
  uses a full-width trackpad in the upper third of the lower panel and a custom keyboard
  with the shared shortcut header in its lower two thirds. Its globe button opens the
  native keyboard for other languages, emoji and dictation. The dock becomes a thin, full-width taskbar at the top of
  the lower half. Caboose title bars are hidden above the hinge; app-owned chrome remains
  part of the guest surface. Pointer hit testing includes the relocated dock, with separate
  saved Laptop positions, without changing the tablet arrangement. App cards target their current
  window. Upper surfaces keep direct touch but do not compete for first responder. The same bounded text-focus policy
  follows clicks and double clicks. Detaching or changing target releases a held drag
  and cancels focus requests. With an external display the upper phone region offers
  window previews and switching without resizing or taking video layers from the monitor.
- **Quick Switch.** On both desktops, ⌥Tab (iPadOS keeps ⌘Tab for itself; Alt+Tab is the
  Linux habit) opens a glass strip of the windows' app icons down the leading edge, most
  recently used first, with the window before the current one selected, its app and title
  beside it. Tab moves on, ⇧Tab back, both wrapping; the desktop shows the selection as it
  moves (Switchyard slides to its column, the floating desktop draws it in front, even from
  the dock) without giving it the keyboard. Letting go of ⌥, seen through Game Controller's
  keyboard, goes to it; Escape stays. A tap on a window in the strip goes to it. The order is
  taken when the strip opens and windows that close leave it; a strip too long for the screen
  shrinks its icons, then shows the windows around the selection (`CabooseKit/Shell/QuickSwitch`).
  Where ⌥ cannot be observed, each press goes straight to the selected window. By touch,
  holding the dock's Overview (Switchyard) or Launchpad (the floating desktop) opens the strip
  with nothing selected: sliding up selects the window level with the finger, letting go goes
  to it, and letting go off the strip, or a cancelled touch, stays; a tap on Overview still
  opens Overview. A held strip's rows stay put whatever is selected, so the row under the
  finger is the one it selects; when more windows than fit are open, the hold reaches the
  most recent that fit, and the rest are reached from the keyboard, by choosing, or Overview. VoiceOver's Switch Windows action on Overview, and a secondary click on
  Launchpad (the way a TV's trackpad reaches it), open the strip to choose from, with Stay
  Here; on the floating desktop and a TV the strip's rows are hit-tested by the desktop like
  the dock. While the strip is open nothing is configured: Switchyard's track slides without
  sending geometry until the switch lands. It lands only on a window still present in the
  same ready session, and is cancelled when its desktop leaves the screen, a card is shown,
  the app leaves the foreground or the session changes.
  Launchpad pages through the available apps, with its controls above the dock.
  An external display scene supplies its current size and scale to the shared desktop;
  changes reconfigure the display without transferring geometry ownership to an app card.
  The green title-bar button maximizes above the dock: its title bar meets the desktop's
  top edge, and its content ends eight UI-scaled points above the dock. Rotation and UI
  scaling update this area. Maximizing and restoring clear the guest's maximized state
  so it uses the client-provided size, while an app's own full-screen request is preserved.
  Transient windows (menus, dialogs, tooltips) are positioned relative to their parent,
  never as separate cards.
- **Switchyard.** Without an external display the Desktop tab tiles the windows on the
  device's own screen (on iPad, a toolbar choice keeps the floating desktop instead).
  Windows sit in columns on a horizontal track that scrolls; a column holds one window or
  a stack (two on an upright phone, three elsewhere). Column widths are ⅓, ½, ⅔ or full,
  offered only where a tile is at least 280 points wide and two halves fit, so an upright
  iPhone shows one full-width column, a Duo opened out or a large phone on its side two,
  an iPad three. New windows open beside the focused one and share the screen evenly until
  it is full, then take columns of their own. A tile is a title bar above its window: Close and
  Full Screen as small coloured circles at its leading edge, each answering across its slice of
  the bar's full height, the title, and an options button; there is no Minimize, because a tiled
  window has no minimized state. The bar never covers the app. The tile's rect below the bar is
  that window's Linux geometry (`configure`, from `YardMetrics.content(ofTile:)`), so apps lay out
  at that size and its input, dialogs and popups are placed by it; a
  resize stretches the entire last picture without cropping until the new one arrives, and drags send geometry at
  most about eight times a second. The gaps resize (snapping to the presets, with haptic
  detents). Dragging a tile's title carries it to a new column, into a stack or onto
  another tile; a tap gives the tile the keyboard, and a double tap opens the same
  full-screen app card as Apps. The green button, the Desktop toolbar's trailing Full
  Screen control, the tile's menu and accessibility action, and ⌘⌥F open the same card. The card keeps Desktop selected
  underneath; dismissing it restores the tile layout. Only the presented card sends window
  geometry while it is up. Its measured content area, including changes to its controls,
  rotation and folding, replaces the guest display size; the complete picture fits while
  the app redraws. A long press on the title or the options button opens the tile's menu
  (full screen, width, ask an agent, redraw, close). Holding a dock icon opens Open, Pin/Unpin and per-window Close
  actions (`DockMenu`), as a menu with the tap as its primary action, so the hold itself
  presents it; tapping it focuses its existing desktop window or opens the app. An app asking for full screen covers the workspace
  above the dock. Desktop keeps its dock and shell navigation through rotation, folding,
  reconnecting and returning from another tab. A pull down from the small tab at its top
  edge shrinks it back into its tile and tells the app to exit full screen. Separate app
  cards keep their own controls. Menus and dialogs appear above the covering window and
  fit within the workspace. Auxiliary windows
  follow their parent's displayed scale and position, including nested menus; trees whose
  owner is offscreen, or is not the covering window, are hidden. A window
  whose own minimum is wider than its tile is shown whole, scaled to fit.
  The dock stays along the bottom under the tiles. Everyday and running apps appear once
  each, with a dot for an open app; tapping focuses or opens it and holding exposes
  its window actions. Icons keep their size and scroll horizontally when they do not fit.
  Overview shows every window (tap to go, swipe up to close), alongside All Apps. The side
  edges move along the track.
  ⌘⌥ with the arrows moves focus, with ⇧ moves the window, and R, F, ⇧F, W, O, A and
  Return cycle the width, toggle full screen, toggle full width, close, open Overview, open
  an app and open a terminal; ⌘⌥ reaches Linux as Ctrl+Alt, so plain ⌘ stays the apps' Ctrl. The layout
  and each app's hand-chosen width are kept per computer (window ids survive reconnects
  and parking). The layout engine is `CabooseKit/Switchyard` and is unit-tested.
- **Lifecycle.** The display socket closes when the app goes to the background; the
  computer parks on idle and resumes on the next foreground. The last frame of every window
  is cached with the server's `epoch`, and shown on reopening only when the new hello has
  the same epoch. Pictures are reduced on the GPU to a 1024-pixel long edge and read back
  off the main thread, most recently raised first within a 24 MiB budget. Home's kept
  pictures use a 640-pixel long edge. Cache generations discard late readbacks.
- **Connection recovery.** While the app is in use, one display connection is open at a
  time, and one wake (`POST /v1/session`) runs at a time; other callers for the same
  computer wait for it. Pairing with another computer, signing out, parking, restarting or
  going to the background fences the running wake: the address it reaches, the session
  it gets and the failure it meets are all dropped rather than applied. A
  connection is given up when the socket closes, when nothing arrives for 15 s (the client
  pings every 5 s and the server answers each), when the hello does not come within 15 s of
  opening, or, after the path's route changes (`NWPathMonitor`: the interface kinds the
  path uses, by `usesInterfaceType`, or its gateways — Wi-Fi to cellular, another network,
  a tunnel coming or going), when a probe ping gets no answer within 5 s. The app then tries again
  after 0.5, 1, 2, 4, 8, 15, 15 and 15 s, each time choosing among the saved addresses
  and waking with a 30 s timeout. A connection that stays up for 10 s starts the count
  again; one that drops at once does not. A new network path, the app returning to the
  foreground, or Try Again starts a new series at once; without a network the series
  waits. It stops when the display refuses a fresh token twice, speaks another protocol
  version, or the host answers with an error, and the tab shows Out of Reach. Another
  device taking the display over (`replaced`) is never retried.
  The session reconnects in place: the same `CabooseDisplaySession`, its windows still on
  screen with their last pictures and their keyboard focus, and a banner that says input
  is paused. When the new hello carries the epoch of the last one, each window the server
  announces again keeps its object and picture, and keeps being painted; any it does not
  announce before the pong to the ping sent after the hello is removed, and
  `windowsAnnounced` is bumped. Another epoch, or none, removes the kept windows before the
  new ones arrive. Pictures still queued from the closed connection are dropped, and
  nothing a closed socket delivers reaches the session. Input sent while disconnected is
  dropped, not replayed; the server releases held keys and buttons when a connection ends.
- **Connection diagnostics.** Computer settings › Display shows what the current
  connection measured on the phone: ping round trip (last, median, worst of the last 20),
  seconds since data last arrived, the receive rate and pictures per second over the last
  5 s, decode time and the wait before decoding (the client's own queue), failed decodes,
  messages waiting to be sent and the oldest one's age, the typing echo (key to next
  picture of that window), and the presented window's last-picture age. It also shows the
  interface kinds the network path uses (all of them, with no guess at which carries the
  display), the address in use, reconnects and recent losses with their reasons. The
  computer's encode time and the one-way network delay are not measured, because the
  phone and the computer share no clock.

### Game handoff

CabooseKit's `Game/` runs the games caboose-display hands off ([game-handoff.md](game-handoff.md)).
`CabooseDisplaySession.runsGames`, true wherever WebKit is available, puts `wasm: true` in the
hello. `game.create` sets `RemoteWindow.game`, a `RemoteGame` that lasts through a resume from
the same server epoch and ends on `game.destroy`, when its window is withdrawn, or when the
session ends. The session sends no input addressed to a game window, and `close` for a game
window first waits up to five seconds for saves still being written. The host's `/v1/fs` is
reached at the display URL's origin with the host bearer token. `RemoteWindowView`'s
interactive view lays the game's one `GameSurfaceView` (a `WKWebView` with a non-persistent
data store) over the window and turns off its own gestures and key forwarding; when the view
leaves the screen or the app stops being active, a snapshot becomes the window's picture.
`CabooseGameSchemeHandler` serves `caboose-game://<id>/<path>` from a least-recently-used cache
in `Caches/CabooseGames`, bounded at 1 GiB and keyed by computer, path and etag. Save sync
writes IDBFS changes within two seconds and retries every five seconds while the game runs.
An on-screen controller reaches the page's Gamepad API through `RemoteGame.gamepad`.

### Shell

The app is a system tab view (SwiftUI `TabView` with `Tab`). Outside wide portrait Desktop,
where the system draws a vertical bar, and on iPad, the tabs are the system's. On an iPhone whose bars are horizontal
the system's tab bar is hidden and the tabs sit at the bottom right
(`HomeToday.tabPlacement`): a cluster beside the tab's own bottom control (Home's Ask) when
the screen is under 600 points wide, else a compact rail at the bottom trailing edge. Tablet portrait uses that compact
rail on both Duo and iPad: icon-only navigation in one floating capsule and page controls
in a separate capsule above it. Page actions and lifecycle actions share the controls
capsule’s overflow menu; the native top toolbar is hidden on this custom path. A single
wallpaper continues behind both capsules, and an explicit
content column reserves its width so grids, chat composers and the Ask field do not
run behind it. Portrait Desktop at 600 points or wider overrides both system and custom tab placement: the far-right icon
in the dock opens an upward, button-anchored 72-point-wide vertical strip of icons for
Desktop controls and app navigation. The strip scrolls within 512 points; Close, outside
tap and the accessibility escape action dismiss it. Narrow phone windows retain their native shell controls. No navigation bar, native tab rail,
or custom sidebar reserves a strip; the closed panel leaves the full available desktop
viewport and bottom dock. Window bounds determine portrait, so showing the keyboard does
not switch chrome. Landscape keeps its native bar where available or its custom sidebar;
Laptop keeps its controls below the screen. Every tab offers Computer settings and a
lifecycle menu: Turn On (`POST /v1/session`) while parked or out of reach, Park
(`POST /v1/session/park`) and, where `capabilities.restart` is true, Restart after
confirmation (`POST /v1/computer/restart`). The host has no power-off. Host messages
(`lastError`, a component update's failure) show as one-line statuses whose text, with
repeated lines removed and clipped to a few lines, opens on tap.

| Tab | What it is |
| --- | --- |
| Home | Today: the computer's state; its windows live in most-recently-used order, or while it rests their last pictures, kept on the phone; approvals (answered in place) and agents at work; agent turns that ended and visible files that changed since the app last left the screen, else the newest visible files (from the same `/v1/fs` scan that feeds Spotlight); pinned and recent apps; AirPlay; and Ask, which opens a window, app or file by name or starts a chat with the default agent |
| Desktop | The computer's desktop on this screen, configured for exactly the space beside or between the bars, with Keyboard, AirPlay and Full Screen in the toolbar; while a TV shows the desktop, the phone's trackpad |
| Agents | The Ask bar, approvals, tasks and the agent seat's windows |
| Apps | Every desktop entry, the Shelf and Library |
| Terminal | A native terminal, present when the app is built with it |

`caboose://home`, `desktop`, `agents`, `apps` and `terminal` select a tab;
Home's live window tiles open on tap and offer Close in their context menu and VoiceOver
custom actions. An upward drag shows close progress and closes on release after 64 points
with vertical travel exceeding horizontal travel by a factor of 1.5. Horizontal and
downward starts yield to scrolling; short or sideways releases cancel. The gesture sends
one normal display close request, leaving unsaved-change handling to the application and
keeping the tile until the server removes the window. Releasing a close drag does not
open the window. A changed session, connection generation or window cancels the drag.

`caboose://task/<id>` opens a task and `caboose://airplay` runs Home's AirPlay action.
Pinned and recent apps are kept on the phone per computer.

The name on Home opens a menu of explicitly paired computers, with the active computer
checked. Add Computer uses the existing pairing flow and retains the other pairings.
A single shared Keychain record stores the collection and active selection atomically;
failed writes leave the current connection intact and show an error. The legacy pairing
migrates with its existing Files/cache identity. Pairing metadata supplies the id and name;
status updates refresh the saved name. Re-pairing a known id at the same host preserves its
local identity. Switching fences old wakes and session callbacks, disconnects the old
computer, and resets its in-memory state before connecting the selected pairing.
Manage Computers opens the host console without a bearer in the URL. Console administrators
provision computers and create pairing codes after web sign-in. A phone token cannot list
the host's computers or authorize a different computer; this menu is a local collection,
not account discovery.


- **Vertical bar.** On iPhone Duo (iOS 27.1) the system draws the tab bar and toolbar
  items together in a bar on the side, and moves the status bar into it. Toolbar items are
  icon buttons so that they can move there. The Desktop tab keeps the tab bar whole
  (`toolbarVerticalCompressionBehavior(.prefersTabBar)`), gives Full Screen the lowest
  visibility priority and the Computer pair the highest, and reads
  `toolbarVerticalEdge` to extend the desktop under the top and bottom insets beside the
  bar. The custom Desktop sidebar uses the same vertical safe-area policy. Both horizontal safe edges stay protected as the bar moves. The desktop is bounded
  and clipped to its measured content viewport; folding, rotation and tab changes report
  that viewport again. Home's window strip and Pinned row receive the measured column
  width and clip within it; Home window previews fit their original aspect ratio within
  320 points of width and 196 points of height, regardless of the window count. File names
  and paths truncate within the same column.
  The landscape Desktop toolbar’s Full Screen control opens the focused app card.
  Wide portrait Desktop hides the native toolbar and tabs together for its compact panel; a closed phone keeps its native bar.
- **AirPlay.** iOS lets no app select an AirPlay device or start Screen Mirroring. The
  AirPlay control (in Home's and the Desktop's AirPlay sheet) remembers the AirPlay output the computer's sound last played on (from the
  audio session's route) and, on a tap, switches the session to long-form video routing and
  calls `prepareRouteSelectionForPlayback`, so the system reconnects or offers a device as
  its Automatically AirPlay setting allows. Beside it is the system route picker
  (`AVRoutePickerView`). The desktop reaches a TV only when the owner starts Screen
  Mirroring; the app then claims the external display as a desktop.
- **Wallpaper.** The desktop's wallpaper is the phone's, not the guest's (the compositor
  draws no desktop), so one choice covers every tab and the desktop on the phone and on a
  TV: the brand gradient, wallpapers that change every quarter hour, one wallpaper, or the
  owner's own picture from Photos, kept on the phone. Rotation uses the 67 curated
  Unsplash photographs served by Lorem Picsum, with photographer credits in the picker.
  Photos are fetched over HTTPS at the display's pixel size, capped at 3840 on the longest
  edge, and cached in Caches. Downloads have a 15-second request timeout, a 30-second
  resource timeout and a 12 MiB limit; image type, dimensions and decoding are validated.
  A failed fetch leaves the current background visible. Twelve named generated scenes
  (`WallpaperRenderer`) are also selectable and render locally without a network.
  The choice is made from Computer settings, the
  Desktop's overflow menu or a long press on Home's background. On the phone a sheer of
  the brand gradient lies over a wallpaper, which extends under the bars. The last
  wallpaper is cached so no screen starts black.
- **Computer settings.** The Computer sheet edits the management settings, shows
  `restartRequired`, parks, restarts after confirmation and chooses the wallpaper.

A full-screen app card entering Laptop mode returns its focused window to the shared
Laptop desktop. The compact dock belongs to the top of the lower control surface;
there is no separate dockless Laptop app-card workspace.

### Input

Terminal opens with the software keyboard hidden; tapping its grid focuses input.
With a hardware keyboard it accepts typing without an extra tap. Its Laptop layout uses
the shared fold measurements, puts the terminal above the hinge and a typing deck below:
the shared KeyBar, compact keyboard, native keyboard option and session/navigation controls.
It has no trackpad or mouse modes. The terminal remains mounted through shell placement
changes, and session menus are anchored to their own buttons. Tab content retains one
structural identity across shell placements; the system tab bar is explicitly restored
when its placement returns. Selecting Desktop from another tab exits a covering window
and restores its dock.


- **Touch.** Native Wayland windows take real multi-touch, except a two-finger tap or stationary
  half-second hold cancels
  the touch sequence and sends a right-click with a brief amber ring and haptic. Xwayland windows get pointer
  gestures: a tap clicks, a one-finger drag holds the primary mouse button for drawing,
  selection or moving, and two fingers scroll with momentum. A two-finger tap or a
  stationary long press sends a right click (an amber ring blooms where it lands, with a tick). Emulated scrolling uses fractional deltas paced to display refresh, with
  time-based deceleration shared by window swipes, desktop two-finger scrolling and the
  phone trackpad. A new touch, context action, target change, detach or app backgrounding
  stops client inertia. Native touch leaves fling and gesture interpretation to the Linux app.
  Pointer taps are sent individually, retaining their real timing for double
  clicks. A stationary half-second hold opens context immediately at the held point;
  lifting or cancellation cannot send another click. A direct drag starts at the finger's
  original contact point; cancellation, backgrounding and target changes release its mouse
  button exactly once. Hardware wheel scrolling keeps its own system momentum.
  A tap shows the keyboard when the app
  answers it with a text cursor or text-input-v3 focus, and hides it otherwise. Dialogs are
  fitted and centred on the phone.
- **Phone trackpad gestures.** Laptop and external-display controls share `TrackpadGestures`:
  one-finger pointing/tapping, two-finger scrolling and secondary tap, three-finger drag,
  and four-finger swipes (left/right switch windows, up opens the window chooser, down
  closes it). From a standalone card, up returns to Desktop. Pinch recognition and scroll
  recognition are mutually exclusive; pinch produces bounded Control–Plus/Minus shortcuts
  for the focused app. Multi-finger lift or system cancellation releases a drag immediately
  and suppresses leftover touches. A gesture guide is available in both control surfaces.
  System-reserved/accessibility gestures, Force Touch and app-specific rotation are not emulated.
- **Pointer.** A hardware trackpad and mouse work through `UIPointerInteraction` and
  `GCMouse`.
- **Keyboard.** The iOS keyboard works through `UITextInput`, so autocorrect, QuickPath,
  dictation, emoji and marked-text input (Chinese, Japanese, Korean) work. The client keeps
  a `TypingBuffer` of the field's text before the remote caret and turns each edit iOS makes
  into BackSpaces and keystrokes from where the old and new text differ. Where the app
  reports its surrounding text (text-input-v3), the buffer is the field's real text before
  the caret, so predictions, autocorrect and dictation work with the words already in the
  field and can correct them; a report that races fresh keystrokes waits until the app has
  caught up. Otherwise the buffer is what was typed since the last click, Return or non-text
  key. Where an app has text-input-v3, the keyboard follows its state, its content purpose
  turns autocorrect off for terminals and passwords, and marked text is a preedit. Return commits any marked
  text and sends a real Enter key press/release, so a browser address bar submits. An
  unmodified software Return dismisses the keyboard except in terminals and code editors;
  pasted multiline text and hardware Return leave it open. Otherwise autocorrect and
  capitals are on for prose and off in terminals and code editors, with an Autocorrect toggle in
  the keyboard controls menu.
- **Keyboard accessory.** Remote app cards, tiled and free desktops, the external-display
  trackpad, Terminal, the Agents composer and app-owned native form fields use
  CabooseKit’s shared `KeyBar` accessory: one 48-point row of plain keys on the system
  keyboard surface. iPad inputs install the same actions in UIKit’s built-in shortcut row.
  iPhone inputs, including an opened Duo, retain the attached header regardless of width.
  Combo and the Terminal Laptop deck embed the shared row directly above their custom keys.
  Hide Keyboard stays fixed at the right edge. A controls menu selects
  Keys, Move or Symbols; each group shows four keys on compact keyboards and six from
  378 points wide, without horizontal scrolling. The menu also exposes every key and the
  Autocorrect toggle. Home/End and symbol keys offer related actions on touch-and-hold.
  Switching groups preserves active modifiers, also indicated on the controls menu.
  The accessory lays out within its own bounds, independently of the tab sidebar's safe area.
  The row offers Escape, Tab, sticky Ctrl/Alt, repeating arrows, navigation and shell symbols.
  Remote inputs share the same text/composition and modifier handling, with a menu toggle
  for autocorrect; Terminal keeps its own terminal-byte semantics without prose correction.
  Native fields use UIKit text editing, selection and IME; navigation moves native text
  positions and never inserts terminal escape sequences. Ctrl/Alt apply to the next key;
  Ctrl+A/C/X/V/Z/Y use native editing commands, with Copy/Cut blocked in secure fields.
  Unsupported chords announce their unavailability without inserting text. Send and Hide clear composer
  focus; updates and send completion leave it hidden until a tap or explicit focus request.
- **Pencil.** Apple Pencil is a tablet pen (tablet-unstable-v2): the client sends
  `pencil` samples with pressure and tilt for every coalesced touch, and hover on iPads that
  have it; the compositor presents one tablet ("Apple Pencil") with one pen tool, so Wayland
  applications and, through Xwayland's tablet devices, X11 applications (GIMP, Krita,
  Xournal++, Inkscape) draw with pressure and tilt. Fingers stay touch.

### Terminal

The Terminal tab is a native terminal on a real shell in the computer, built on
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.99.1 (MIT): xterm-256color with
truecolor, 256 colours, bold and italic, the alternate screen, mouse reporting, bracketed
paste and OSC 8 links. CabooseKit holds the protocol (`Terminal/`: messages, closes, keys,
and `TerminalConnection`, which tracks the output offset); the app holds the view.

- **Look.** Caboose Night: SF Mono on the icon's navy (`#0E1626`) at 50% opacity over the
  wallpaper, cream text, an amber cursor and selection, and a sixteen-colour palette from
  which the 256-colour cube derives. Pinch, or Larger and Smaller Text in the session menu,
  sets the size from 8 to 28 points; it is kept on the phone. Like Desktop, the terminal
  fills the screen beside a vertical sidebar without a title strip or outer margins.
  The grid has a ten-point inset inside its navy background to keep text and the cursor
  clear of the edges; one uniform background covers both inset and grid. The keyboard opens
  when entering Terminal and still reduces the grid's height. A single tap in the middle
  hides it for reading; another tap shows it again. Links and double-tap selection retain
  their actions. Sessions open a system action dialog. Computer lifecycle actions open a
  popover anchored to the power button, including on compact screens, so the actions stay
  beside their control without nesting inside the Duo's toolbar overflow.
- **Input.** A key row above the keyboard has Esc, Tab, sticky Ctrl and Alt (for the row's
  keys and the keyboard's next one), arrows that repeat while held, `` | ~ / - _ ` \ : * $ ``,
  Home, End, Page Up and Page Down, and Hide Keyboard. Unmodified arrows follow the
  application's cursor-key mode; modified keys are xterm's. A hardware keyboard types
  directly (Option is Meta) and focuses the terminal on arrival. Long press or double tap
  selects, with Copy, Paste and Select All; programs can copy to the phone's clipboard with
  OSC 52, but never read it.
- **Behaviour.** A tap on a URL in the output or an OSC 8 link opens it in Safari. The bell
  is a haptic and a flash. The grid follows the view: rotation, the keyboard, the vertical
  bar and pinch each send a resize. Leaving the app or the tab detaches; coming back
  reattaches from the last byte received, so nothing repeats. A dropped connection retries
  after 0.5, 1, 2, 4 and 8 s, then every 15 s; only opening the tab or an action wakes a
  parked computer (`wake=1`), never a retry. When the shell exits, another device takes
  the session, or the connection closes as idle, the screen says so with one action (New
  Session, Show Here, Reconnect); typing after an idle close reconnects, and Return after an
  exit starts a new session. A session that
  ended while away is replaced with a new one, with a note.
- **Sessions.** The session menu starts a new session, switches between the computer's
  sessions (`GET /v1/terminal/sessions`) and closes the current one. The current session's
  id is kept on the phone, so the app reopens it after a relaunch.

### Agent space

- **Chats.** The Agents tab is a chat with an agent on the computer, and a chat is a task:
  its first message starts it with the chosen agent (the default unless the composer names
  another), and every later message is a reply, so the agent has the whole conversation in
  one session. Sent while the agent works, a message waits in the task's queue and shows as
  waiting, with Send Now, which cancels the turn and sends it at once. New Chat starts a
  fresh task; the chat list is the task list, and other chats still working are pinned
  along the top. Where Apple Intelligence is available the phone's Foundation Models model
  names each chat from its first message for the list; it handles nothing the owner says.
- **Composer.** Every chat and the new-chat screen retain their own unsent text and files
  while the app is open. The glass composer offers camera photos, Photos and Files, shows
  removable attachment previews, and keeps input after a failed send. Explicit dictation
  requests microphone and speech permission, displays Listening, and puts recognized speech
  into editable text; it never sends automatically. Recognition availability depends on iOS
  and the selected language. Attachments without text use “Please look at the attached files.”
- **Transcript.** A chat shows its whole conversation from
  `GET /v1/agent/tasks/:id/transcript`, then follows `agent.task.event` and replaceable
  `agent.task.draft` snapshots: prompts, streamed messages,
  collapsible thoughts, tool calls grouped and updated in place, the plan as a checklist,
  permissions with their answers, and context use. Messages render native headings, lists,
  quotes, inline styles and links, plus selectable fenced code with Copy. The chat list is
  searchable by title and agent. Generated-file links beneath `/home/caboose` (including
  guest `file://` links), `~/` paths and home-relative paths download through the authenticated
  `/v1/fs/content` service, never the phone's filesystem. Downloads reject redirects and stop
  at 25 MiB. Standalone image Markdown shows a downsampled inline preview; tapping opens
  Quick Look with Share. Unsupported preview formats offer sharing. Download failures are
  visible in the chat.
  Complete `html` and `inline-html` fences up to 512 KiB render self-contained interactive
  HTML/CSS/JavaScript/SVG; incomplete fences show a completion placeholder and oversized
  widgets show a size message. HTML source is never displayed in the chat. Each widget
  uses an ephemeral WKWebView and an opaque-origin sandbox frame, with CSP and content rules
  blocking network and file access, navigation, external dependencies, frames and popups.
  Widgets resize with their content, open full screen by moving the same web view into a
  native presentation with Done (preserving JavaScript state), and
  offer HTML export. A preview failure shows a compact message with Retry, without dumping
  source. Network-blocking rules use separate scheme patterns supported by WebKit's rule
  compiler. No bearer token enters the web view. The sole native bridge,
  `window.Caboose.compose(message)`, accepts at most 32,000 characters after a widget touch
  and active JavaScript user activation, then shows a native proposed-message review sheet.
  Use in Composer prefills the chat draft; it never sends a message or executes tools.
  A running chat shows a live preview when the shared agent
  seat has an application window; Watch opens that real surface. A working agent can be stopped. Pending approvals show in the chat, on Home and as a banner over every screen, with the agent's always-allow option when it
  has one. A task whose agent was signed out offers Sign In and Ask Another (another agent
  the same thing in a new chat, or Connect a Model). Sign In, there and in Settings › Agents,
  opens a sheet that signs in on the phone: the sign-in page in a private in-app browser,
  whose return to the computer's localhost goes to the agent, and a terminal sign-in's
  terminal, with Sign In on Computer's Screen as the other way. A window's menu hands the window
  (screenshot, title, app) to an agent as an attachment.
  The sign-in sheet uses translucent material over the presenting screen.
- **Connect a Model.** An API key instead of an account: OpenRouter (through the registry's
  `goose`, with `GOOSE_PROVIDER=openrouter`, `GOOSE_MODEL` from OpenRouter's public model
  list of tool-using models, and `OPENROUTER_API_KEY`), Anthropic (`claude-acp`,
  `ANTHROPIC_API_KEY`) or OpenAI (`codex-acp`, `OPENAI_API_KEY`). The app installs the
  agent, sets its environment with `PUT /v1/agents/:id/env`, and makes it the default; the
  host learns nothing new.
- **Agent seat.** The Agent space watches the seat with a second `CabooseDisplaySession`
  on `/v1/display?seat=agent` that plays no sound, so there is one stream of sound: the
  owner's display. Take Over and Hand Back pause and resume tasks.
- **Settings › Agents** lists the registry (installed agents first): install or update,
  sign in on the computer's screen, add or remove environment variables such as an API key,
  and choose the default agent. Registry icons are SVG, which iOS does not draw, so agents
  show their initials.

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

App Intents wake or park the computer, open a Linux app or run one of its desktop actions
(New Private Window, a new document), open a URL on the computer, ask a computer agent (an approval-gated task, returning a task link), open, get or save computer
files, and run the four Craft operations. App shortcuts offer phrases to Siri and
Shortcuts. App and file entities use the authenticated host API. File paths are relative to
the home; saving creates new files and refuses to overwrite.

Craft intents stage their inputs under `.caboose-jobs/<job>` through `/v1/fs`, call
`POST /v1/catalog/:id/run`, download the outputs, and move the job directory to Trash after
success. A failed or interrupted job's directory is kept for inspection. CLI warnings are
returned to the shortcut.

File search lists the home recursively through `/v1/fs`, skipping unreadable or removed
directories and the top-level `.caboose-jobs` directory, and sorts by modification time.
It suggests the 200 most recent files; a text query searches all of them. Apps are indexed
with their desktop actions, each found under its own name and run when selected. On wake and on
`fs.changed`, while a control connection is active, the app replaces its 200 Spotlight file
entries; a connection failure during a scan leaves the previous entries in place. The app
also indexes the current app list, opens an indexed app or file when it is selected, and
removes its index on sign-out.

### Files

The app registers the paired computer’s replicated File Provider domain at startup, after
pairing, and on foreground entry, independently of host wake. The domain is named Caboose
until the host supplies the computer’s name. Registration and removal run in order;
enumerator signals follow successful registration. Computer settings shows registration
errors and offers Retry Files Setup, even when the host is unreachable. Signing out or
switching computers removes the previous domain. The extension declares enumeration support
and its shared document group in its Info.plist. Files controls location visibility; a
provider listed but switched off in Browse > More > Edit must be enabled there.

The extension enumerates its home through `/v1/fs`, downloads on demand, and uploads coordinated edits with
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

### Native bridge on the phone

Linux file dialogs open the iOS document picker (Open) or a native sheet browsing the
computer (Save, Choose Folder); a picked file outside the computer is copied to it and kept
in sync like [an opened document](#open-in-place). The computer follows the phone's
appearance, its media appears in Now Playing, and, when the owner turns it on, it gets the
phone's location while Caboose is open. Computer settings has the switches. See
[native-bridge.md](native-bridge.md#app).

## 7. Security model

- **Owner token.** One bearer token (`CABOOSE_OWNER_TOKEN`, or generated into the state
  directory with mode 0600) authorizes every `/v1` route, every computer and every
  WebSocket. The web console keeps it in session storage. The host
  speaks plain HTTP on loopback by default; HTTPS and WSS belong in front of it before
  traffic crosses a network.
- **Accounts.** Administrators sign in with an email and password (hashed by Better Auth;
  sessions are signed with `CABOOSE_AUTH_SECRET` or the generated `auth-secret`). Sign-up
  is closed: the first account comes from setting the host up with its one-time code, the
  rest from single-use invitation links. The host allows twenty sign-in, setup or
  invitation attempts per client in ten minutes, then answers 429. An administrator
  sees only their tenants' computers; only the operator sees the host itself.
- **Phone tokens.** A phone signs in to one computer with its own token, obtained once for a
  single-use, ten-minute pairing code, so no token is ever shown in a link, a QR code or the
  console. The host stores only SHA-256 digests; signing a phone out closes its sockets and
  removes its notifications. The app and its extensions keep the token in a shared Keychain
  access group.
- **Computers.** Each computer is fenced from every other (`192.0.2.0/24` is always
  rejected; containers sit on separate bridge networks) and has its own disk and data
  directory.
- **Display token.** A random per-wake token in `/run/caboose/display-token` (mode 0600,
  owned by `caboose`) authorizes the guest's display, file and terminal services. It reaches a
  client only inside an authenticated `/v1/session` response.
- **Control sockets.** Each seat's control socket is a Unix socket in a directory only
  `caboose` can open, and the compositor serves only peers of its own user. It is never
  exposed outside the computer.
- **Fencing.** The guest cannot open connections to the host, and by default cannot reach
  private, link-local, CGNAT or reserved ranges. Display, file and terminal ports are
  reachable only from the host: over the TAP device on Linux, or through loopback relays on macOS and containers.
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

### Agent model selection

`POST /v1/agents/:id/models` opens a bounded ACP discovery session in the computer,
without a prompt or MCP servers, and returns `{ models? }`. The optional capability is
`{ currentModelId, availableModels: [{ id, name, description? }] }`. Model configuration
options advertised by ACP take precedence over legacy session model state. Providers
that advertise neither omit the capability. Discovery can require signing in.

Task creation accepts an optional `model` id, included in the durable admission
fingerprint and task configuration. The runner validates it against the session's actual
advertisement and negotiates it after new/load/resume, before sending any prompt.
An unavailable requested model fails explicitly. Tasks expose `requestedModel` separately
from the agent-confirmed `models.currentModelId`; both survive runner/host restart.
`GET /v1/agent/tasks/:id/models` reads the durable state. `PUT` with `{ model }` selects
an advertised model for the next message when the chat and its queue are idle (409
otherwise). Model selection does not change profile identity, routines, MCP scope, or
sign-in attempts. The phone's Agents toolbar offers the provider's advertised models
for new chats and the current chat.

Agent chats and the new-chat screen use a translucent navy reading field matching Terminal,
with opaque text and the selected wallpaper visible beneath it. Reduce Transparency makes
the reading field opaque.

Agent chats keep their rendered turns mounted through keyboard and reply updates. A stale
transcript read preserves completed turns already shown unless the host explicitly truncates
the transcript; the last-answer summary is retained before a new reply clears it.

For chats created before model-state reporting, idle model discovery reads provider choices
without claiming to know that chat’s current model (`currentModelKnown: false`). Selecting a
model retires only the identified idle runner before saving the request; the next reply
resumes its conversation with the new runner and applies the choice before prompting.

Synthetic mouse clicks from app cards, the desktop and its trackpad retain a 100 ms button-down interval and a 20 ms up interval between queued clicks. This lets frame-sampled desktop interfaces observe both edges. A drag or detached input view cancels pending clicks and releases the active button; queued input is fenced to the original session connection and window. Native touch sequences retain their original phases.

An app card reasserts its measured viewport when the guest resizes the window after opening, including onboarding transitions. Corrections are limited to two per one-second burst so an app enforcing a minimum size does not cause a configure loop; a later app resize or viewport change starts a new burst.
