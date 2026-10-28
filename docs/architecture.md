# Caboose architecture

Caboose is your phone's computer. It is a persistent Linux machine that lives on a
server, wakes the moment you open the app, parks itself (memory and all) when you
leave, and is shared by you and your agents. On the phone it does not look like a
remote desktop: each Linux application arrives as its own native iOS surface.

This document is the contract every component is built against. Change it in the
same pull request as the code that changes the contract.

## Shortcuts and Spotlight

Caboose provides App Intents to wake or park the computer, launch an installed Linux
app, open a web URL, start an approval-gated agent task, and open, download or upload
computer files. App and file entities use authenticated host APIs. File paths are
relative to the computer home; uploads create new files and refuse overwrites. Agent
actions return a task link. App shortcuts offer phrases to Siri and Shortcuts.

File search recursively lists the home through `/v1/fs`, sorts by modification time,
and suggests the 200 most recent files; a text query searches all files. Unreadable or
removed directories are skipped; a connection failure during scanning leaves the prior Spotlight index
intact. The private `.caboose-jobs` staging directory is excluded. On wake and on
`fs.changed` the app rescans and replaces its 200 recent Spotlight file entries. It
indexes the current app list on refresh and opens an indexed app or file on selection.
Signing out removes Caboose's index. Refresh requires an active control connection;
changes while disconnected are reconciled on the next wake.

The WidgetKit extension uses the shared Keychain to fetch computer state and the running
agent count without waking it. WidgetKit schedules refreshes. A configurable favourite
app widget and Control Center control launch the selected app; an Ask Agent control
opens the Ask bar in Caboose, and a power toggle wakes or parks the computer.
A signed device is needed to verify shared Keychain access and control behavior.

Craft shortcuts stage input files under `.caboose-jobs/<32 lowercase hex job id>` through
`/v1/fs`, then call authenticated `POST /v1/catalog/:id/run` with `{ job, inputs,
format }`. Inputs are numbered `input-0.ext`, etc. The host requires the catalog app to
be installed and accepts only fixed operations: PhotoCraft `convert` (1–20 images to
PNG/JPEG/TIFF/WebP), PDFCraft `combine` (2–20 PDFs), LightCraft `render` (one photo to
PNG/JPEG/TIFF/WebP), and FilmCraft `export` (one `.fcproj` to MP4/MOV). FilmCraft
projects must have their referenced media available at their original paths in the
computer; its CLI reports offline media as a failure. The host executes a fixed argument
vector as `caboose`, holds a computer lease, and returns `{ job, outputs, warnings }`;
outputs are home-relative staged paths. Failed or interrupted jobs remain for inspection;
a successful shortcut downloads outputs then moves the job directory to Trash. Warnings
from the CLI are returned to the shortcut. `/v1/control` broadcasts `job.progress` with
the generic job shape on start and completion or failure; the host also publishes that
shape to Live Activities when configured. A run can last up to 57.5 minutes, and the
guest terminates its process group on timeout. APNs and signed-device delivery remain
best effort. The operations follow the pinned versions' [PhotoCraft CLI](https://github.com/storytold/photocraft/blob/v0.16.0/book/src/automation/cli.md),
[PDFCraft CLI](https://github.com/storytold/pdfcraft/blob/v0.14.0/apps/pdfcraft-cli/src/main.rs),
[LightCraft CLI](https://github.com/storytold/lightcraft/blob/v0.14.0/apps/lightcraft-cli/src/main.rs), and
[FilmCraft CLI](https://github.com/storytold/filmcraft/blob/v0.13.0/docs/agents.md).

## Notifications

The host has an optional APNs provider configured with a private .p8 path, key ID,
team ID and app topic. `GET /v1/computer` reports `capabilities.push` when configured.
An authenticated `POST /v1/devices/push` accepts `{ token, environment, kinds }`,
where environment is `sandbox` or `production` and kinds is a subset of `approval`,
`task`, and `desktop`; registration replaces the same token's settings. `DELETE` accepts
`{ token }`. The private device list is persisted atomically beside the computer
settings. APNs 410 Unregistered responses remove the affected registration, unless it
was registered again while the request was in flight. Provider JWTs are refreshed after
50 minutes. With no foreground app control socket connected, new agent approvals and succeeded or
failed tasks generate grouped APNs alerts for devices that enabled the corresponding
kind. The app identifies its foreground control socket with `?foreground=1` and closes it
on backgrounding; other control clients do not suppress alerts. APNs delivery is best effort.

The iOS Computer settings offer per-device switches when APNs is configured. Enabling
notifications requests permission, registers the device and sends its APNs token; notification
approval actions call the existing approval API and task taps open the task. Sign-out requests
unregistration. The guest monitors owner-seat D-Bus notification calls and writes private,
bounded transient records in its cache. The host drains them while the computer is running;
old records expire. The agent seat uses its own session bus, so its notifications do not enter
the owner's queue. Caboose Display runs a small D-Bus notification endpoint; Xpra provides
its own. Linux notifications do not carry a reliable window identifier, so tapping one returns
to the app.

Live Activities use `JobAttributes { jobID, kind, title }` and `ContentState { status, detail }`.
The app starts one for each running agent task; it registers its ActivityKit update token using
`POST /v1/activities` with `{ activityId, jobId, token, environment }`. The host sends updates
and an end over APNs with the `.push-type.liveactivity` topic as the agent changes state; the
app also updates or ends an activity while foregrounded. A device can register a push-to-start
token with `POST /v1/activities/start-token { deviceId, token, environment }`; the host uses
it when a task starts without a foreground app. The corresponding DELETE requests take
`{ activityId }` and `{ deviceId }`. Tokens and the latest 200 job states are private and stored atomically beside settings. A late update-token registration is reconciled with the latest saved job state.
The app unregisters on sign-out. The shared widget extension renders the Lock Screen and
Dynamic Island and opens agent tasks on tap.

Other host jobs can call `POST /v1/jobs/activity` with `{ start, job: { id, kind, title, status,
detail } }`; `start` is a boolean, status is `running`, `paused`, `succeeded`, `failed`, or
`cancelled`, and the final three end an activity. Producers publish their own state and use the
same identifiers when registering an activity. This is the interface for app installs and
future exports; those producers have not been wired into it by this lane. APNs is best effort;
real delivery and push-to-start need a signed device and configured credentials.


## iOS weave

The guest installs `caboose-open URL` and `caboose-share FILE...` on both images.
The desktop registers the phone-specific `mailto`, `tel`, `sms`, `facetime`,
`facetime-audio`, `maps` and `geo` scheme handlers, without changing the default web
browser; `caboose-open` also accepts explicit `http(s)` links. Thunar has **Share to
iPhone**. A local `iPhone` CUPS queue filters print jobs to PDF and uses the same
handoff path, so it works with either display protocol rather than relying on Xpra's
printing forwarding. The queue needs CUPS and cups-filters in the guest.

The commands snapshot files in `/home/caboose/.cache/caboose/phone/files` and queue
requests in its sibling `queue` directory, private to the owner. Files are limited to
10 MiB, the queue to 100 pending requests, and both expire after 24 hours. The host polls
only while the computer is running and an authenticated iOS control socket with
`?phone=1` is connected. It validates each event and sends it to those sockets:

- `phone.open { url }`;
- `phone.share` and `phone.print` with `{ id, path, name, size, contentType }`; `id`
  is a 32-character lowercase hex identifier and `path` is the corresponding private
  staged file. Print content is PDF.

Delivery is at most once: events claimed during a connection loss are not replayed.
The owner token scopes the connection to the owner's computer. The phone prompts before
opening, sharing or printing; it never acts silently, and defers prompts while inactive.
On background the control connection is detached; queued guest events wait for a later
foreground connection, subject to expiry. Xpra URL requests also require a prompt.

After the user agrees, `GET /v1/phone/files/:id` reads the staged file in bounded chunks
through the existing guest command channel and returns `{ data: base64 }`. It never
accepts a guest-supplied arbitrary path or wakes a parked computer. The iOS
`PhoneFileDownloading` protocol isolates this small-file fallback so it can be replaced
with lane 2's streamed `/v1/fs` download. The native share sheet or AirPrint dialog opens
only after the download and confirmation; temporary phone copies are deleted when the
sheet finishes.

Dropping text onto an owner window focuses and clicks at the drop point, then types it
through the display session. Dropping a file or image saves it to `~/Downloads` through
`POST /v1/files` (50 MiB limit) and opens it using Linux's default handler. The selected
window is not necessarily that handler. Native file-drop delivery into a specific Linux
app and dragging out of Linux are not implemented. Both display protocols use the same
path. Transfer failures are shown on the phone.

Xpra's client currently sends pointer and button packets, and the guest defaults to
XTest, which has no tablet axes. Xpra 6.5.5's optional uinput touchpad sends constant
pressure 255 and declares no tilt or pen tool (see its [device setup](https://github.com/Xpra-org/xpra/blob/v6.5.5/xpra/x11/uinput/setup.py)
and [motion code](https://github.com/Xpra-org/xpra/blob/v6.5.5/xpra/x11/uinput/device.py)),
so switching to it would still not deliver Pencil pressure/tilt as a tablet. A real X11 tablet device and a tested input path would
be needed. Caboose Display defines and sends `pencil` samples in the client, but its
compositor currently drops them and does not advertise `pencil` (see
`guest/display/README.md`); neither protocol currently delivers pressure or tilt to apps.

## The pieces

```
 iPhone / iPad / external display                     server (Linux + /dev/kvm)
 ┌───────────────────────────────┐                     ┌──────────────────────────────────────┐
 │ Caboose app (Swift)           │   HTTPS + WSS       │ caboose-host (TypeScript, Node 22)    │
 │  ├ Shell: home grid, app      │ ──────────────────▶ │  ├ Accounts + device tokens           │
 │  │  cards, windows on iPad/TV │   /v1/session       │  ├ Desk lifecycle (appkit-desk):      │
 │  ├ CabooseKit (Swift package) │   /v1/display (WS)  │  │  wake, lease, park-with-memory     │
 │  │  ├ Xpra + Caboose Display  │   /v1/control (WS)  │  ├ Display relay: WS ⇄ guest TCP       │
 │  │  ├ VideoToolbox decode     │                     │  └ Control: apps, launch, park, agent  │
 │  │  └ Input: touch, trackpad, │                     │              │ vsock (appkit-desk)     │
 │  │    keyboard, pencil        │                     │              │ TAP (display relay)     │
 │  └ iOS weave: Files, share,   │                     │ ┌────────────▼────────────────────────┐ │
 │    notifications, Shortcuts   │                     │ │ Cloud Hypervisor microVM (per user) │ │
 └───────────────────────────────┘                     │ │  Debian 13 golden image + CoW home  │ │
                                                       │ │  ├ desk guest agent (exec, a11y)    │ │
                                                       │ │  ├ xpra seamless server :100        │ │
                                                       │ │  │   per-window H.264, clipboard,   │ │
                                                       │ │  │   notifications, files, audio    │ │
                                                       │ │  └ apps: Chromium, VS Code, term,   │ │
                                                       │ │     Claude Code, Codex, …           │ │
                                                       │ └─────────────────────────────────────┘ │
                                                       └──────────────────────────────────────┘
```

### 1. Guest: the computer (`guest/`)

On a WSL2 host that exposes its GPU through `/dev/dxg`, the host can instead run
the computer as a Debian container using `CABOOSE_RUNTIME=container`. Mesa's
D3D12 driver renders on the WSL GPU and Xpra can use NVENC; display ports,
authentication, application discovery and the two-seat protocol remain the
same. The home directory is a persistent host bind mount or volume; installed packages
remain in the container writable layer across a Caboose cold restart. Parking
pauses the container in RAM, and waking unpauses it; a Docker or WSL restart
loses the process tree, but not the home directory. This volatile pause does
not claim the durable microVM snapshot semantics described below. The runtime
and its build and checks are documented in `guest/container/README.md`.

A Debian 13 (trixie, amd64) golden image booted by Cloud Hypervisor. Each computer's
disk is a reflink copy-on-write clone of the base, exactly the appkit-desk model: it
costs no space up front and each user's installs and home persist. A clone is
independent of the base once made, so a new base image reaches new computers only.
On each wake the host compares a SHA-256 hash of its bundled guest components with
`/usr/local/share/caboose/components.version`. A mismatch starts an asynchronous,
root guest-exec upgrade after the display is ready: the host stages bounded base64
argument chunks, installs missing Debian packages, the file service, phone integration,
notification monitor and Mesa software drivers, starts their services and CUPS queue,
and atomically writes the marker only after success. It never replaces the disk or edits
user files. The same installer is used by both image builders. A failed upgrade is retried
on the next wake; a running upgrade holds a lease and rejects park or restart requests.
The system Thunar action is a default; existing user-defined actions take precedence.

`GET /v1/computer` reports `upgrade: null | { state, version?, message? }`, and
`/v1/control` broadcasts `computer.upgrade { upgrade }` plus updated management status.
States are `checking`, `updating`, `succeeded`, and `failed`. A failure does not prevent
the display opening. Before starting an existing container display, the host installs the guarded session bootstrap
from the same bundle on a best-effort basis; missing printing helpers do not prevent display
startup. Old containers retain their writable layer and use the same guest upgrade, but Docker cannot add a port mapping to an existing container: if its port 14700
mapping is absent the success message says to recreate the container to enable Files.
Back up its writable layer and home before replacing it; installed packages in that layer
are otherwise lost. The Computer sheet shows progress, failures and this warning.

- **Display server: Xpra in seamless mode** on display `:100`, listening for
  WebSocket on `0.0.0.0:14500` inside the guest (reachable only from the host over
  the desk's TAP device). Seamless mode is the reason for the choice: every
  application window is its own stream with its own title, icon, class, size
  hints, transient/popup relationships and damage-driven H.264, which is what lets
  the phone render Linux apps as native surfaces instead of a picture of a
  desktop. Xpra also already carries clipboard, notifications, file transfer,
  audio, printing, webcam and cursor shapes. The owner seat forwards speaker audio
  via a PulseAudio monitor, with MP3 available for iOS; microphone forwarding is off.
  Caboose Display (`guest/display`, [display.md](display.md)), Caboose's own headless
  Wayland compositor with Xwayland, is in both guest images on WebSocket `14600` with the
  same token file, installed but not the default; it replaces Xpra behind the same
  window model when the host selects it.
- **Session auth.** Xpra requires a per-boot token (`tcp-auth`/`ws-auth` via an
  `env`/file authenticator). The host writes it with `desk.exec` at wake and hands
  it to the client inside the authenticated `/v1/session` response.
- **Apps** installed in the image: Chromium, Firefox ESR, VS Code, xfce4-terminal,
  Thunar, Mousepad, LibreOffice, Obsidian, document and media tools; optional apps
  are installed on demand from the catalog; developer
  tools including Git, Neovim, Lazygit, Lazydocker, btop, mise and modern shell tools;
  and the Claude Code, Codex, OpenCode and Gemini CLI agents. Terminal tools and agents
  have desktop launchers. Mesa Vulkan and OpenGL software drivers are included. Fonts:
  Inter, JetBrains Mono and Noto (incl. CJK, emoji).
- **Agent runner.** `caboose-agentd` (`/opt/caboose/agentd`, Node with the pinned ACP
  TypeScript SDK) runs any Agent Client Protocol agent for a task; `uv` is installed for
  agents published as Python packages. See Agents.
- **Video decoding (with Caboose Display).** `guest/vaapi` is a VA-API driver that
  forwards each video's compressed bitstream to the client instead of decoding it
  ([codec-passthrough.md](codec-passthrough.md)). It is not built into the images yet: it
  takes effect once Caboose Display's receiving side for it lands. Under Xpra, apps decode
  as before.
- **Guest agent.** The appkit-desk guest agent (vsock 5252) for exec, jobs,
  observe/a11y and agent input. Agents drive the machine through it; humans drive
  it through Xpra.
- **Agent seat.** A second Xpra display (`:101`, WebSocket port `14501`) is reserved for agents so an
  agent never steals the user's pointer; its windows appear in the app's Agent
  space. Its service is installed for on-demand start and uses the same per-wake
  token as the human display. The host starts and relays it on demand.

### Runtimes

The computer normally runs as a **microVM** (Cloud Hypervisor, below). Where a GPU can
reach a container but not a VM — WSL2, whose GPU is the paravirtual `/dev/dxg` —
`CABOOSE_RUNTIME=container` runs it as a Docker container instead:

- the same Debian package set, plus the GPU the host can give a container
  (`CABOOSE_GPU`, detected by default):

  | `CABOOSE_GPU` | Host | Container gets | Rendering / video encode |
  | --- | --- | --- | --- |
  | `wsl` | Windows + WSL2, any vendor | `/dev/dxg`, `/usr/lib/wsl` | Mesa D3D12; NVENC on NVIDIA |
  | `nvidia` | Linux + NVIDIA container toolkit | `--gpus all` | GL + NVENC |
  | `dri` | Linux, Intel / AMD | `/dev/dri` render nodes | Mesa + VA-API |
  | `none` | anything | nothing | CPU (x264) |

  The image reads `CABOOSE_GPU` to pick its GL driver and Xpra's encoder. 4K goes as HEVC
  where a hardware encoder has it (Xpra 6.5.5's NVENC H.264 is fixed at level 5.0, below 4K
  frame sizes); the client decodes H.264 and HEVC in hardware and falls back to images;
- `/home/caboose` on a volume or host path (`CABOOSE_CONTAINER_HOME`);
- the displays published on loopback only, reached by the same relay;
- the image's `caboose-session start | start-agent | ready <display>` brings up D-Bus,
  PulseAudio and the Xpra displays with the per-wake token, as the VM's units do.

Parking a container **freezes** it: memory stays in RAM and waking is instant, but a host
restart loses it and the next wake boots fresh with the home intact. A microVM's
park-with-memory survives host restarts. Isolation is a container's, not a VM's, so the
hosted service keeps microVMs. A bare-metal Linux host with a spare GPU can later give the
microVM itself the GPU through VFIO passthrough, keeping VM isolation and durable parking.

### 2. Host: `caboose-host` (`apps/host/`)

TypeScript on Node 22, built on AppKit packages. It owns no display logic: the
Xpra byte stream is relayed, not parsed.

HTTP API (JSON except streamed file contents, all behind `Authorization: Bearer <device token>`):

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/v1/health` | host + KVM + desk host stats |
| `POST` | `/v1/devices/push` | register or replace a push device and its enabled kinds |
| `DELETE` | `/v1/devices/push` | unregister a push device by token |
| `POST`, `DELETE` | `/v1/activities` | register an ActivityKit update token or remove an activity |
| `POST`, `DELETE` | `/v1/activities/start-token` | register or remove a device's ActivityKit push-to-start token |
| `POST` | `/v1/jobs/activity` | publish a generic job state to its Live Activities |
| `POST` | `/v1/session` | wake the user's computer (start or resume), ensure its display server is up, return `{ state, display: { path, token, protocol }, computer: { name, image, memoryMb, vcpus } }`. `protocol` is `"xpra-ws"` (the default) or `"caboose-display"` (`CABOOSE_DISPLAY=caboose`, docs/display.md); clients treat any other value as `"xpra-ws"` |
| `GET` | `/v1/display` | **WebSocket.** Binary relay to the owner's display in the guest: Xpra's WS on 14500, or caboose-display's on 14600. Subprotocol passthrough (`binary`). One relay per client connection |
| `GET` | `/v1/catalog` | catalog, packs, installed versions and operation state |
| `POST` | `/v1/catalog/:id/install`, `/update`, `/rollback` | queue an application operation |
| `DELETE` | `/v1/catalog/:id` | queue removal of an application |
| `POST` | `/v1/catalog/packs/:id/install` | queue a pack installation |
| `GET` | `/v1/apps` | launchable apps from the guest's `.desktop` files: `{ id, name, icon (PNG data URL), categories, exec }` |
| `POST` | `/v1/apps/:id/launch` | start an app on the owner's display: Xpra's `:100`, or under Caboose Display with the launch environment it writes to `/run/caboose/display.env` |
| `POST` | `/v1/session/park` | park now (snapshot with memory); otherwise parked on idle |
| `GET` | `/v1/control` | **WebSocket.** JSON events: `computer.state`, `notification`, `agent.*`, `media.*`, `fs.changed` |
| `GET` | `/v1/computer` | management status and persisted computer settings; does not wake or lease the computer |
| `PATCH` | `/v1/computer/settings` | update any of `name`, `memoryMb`, `vcpus`, `idleMs`, `defaultAgent`; returns management status |
| `POST` | `/v1/computer/restart` | requires `{ "confirm": true }`; cold restart, preserving the disk and discarding memory; returns management status |
| `POST` | `/v1/files` | `{ name, data (base64), open? }` → `{ path }`: save in `~/Downloads` (legacy clients; see Files) |
| `GET` | `/v1/fs/list?path=…` | list a home-relative directory |
| `GET` | `/v1/fs/stat?path=…` | stat a home-relative item |
| `GET`, `PUT` | `/v1/fs/content?path=…` | streamed download (including Range) and upload |
| `POST` | `/v1/fs/mkdir?path=…` | create a directory |
| `POST` | `/v1/fs/move?path=…` | move or rename with `{ destination }` |
| `DELETE` | `/v1/fs/item?path=…` | move an item to the guest's Trash |
| `GET` | `/v1/fs/changes?anchor=…` | query the inotify journal and its sync anchor |
| `POST` | `/v1/fs/open` | `{ path, app? }` → open a home-relative item on the owner display, optionally with a desktop entry id |
| `POST` | `/v1/open` | `{ url }` → `{ opened: true }`: open an `http(s)` URL in the default browser on the owner's display |

Management status has this shape (resources are MiB and idle time is milliseconds):

```ts
{
  state: "parked" | "waking" | "running" | "parking" | "restarting" | "error",
  settings: { name: string, memoryMb: number, vcpus: number, idleMs: number, defaultAgent: string | null },
  limits: { memoryMb: { min: number, max: number }, vcpus: { min: number, max: number }, idleMs: { min: number, max: number } },
  activeResources: { memoryMb: number, vcpus: number } | null,
  restartRequired: boolean,
  clients: { display: number, control: number },
  tasks: { running: number, paused: number },
  capabilities: { restart: boolean, push: boolean },
  lastError: string | null
}
```

The name is 1–80 characters without control characters, trimmed on save. Memory is
512–65536 MiB, vCPUs 1–32, and idle time 60000–86400000 ms; numeric values are integers.
`defaultAgent` is null (the initial value) or the id of an agent in the ACP registry or
installed in the computer (see Agents); the first agent install sets it when it is null.
Unknown fields and invalid JSON return 400 without applying any changes. Settings
are stored atomically in `${CABOOSE_IMAGE_ROOT}/caboose.json` with mode 0600; environment
values are initial defaults. Name and idle changes apply immediately. CPU and memory
changes apply on the next cold boot, not a memory-snapshot resume. `activeResources`
describes the current running or parked machine, or is null before its configuration
is known. A legacy snapshot with unknown resources requires a restart to establish
them. `restartRequired` distinguishes desired settings from those applied.

Restart closes client sockets, ends running/paused agent tasks, and discards unsaved
application state; it never deletes the computer disk. Restart and park are serialized
with wake and cannot race a new application/task launch. Clients must confirm restart
with the user before sending `confirm: true`. Concurrent restart requests are rejected
with 409 rather than scheduling repeated destructive reboots. A successful restart
response is sent only after the computer and owner display are ready again (clients
allow 300 seconds). Lifecycle failures are
reported in `lastError`. A restart attempts a short disk flush; if the guest is
unresponsive, the confirmed restart still proceeds and leaves a warning in
`lastError` even when the new boot succeeds. The control socket broadcasts
`{ type: "computer.settings", computer: <management status> }` when settings or their
applied state change. An HTTP management poll does not prevent idle parking.

The host serves the built AppKit web management app from `CABOOSE_WEB_ROOT` (defaults
to `apps/web/dist` relative to the host package), with SPA fallback for non-API GETs.
Static files are public; all `/v1` routes remain bearer-authenticated. The web client
keeps the owner token in session storage and sends it only as an Authorization header.
It uses HTTP status polling so leaving the console open does not keep a computer awake.

Network: the guest's TAP is fenced in host-owned chains (`CABOOSE-IN`, `CABOOSE-FWD`).
The guest can open nothing on the host and reaches only the public internet unless
`CABOOSE_GUEST_LAN=allow`. The display relay is opened by the host.

Lifecycle: the host keeps a lease while any display or control socket is open
and lets appkit-desk park the computer after `CABOOSE_IDLE_MS` with no client.
Parking keeps memory, so every app is exactly where it was on resume.

v0 auth is a single owner token from the environment; accounts and tenancy move to
`appkit-auth`/`appkit-tenant`/`appkit-iam` for the hosted service. Nothing in the
API is single-user by shape: every route is scoped to the authenticated
principal's computer.

### Catalog

The repository-owned `guest/catalog/catalog.json` is the source of available apps and
release pins. Debian apps use Debian 13's signed repositories; Craft release packages
have fixed URLs, byte counts and SHA-256 hashes. No release pin changes automatically.
A catalog mutation returns 202 after accepting the operation and emits `catalog.progress`
with an id, operation and phase (`queued`, `installing`, `finished`, or `failed`),
including download stage and estimated progress where available, followed
by `catalog.changed`. Only one catalog operation runs at a time; a concurrent request,
park or cold restart receives 409. Pack installs run their entries in order and continue
past individual failures. Catalog operations hold a computer lease.

The host runs the installer as root through the same argument-only guest channel on both
runtimes. Downloads go directly from the guest, are size- and SHA-256-checked before APT
installs them, and are retained for rollback. Release installs also ensure Mesa software
rendering packages are present on older computers. A successful change retains the prior cached
release where available. APT apps do not promise rollback. Package state and failures are
recorded in the guest and installed versions come from dpkg; interrupted operations are
reported on the next listing. The catalog listing uses the last observed state while the
computer is parked. It does not wake the computer. `/v1/apps` continues to discover
installed desktop entries independently. Craft apps launch over the owner display’s X11
socket (Xpra or Caboose Display’s Xwayland), avoiding their upstream Wayland drag-and-drop
limitation. Mesa provides a software Vulkan and OpenGL fallback when the guest has no GPU.

### 3. App: Caboose for iOS (`apps/ios/`)

Swift, SwiftUI shell over UIKit surfaces, iOS 26+, project generated by XcodeGen.

- **CabooseKit** (Swift package, no UI): `DisplaySession`, the window model the app
  works against, with two implementations chosen by `/v1/session`'s `protocol`.
  `XpraSession` (packet framing, rencodeplus codec, hello/capabilities, keepalive,
  window registry, metadata, cursors, clipboard, notifications) and
  `CabooseDisplaySession` (the Caboose Display Protocol of docs/display.md: canonical
  CBOR, per-window video with acks and keyframe recovery, video streams layered into
  windows, Opus sound on one playback clock with them, vsync pacing, touch, Pencil
  and text-input-v3). Both fill the same `RemoteWindow` and Metal `WindowSurface`.
  Decoders: `VTDecompressionSession` for H.264, HEVC and, where the device has a
  hardware decoder, AV1; ImageIO for png/jpeg/webp; raw rgb. Unit-tested on macOS,
  including the compositor's golden vectors.
- **Shell.** On iPhone each Linux window is an app card: full screen, native
  app-switcher gestures between them, home grid of Linux apps with their real
  icons. Home’s Shelf offers optional catalog apps, and Library groups packs and
  lets the owner install, update, roll back or remove them; progress follows the
  control socket. On iPad and external displays the same windows float, resize and stack,
  with a dock and menu bar. Transient windows (menus, dialogs, tooltips) are
  positioned relative to their parent, never as separate cards.
- **Input.** Touch maps to pointer with tap/drag/long-press (a two-finger tap or a
  long press right-clicks), swipe to scroll
  with momentum (precise wheel motion when the server reports `wheel.precise`,
  otherwise whole wheel clicks, since Xpra's XTest pointer drops `pointer-wheel`);
  a tap shows the keyboard when the app answers it with a text cursor and hides
  it otherwise; dialogs are fitted and centred on the phone; hardware trackpad and mouse through `UIPointerInteraction` and
  `GCMouse`; the iOS keyboard through `UITextInput`, so autocorrect, QuickPath swipe
  typing, dictation, emoji and marked-text input (Chinese, Japanese, Korean) work. The
  remote text is unknown, so the client keeps a `TypingBuffer` of what was typed since
  the last click, Return or non-text key, assumes the remote caret is at its end, and
  turns each edit iOS makes into BackSpaces and keystrokes from where the old and new
  text differ; marked text is typed live and recomposed the same way. Autocorrect and
  capitals are on for prose and off in terminals and code editors (by window class),
  with an `Aa` toggle on the key bar. Multi-scalar characters are typed scalar by
  scalar. Under Caboose Display, native Wayland windows take real multi-touch
  (`touch`, one wl_touch frame per UIKit event) while Xwayland windows keep the pointer
  gestures; Apple Pencil goes as a tablet (`pencil`: pressure, tilt, azimuth, hover);
  the keyboard follows the app's text-input-v3 state (`text_input`) instead of the
  cursor shape, its purpose turns autocorrect off for terminals and passwords, and
  marked text is a text-input-v3 preedit where the app has text-input-v3. Every window
  view on screen sends `vsync` from its screen's display link (120 Hz on ProMotion).
- **Rendering.** Every write to a window's texture (CPU pixels staged through a
  buffer, decoded video, scrolls, resizes) is a blit on one shared Metal queue, which
  runs command buffers in commit order, so no draw waits for the GPU before the next
  is decoded and acknowledged.
- **Lifecycle.** The display socket closes when the app backgrounds; the computer
  parks on idle and resumes on the next foreground. The last frame of every
  window is cached so reopening is instant while the stream reconnects.
- **Computer settings.** A Computer sheet (from Home, the parked screen and the
  failure screen) edits the management settings, shows `restartRequired`, parks,
  and restarts after confirmation; Park Now lands on a parked screen with Wake.
- **Agents.** The Ask bar starts tasks with the default agent or any installed one
  (optionally asking before acting); pending approvals show on the task card and as a
  banner over every screen, with the agent's always-allow option when it has one; finished
  tasks take replies, and a task whose agent was signed out offers its sign-in methods;
  a window's menu hands the window (screenshot, title, app) to an agent as an attachment.
  Settings › Agents lists the registry (installed first): install or update, sign in on
  the computer's screen, add or remove environment variables such as an API key
  (`PUT /v1/agents/:id/env`), and choose the default agent. Registry icons are SVG, which
  iOS does not draw, so agents show their initials.
- **On iPhone.** Where Apple Intelligence is available, the Ask bar also offers the phone's
  own Foundation Models model. It runs on the device, answers in about a second and sends
  nothing to a model provider. It does quick things itself through the host — open an app
  (`/v1/apps/:id/launch`), open a page or search (`/v1/open`), type or press a shortcut
  (`/v1/screen/type`, `/v1/screen/keys`), look at the focused window and press a control by
  name (`/v1/screen/elements`, `/v1/screen/act`), park the computer — and hands anything
  that needs several steps, code, files or judgement to a computer agent as a task (the
  default, or one chosen in Settings › Agents). Measured on an iPhone with the
  `AFM 3 Core Advanced` model (8K context): it routes quick actions and hand-offs well and
  presses named controls reliably, but it cannot place clicks by pixel coordinates or
  compose long content into a tool call, which is why it acts on the accessibility tree and
  delegates real work. `apps/ios/OnDeviceEval` re-runs that measurement on a device.
- **Share extension.** `CabooseShare` takes pages, text, photos and files from the iOS
  share sheet: `POST /v1/open` for a page, `POST /v1/files` into Downloads, or a new agent
  task with them attached. The app and the extension share the pairing through a Keychain
  access group. Push alerts for agent approvals and results are available when configured on the host;
  see Notifications.

### 4. AppKit upstream

Caboose consumes AppKit packages from npm and contributes back rather than
forking:

- `@braedonsaunders/appkit-desk` gains what a person-facing computer needs: the
  TAP networking and guest-network setup that currently live in Bunkhouse's desk
  runner, a port relay so a host can reach a guest service without exposing the
  TAP, and snapshot portability (CPUID-compatible restore or a clean, reported
  fallback).
- The golden-image builder and guest agent move from Bunkhouse into AppKit so
  Bunkhouse and Caboose build their machines the same way.

## Agents

An agent is any program that speaks the [Agent Client Protocol](https://agentclientprotocol.com)
(ACP) and is listed in the public [ACP registry](https://github.com/agentclientprotocol/registry).
Caboose has no list of its own and no code for any particular agent: it runs whatever the
registry describes, inside the computer, signed in with the owner's own account. The host
holds no model keys. An agent works on its **own seat**, so it never moves the owner's
pointer or types into the owner's windows.

- **Agent seat.** `caboose-xpra-agent.service` runs a second Xpra seamless display `:101`
  (WebSocket `0.0.0.0:14501`, same token file and username as `:100`). GUI apps an agent
  starts appear there. The app shows them in an Agent space, view-only. **Take Over**
  stops the running agents (SIGSTOP to each task's process group) and gives the owner
  input; **Hand Back**, or leaving the window, continues them, so the owner and an agent
  never type into the same app at once. The seat's display starts only once an agent is in
  use.
- **Desktop tools.** `caboose-desktop-mcp` (stdio MCP server, in the image) gives an agent
  `screenshot`, `click`, `type`, `key`, `scroll`, `launch`, `list_windows` and `focus` on
  `:101`, so an agent can drive GUI apps as well as the shell. Its accessibility tools
  come first, because they need no screenshot and no model round trip: `elements` lists
  the focused window's controls (role, name, state, bounds) from the AT-SPI tree, `find`
  searches them by name and role, `click_element` and `set_text` act on one by id, and
  `read_text` returns the window's text. Xpra keeps a seamless window unmapped until a client
  shows it, so before a coordinate tool runs the server asks Xpra to map the seat's hidden
  windows; `click`, `type` and `screenshot` work whether or not anyone is watching the seat.
  Every task gets it as the MCP server `caboose-desktop` in ACP `session/new`. At task
  creation the host also snapshots installed catalog entries with an `mcp` command and
  offers them as `caboose-<catalog id>` stdio servers in ACP new, load and resume requests.
  Commands and arguments are passed directly, never through a shell. The current catalog
  offers PhotoCraft, LightCraft, FilmCraft, VectorCraft, PDFCraft, EffectCraft, DesignCraft,
  WordCraft, GridCraft, DeckCraft, CADCraft, SoundCraft and FigCraft when installed. An API
  client can set `craftMcp: false` when starting a task to omit these servers for that task;
  the choice persists for replies. The Ask bar menu offers Use Craft App Tools for tasks started
  in the app. Agent support
  for ACP MCP servers and each application's own tools determine what is actually available.

### The registry

The host fetches `registry.json` (`CABOOSE_AGENT_REGISTRY_URL`, by default
`https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json`) when it is first
needed and again after an hour, revalidating with its ETag. The last good copy is kept in
memory and in `${CABOOSE_IMAGE_ROOT}/agent-registry.json` (mode 0600); when a fetch fails
it is served with `registry.error` and the fetch is retried after a minute. Before any
successful fetch the list is empty and says why.

Each agent is resolved for `linux-x86_64`, preferring a binary the registry pins by
SHA-256, then `npx`, then `uvx`, then a binary without a checksum:

| Distribution | Started as |
| --- | --- |
| `npx` | `npx -y <package> <args>` |
| `uvx` | `uvx <package> <args>` |
| `binary` | `<cmd> <args>` inside `~/.local/share/caboose/agents/<id>/<version>/`, after downloading `archive`, checking its `sha256` when given (otherwise HTTPS only), and unpacking it (`.zip`, `.tar.gz`, `.tar.bz2`, `.tar.xz`, or a raw executable) |

with the registry's `env`. Entries without such a distribution, with a command that leaves
its directory, or with a package name that looks like an option are not offered.
**Install** prefetches an agent into the computer (the npm or uv cache, or the binary),
starts it once to learn its sign-in methods, and records the version in
`~/.local/share/caboose/agents/<id>/installed.json`. A task runs the installed version;
installing again moves to the registry's current one. An agent that is not installed
runs the registry's current version, fetched on first use. An installed agent that leaves
the registry stays listed and runnable.

Everything under `/home/caboose` belongs to `caboose`. Installs, sign-ins, tasks and
replies all run as `caboose`, and root's own commands in the guest keep root's home. A
root-owned leftover, such as a cache written by a hand-run command, would still break the
next npm, uv or agent run. So before an install, a sign-in or a runner start, the host
gives anything in the home that is not `caboose`'s back to it: one `find -xdev` pass as
root, at most once every five minutes and again after a restart.

The owner can give an agent extra environment, such as an API key, in
`/home/caboose/.config/caboose/agents/<registry id>.env`: `KEY=VALUE` lines, `#` comments
and blank lines, no shell expansion, one pair of matching quotes around a value removed.
The file must belong to `caboose` and be closed to group and others (mode 0600), or the
runner ignores it and logs why. It is applied after the registry's `env`, for tasks,
installs and sign-ins alike, and its values are never written to transcripts or logs.
Clients edit it with `PUT /v1/agents/:id/env` (below): the runner merges the change
(`caboose-agentd set-env`), keeping the file's other lines, and `GET /v1/agents` lists the
names it sets as `env`, never the values. The host keeps no copy.

### The runner

`caboose-agentd` (`guest/agentd`, installed at `/opt/caboose/agentd`) is the ACP client.
The host's guest channel carries command arguments, not stdin, so the host never speaks
ACP itself: it starts one runner per task, detached (`setsid`), as `caboose`, with
`DISPLAY=:101`, and the two exchange files in the task directory
`/home/caboose/Agents/<task-id>/`. The file formats are specified in `guest/agentd/README.md`;
in short:

- The host writes `task.json` `{ agent: <resolved spec>, cwd, approvals, idleMs }`, prompts
  as `inbox/<turn>.prompt.json`, cancels as `inbox/cancel-<n>.json`, and decisions as
  `approvals/<requestId>.decision`. The runner writes `transcript.jsonl`,
  `approvals/<requestId>.json` and `session`; the launch script records `pid` and
  `exit-code`. Every file is written whole and renamed into place.
- `initialize` advertises file reads and writes (resolved paths, refused outside
  `/home/caboose`), no terminals, and terminal sign-in. The `authMethods` an agent returns
  are kept for the owner (below).
- Each turn is `session/prompt` with a text block, and each attachment as an `image`
  block when the agent accepts images and it is a PNG, JPEG, GIF or WebP under 10 MB,
  otherwise as a `resource_link` to its `file://` path.
- The transcript is the same for every agent: `user` (a turn began), `session`
  (`continuity: new | resume | load | recap`), `text` and `thought` (chunks joined per
  message), `tool` and `tool_update` (title, kind, status), `plan`, `mode`, `permission`,
  `usage`, and exactly one of `turn_end` (ACP `stopReason` and the turn's last message as
  `summary`), `turn_failed` or `auth_required` per turn, each with its turn number.
- After a turn the runner keeps the agent and its session for `CABOOSE_AGENT_IDLE_MS`
  (10 minutes by default) waiting for a reply, then exits 0. A later reply starts a new
  runner, which reopens the conversation with `session/resume` if the agent advertises it,
  else `session/load` (the replayed history is not written again), else `session/new` with
  a recap of the earlier turns from the transcript at the start of the prompt; that turn's
  summary says so.

### Tasks

- **Start.** `POST /v1/agent/tasks` names an agent by registry id, or uses the owner's
  `defaultAgent`. The host resolves it (installed version first), writes the attachments,
  `task.json` and the first prompt, and starts the runner. The task's `prompt` stays as the
  owner wrote it.
- **Ask before acting** (`approvals: "ask"`) works for every agent: each ACP
  `session/request_permission` becomes `approvals/<requestId>.json`
  `{ tool, kind, summary, input, options: [{ id, name, kind }], requestedAt }` and waits,
  with no time limit (the task's lease keeps the computer awake), for the owner's decision
  `{ allow, message?, optionId? }`: the named option, else the agent's `allow_once`
  (`allow_always`) or `reject_once` (`reject_always`). Request ids are UUIDs minted by the
  runner and validated by the host. ACP has no field for a reason, so a denial's `message`
  is kept in the transcript, not shown to the agent. With `approvals: "auto"` the runner
  answers `allow_once` (else `allow_always`) itself; agents also keep their own modes and
  settings.
- **Replies.** A finished task (succeeded, failed or cancelled) can be continued. If its
  runner is still waiting, the prompt goes to the same session; otherwise the reply starts
  a new runner, which takes the prompt from the inbox (a runner that neither takes it nor
  exits within 20 s is stopped). Each turn appends to the same `transcript.jsonl`; the task
  keeps its id, `prompt` and `startedAt`, goes back to `running`, and `turns` counts the
  turns. Output the earlier turn writes after it was cancelled is not shown as the new one.
- **Cancel** writes a cancel to the inbox (continuing a paused task first). The runner sends
  `session/cancel`, answers waiting permission requests `cancelled`, and ends the turn with
  `stopReason: "cancelled"`; an agent that has not stopped after 15 s is terminated, and the
  next reply starts it again. The host reports the task cancelled at once.
- **Signed out.** An ACP `auth_required` error (code -32000) from `session/new`, `load`,
  `resume` or `prompt` fails the task with `summary: "Sign in to <name> first."` and
  `signIn`, the agent's sign-in methods, so a client can offer them; after signing in, a
  reply retries.
- **Polling.** While any task is live the host runs one guest command per second for all
  of them: new transcript bytes from each task's byte offset (1 MiB per tick shared between
  tasks, read as base64 so offsets stay exact), the runner's exit code, and pending approval
  requests. A tick with no live task does nothing. A runner that exits before its turn ends
  fails the task with the end of its stderr.
- **Restore.** Each task directory records its agent, prompt, approval mode and turn count,
  so a restarted host rebuilds the task list from the guest: a task whose last turn ended
  is finished with that turn's result, one whose runner is still working re-takes the
  lease, and either can still be replied to. Task directories written before the runner
  are listed but cannot be continued.

### Signing in

Agents announce their sign-in methods in ACP `initialize`, which the runner records when an
agent is installed, probed or run. Registry agents offer at least one of two kinds:

Sign-in runs on the owner's display, with the same launch environment an app gets there
(`DISPLAY=:100` under Xpra; `WAYLAND_DISPLAY`, Xwayland's `DISPLAY` and the toolkit hints
from `/run/caboose/display.env` under Caboose Display), which the host passes to the runner.

- **`agent`:** `POST /v1/agents/:id/sign-in` starts the runner in sign-in mode on the
  owner's display, and it calls ACP `authenticate`; the agent opens the computer's
  browser at its own sign-in page, with its callback on the computer's localhost, and the
  owner completes it on the phone.
- **`terminal`:** the runner opens a terminal window on that display running the agent's own
  program with the method's `args` in place of the registry's, and its `env` over the
  registry's. Exit status 0 is success; the runner then initializes the agent again.

Progress is reported as `signInStatus` in `GET /v1/agents`
(`~/.local/share/caboose/agents/<id>/sign-in.json`). Credentials stay wherever the agent
keeps them in the owner's home directory.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/v1/agents` | the agents this computer can run (below); never wakes the computer, and shows the last known installed state while it is parked |
| `POST` | `/v1/agents/:id/install` | → `{ agent }`; prefetch the registry's current version into the computer and learn its sign-in methods; can take minutes. 404 for an id not in the registry, 409 while the computer is not running or when it has no runner, 502 when the install fails (with the reason) |
| `PUT` | `/v1/agents/:id/env` | `{ set?: { NAME: value }, remove?: [NAME] }` → `{ env: [NAME] }`; set or remove variables in the agent's environment file in the computer, such as an API key. Names are shell-style, values one line of at most 8192 characters. 400 for invalid input, 409 while the computer is not running |
| `POST` | `/v1/agents/:id/sign-in` | `{ methodId }` → `{ started: true, method: { id, name, description?, type } }`; start a sign-in on the owner's display. 400 for an unknown method |
| `POST` | `/v1/agent/tasks` | `{ prompt, agent?: <registry id>, approvals?: "ask" \| "auto", craftMcp?: boolean, attachments?: [{ name, type, data (base64) }] }` → `{ id }`. `agent` defaults to `defaultAgent` (400 when neither is set); 404 for an id that is not in the registry or installed |
| `GET` | `/v1/agent/tasks` | recent tasks, newest first (task record below) |
| `POST` | `/v1/agent/tasks/:id/reply` | `{ prompt }` → `{ task }`; continue a finished task's conversation. 409 while the task is running or paused, or for a task from before the runner; 404 for an unknown task |
| `POST` | `/v1/agent/tasks/:id/approvals/:requestId` | `{ allow: boolean, message?: string, optionId?: string }` → `{ resolved }`; `resolved: false` when that request is no longer waiting |
| `POST` | `/v1/agent/tasks/:id/cancel` | cancel a running task's turn |
| `POST` | `/v1/agent/tasks/:id/pause` | stop a running task in place for take-over (`status: "paused"`) |
| `POST` | `/v1/agent/tasks/:id/resume` | continue a paused task |
| `GET` | `/v1/display?seat=agent` | **WebSocket.** Relay to the agent seat's Xpra on `:101` |

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

Prompts are 1–32000 characters after trimming; `message` is at most 2000 characters and
`optionId` 200. Agent requests answer 400 for invalid input, 409 while the computer is
not running or when its image has no runner (with how to install it), and 502 when the
registry has never been fetched and the agent is not installed.

Control-socket events: `agent.task.started { id, agent, agentName?, prompt }`,
`agent.task.output { id, kind: "text" | "tool" | "error", text }` (each agent message, each
new tool call by title, and a failed turn's error), `agent.task.paused { id }`,
`agent.task.resumed { id }`,
`agent.task.finished { id, status: "succeeded" | "failed" | "cancelled", summary, signIn? }`,
`agent.task.replied { id, prompt, turn }`,
`agent.task.approval { id, request: { id, tool, summary, options? } }` (once per request),
`agent.task.approval.resolved { id, requestId, allow }`. Tasks keep running while the
phone is locked: the computer is a server, and the host holds a lease while any task runs,
so the computer is not parked under a working agent.

**Compatibility with clients written for the two built-in CLIs.** Routes and events keep
their shapes; fields are only added. `agent` is now a registry id: a request naming
`"claude"` or `"codex"` runs `claude-acp` or `codex-acp`, and task records carry the
registry id and `agentName`. Any agent may ask before acting. A denial's `message` no
longer reaches the agent. A signed-out agent's summary names the agent, and its `signIn`
methods replace the advice to sign in from Terminal.

### Screen

The owner's display can be read and acted on through its accessibility tree, so a client —
an agent running on the phone, or the web console — can work with what the owner sees
without pixels:

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/v1/screen/elements` | `{ window: { title, app }, elements: [{ id, role, name, states, bounds: { x, y, width, height } }], note? }`: the focused window's visible controls on the owner's display, at most 200, and `note` when there are none to say why |
| `POST` | `/v1/screen/act` | `{ element: id, action: "press" \| "focus" \| "set-text", text? }` → `{ ok }`; 404 when the element is gone |
| `POST` | `/v1/screen/type` | `{ text }` (1–10000 characters): type into the focused window on the owner's display |
| `POST` | `/v1/screen/keys` | `{ keys }`: press key combinations such as `ctrl+s` or `ctrl+shift+t Return` on the owner's display |

Element ids are opaque strings valid until the window changes. These routes act only on
the owner's display, on the owner's own command, and answer 409 while the computer is not
running. They run `/opt/caboose/a11y.py` in the guest as `caboose` — the AT-SPI helper
behind the desktop tools — and `xdotool`. The helper finds each display's accessibility
bus itself and reads only an application whose windows are all on the requested display,
so the agent seat never reads or presses the owner's windows. Xpra, Chromium, VS Code and
Firefox are started with their accessibility trees enabled so web content is included.

They run with the owner display's launch environment on its X display: Xpra's `:100`, or
Xwayland's under Caboose Display. Both tools find the focused window and send keys through
X, so under Caboose Display they reach X11 windows only. A native Wayland window, such as
Chromium, is not read, and `elements` says "No window is open on this display." while one
is focused. Reading and typing into Wayland windows needs the compositor to report focus
and inject input, and that is not built yet.

### Files

The private `guest/files` service listens on guest TCP port 14700, runs as `caboose`, and
reads the same per-wake token file as the displays on every request. The microVM host reaches
it over the fenced TAP; the container publishes it on host loopback only. Both guest images
install it. The host relays bytes without buffering an entire file and holds a lifecycle
lease from wake until the response completes. Existing computers receive this service through the guest-components upgrade described above.

The `/v1/fs` routes above require the owner bearer token. `path` and `destination` are
relative to `/home/caboose`; the empty path denotes the root. Traversal, absolute paths,
NULs, symlinks and special files are rejected, and directory components are opened without
following symlinks. Names beginning `.caboose-upload-` are reserved for temporary uploads.
Lists return `{ items: [{ name, kind, size, mtime, etag, contentType, identity }] }`; `kind`
is `file` or `directory`, `mtime` is Unix milliseconds, and the opaque quoted `etag` changes
on replacement or modification. `identity` identifies a Linux inode and helps the Files
provider reconcile a rename after an expired anchor; hard links can share it.

A GET of `content` streams bytes, accepts a single `Range: bytes=…` including suffix ranges,
and answers 206 with `Content-Range` or 416 for an unsatisfiable range. PUT streams a file
with a known length or chunked transfer encoding to a temporary file, then atomically places
it. Use `If-None-Match: *` for create and `If-Match: <etag>` for replacement; a version
mismatch returns 412 and replacement without a precondition returns 428. The version check
is immediately before placement, but Linux applications do not participate in the service's
lock, so it cannot make that check atomic with a concurrent direct filesystem write. `mkdir`
returns 201; move accepts an optional `If-Match` and refuses an existing destination (409);
delete also accepts `If-Match` and uses the freedesktop home Trash. A move to Trash across
filesystems can fail instead of permanently deleting the item.

`changes` returns `{ anchor, changed, reset, events: [{ path, removed, cookie }] }`.
Anchors are opaque and scoped to one guest-service instance. A missing, expired, overflowed,
or previous-instance anchor has `reset: true` and requires a complete re-enumeration; the
journal is bounded. Rename events carry the inotify cookie to associate the old and new path.
When a control socket is connected the host polls the journal and broadcasts
`{ type: "fs.changed", anchor }`; a client also checks its anchor on enumerator wake.

The replicated iOS File Provider registers a domain named for the paired computer, enumerates
its home, downloads on demand, and uploads coordinated edits with version checks. It tracks
stable provider IDs in its extension storage across moves, signals the working set when the
app receives `fs.changed`, and re-enumerates after an expired anchor. It requests file bytes
on demand; the system can generate previews for materialized files. Separate server-side
thumbnail generation is not implemented. Files access wakes a parked computer; an offline
host is reported to Files as unreachable. Device behavior requires the real-host and device
checks in the component READMEs.
The provider supports coordinated writes back to the computer. The app-level open workflow
and its separate external-document sync are described in Open in place.

`POST /v1/files` remains available for existing clients: it accepts `{ name, data, open? }`
with base64 data, picks a unique name in `~/Downloads`, and uses the bulk service. Its JSON
body still has to be held in memory, so new clients should use streamed `PUT /v1/fs/content`.
The Share extension uploads from a temporary file and optionally opens it on the computer.
`POST /v1/fs/open` accepts an optional `app` desktop entry ID; it checks the path through
the file service and passes it as a file argument to that application’s desktop entry.
`POST /v1/open` opens an `http(s)` URL on the owner's display; other schemes, control
characters and spaces are rejected. It answers 409 while the computer is not running.

## Open in place

The iOS build derives its alternate-handler document declarations from `guest/catalog/catalog.json`;
`apps/ios/scripts/document-types.py --write` updates the checked snapshot and the build checks it
before generating the app Info.plist. Catalog extensions without a recorded system identifier get
an imported Caboose UTI. The list is limited to associations recorded in the catalog; an empty
file type list is not evidence that an app handles a type. Project files can reference media
separately; opening one document does not upload those dependencies.

A file URL delivered to the app opens a chooser of catalog applications that list its extension
or type, including installable apps with progress, and other installed apps. For an external file,
Caboose coordinates a read, streams a snapshot to `Caboose Documents/<uuid>/<filename>` through
`/v1/fs`, stores the security-scoped bookmark and paired-computer identity in the application
group, and launches the selected desktop entry with the file. A copy delivered into the app’s Inbox is identified as a copy and the chooser warns that
changes cannot return to its source. The chooser is also in the Share extension. It asks for an in-place representation; if the provider only offers a temporary copy,
the extension warns that edits cannot be written back and only proceeds after the user chooses
Open Copy. The extension cannot itself bring the containing app to the foreground; returning to
Caboose shows the launched window when it can identify it. A Files URL belonging to Caboose's own
File Provider is translated through the provider's shared identifier index and opens its existing
computer path without a copy. If the index is unavailable, opening fails instead of silently
making another copy.

For an external original with a persistent bookmark, the app compares a hash of a coordinated
local snapshot and the remote file's ETag to the last synchronized versions. A single changed
side is copied to the other; both changed presents Keep Original or Keep Computer Copy. Downloads
are version-checked again before a coordinated replacement, and writes to the computer carry
`If-Match`. A changed original during a replacement or a changed remote version fails the attempt
and is checked again rather than silently choosing a winner. The app reconciles after `fs.changed`
and when it resumes or reconnects, so changes made while suspended are caught up when iOS runs it
again; iOS does not guarantee continuous execution or immediate synchronization while suspended.
Failures and stale bookmarks are shown in the app. The service's precondition is not atomic with a
Linux application's direct write, as described in Files. A deleted or renamed computer copy is
reported as a sync error; automatic rebinding is not supported.

The app, Share extension and File Provider require the `group.com.braedonsaunders.caboose`
application group in their signing profile, in addition to their keychain access group. A signed
device and real computer are required to verify provider bookmarks, extension handoff, coordinated
replacement and resumed sync; run `apps/ios/scripts/check-open-in-place.sh` and follow its checks.

## Media handoff

Video reaches the phone the way every window does (see `docs/display.md`, "Video, for
every app"). Media handoff is only a user action on top of that: from a window's menu,
**Play on iPhone / Apple TV** moves a video playing in the computer's Chromium to the phone,
pauses the Linux copy, and afterwards resumes the Linux copy at the phone's position. It
treats every site the same way; there are no per-site rules.

**Guest** (`guest/media-handoff/`, installed in the image): a Chromium extension, ID
`cklinclacpchpdgickgonlhnldfmkhbh` (fixed by the public key in its manifest), and its native
messaging host `com.caboose.media`. The extension watches every `<video>` in every http(s)
page and frame and offers the most recently started playing one (or, if none plays, the
most recently started one). The native host keeps `/home/caboose/.cache/caboose/media.json`
equal to it (atomically replaced, removed when nothing is offered or the browser closes),
records its pid in `media-host.pid`, and forwards commands from `media-command.json`.

| Offered as | When | Played on the phone from |
| --- | --- | --- |
| `kind: "hls"`, `src` | `currentSrc` is http(s) and its path ends in `.m3u8` | `src`, natively |
| `kind: "video"`, `src` | any other http(s) `currentSrc` | `src`, natively |
| `kind: "page"` | `currentSrc` is a `blob:` the page assembled (MediaSource) | the page, in the phone's browser; the position does not carry over |

Not supported: DRM (EME) playback off the computer, `data:` and MediaStream sources (calls,
cameras), muted looping videos (page decoration), videos inside shadow roots, and other
browsers. `src` is
the page's own URL for the media; cookies, headers and short-lived signed URLs may not
work off the computer, which the phone reports as a playback failure.

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
every 5 seconds while playing. In the guest file `updatedAt` is the guest-clock sample time.
**caboose-host** reads the file (with the guest's clock, so skew does not matter) about
once a second, and only while the computer is already `running` *and* at least one display
client is connected; reads go straight to the guest, so they never wake the computer, hold
a lease or delay idle parking. A file whose native host is no longer running is ignored.
What the host sends has `position` extrapolated to the moment it is sent while playing
(capped at `duration`), and `updatedAt` set to that moment on the host's clock.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/v1/media` | `{ media: <state> \| null }`; null unless the computer is running. Does not wake or lease |
| `POST` | `/v1/media/:id/control` | `{ action: "pause" \| "play", position?: number }` → `{ sent: true }` |

Control validates strictly (400): the raw `:id` path segment must match
`/^[A-Za-z0-9._-]{1,64}$/`; the body may contain only `action` and `position`; `position`
(seconds, 0–10⁷) is allowed only with `play`, which seeks there and plays. A parked or
waking computer returns 409; control does not wake it (call `POST /v1/session` first).
The host writes `{ seq, id, action, position? }` to
`/home/caboose/.cache/caboose/media-command.json` as user `caboose`, `seq` increasing (ms
based, so across host restarts too). `sent` means the command reached the computer; an id
the browser no longer has (tab closed) is ignored there, and the next state shows the
result.

Control-socket events: `media.playing { media }` on every change of the state (including
each 5-second heartbeat while playing, and once more when polling starts), and
`media.stopped { id }` when that video stops being offered (it ended, its tab closed, the
browser closed, another video replaced it, or the computer stopped running). A control
socket that connects while polling is running receives the current `media.playing` after
`computer.settings`.

The handoff flow on the phone: on `media.playing`, offer the video; to hand off, play it
natively from `position`, then `POST …/control { action: "pause" }`; when the phone stops,
`POST …/control { action: "play", position: <phone position> }`.

## Iteration 1: done means

Open Caboose on the iPhone, sign in with the owner token and host URL, watch it
wake the computer, pick Chromium or the terminal from the home grid, and use it:
native full-screen surface, smooth H.264, touch and keyboard input, clipboard both
ways. Background the app and come back: everything is where it was.

## Decisions

- **Xpra seamless over a whole-desktop stream** — per-window is the product; Xpra
  ships it today.
- **Relay, do not transcode, on the host** — the host never decodes pixels, so a
  host serves many users and latency stays guest → phone.
- **Cloud Hypervisor + raw CoW overlays + park-with-memory** — inherited from
  appkit-desk; resumable is the product too.
- **AGPL-3.0** — like AppKit and Bunkhouse; self-hostable, with a hosted service.
