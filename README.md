<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/assets/caboose-logo-dark.svg" />
    <img src=".github/assets/caboose-logo.svg" alt="Caboose" width="460" />
  </picture>
</p>

<p align="center">
  <strong>Your phone's computer.</strong><br />
  A real Linux machine that lives on a server, wakes the moment you open it, and parks
  itself (every app still open) when you leave. On your iPhone it isn't a remote desktop:
  each Linux app arrives as its own native surface.
</p>

<p align="center">
  <a href="LICENSE"><img alt="License: AGPL-3.0-or-later" src="https://img.shields.io/badge/License-AGPL--3.0--or--later-f5a623" /></a>
  <img alt="Status: pre-release" src="https://img.shields.io/badge/status-pre--release-ef4444" />
  <img alt="iOS 26+" src="https://img.shields.io/badge/iOS-26%2B-1b2b4a" />
  <img alt="Self-hostable" src="https://img.shields.io/badge/self--host-Docker%20%2B%20KVM-1b2b4a" />
</p>

<p align="center">
  <a href="#why-caboose">Why</a> ·
  <a href="#what-it-feels-like">What it feels like</a> ·
  <a href="#whats-inside">What's inside</a> ·
  <a href="#how-it-works">How it works</a> ·
  <a href="#run-your-own">Run your own</a> ·
  <a href="docs/architecture.md">Architecture</a>
</p>

---

## Why Caboose

The phone is the computer most people carry and the least capable one they own.
Cloud desktops fix the capability and lose the phone: you get a picture of a desktop
squeezed onto glass and driven by a fake mouse. Agent computers solve a different problem.
The machine belongs to the agent, and you watch.

Caboose starts from the other end:

- **Linux apps as native surfaces.** Every window streams on its own, with its title,
  icon, menus and dialogs. On iPhone it behaves like an app; on iPad or a TV it behaves
  like a window. Menus and dialogs sit next to the window they belong to, not in a
  separate frame.
- **Resumable, not rebooted.** Your computer parks with its memory. Reopen the app and
  every program is exactly where you left it.
- **Shared with agents, without fighting them.** Any agent from the Agent Client
  Protocol registry runs on the same machine on its own seat, so it never steals your
  pointer. Agents keep working while your phone is locked, and you can take over any time.
- **Yours.** Open source and self-hostable, and you bring your own model accounts. The
  host holds no model keys.

The name is the railway's: the caboose is the car at the back of the train where the crew
lived and worked. Here it's the computer that comes along wherever your phone goes.

## What it feels like

1. **Open Caboose.** The computer wakes, and a parked machine resumes with its memory
   rather than booting.
2. **Tap an app.** The Home grid lists the computer's real Linux apps with their real
   icons. Chromium, VS Code or the terminal opens full screen, decoded in hardware, with
   touch, keyboard, trackpad and clipboard working both ways.
3. **Leave.** Background the app and the stream closes. After the idle timeout the
   computer parks with its memory. Come back tomorrow and everything is where it was.
4. **Put it on the TV.** Connect a display and the Linux desktop moves to the big screen
   while the phone becomes its trackpad. You can also open the desktop on the phone or
   iPad itself.
5. **Hand work to an agent.** Ask from the Ask bar. The task runs on the agent's own
   seat, and its windows show up in an Agent space you can watch, take over and hand
   back.

## What's inside

| | |
| --- | --- |
| **iOS app** (`apps/ios`) | SwiftUI shell over UIKit and Metal. Each Linux window is its own Metal surface; H.264, HEVC and, where the device has a decoder, AV1 decode in VideoToolbox straight into GPU memory. Touch, hardware trackpad and mouse, the iOS keyboard with autocorrect, dictation and CJK input, ⌘ shortcuts sent as Control, and a TV mode with the phone as a trackpad. Extensions put the computer in the Files app and the share sheet, and add widgets and Live Activities. |
| **CabooseKit** (`apps/ios/CabooseKit`) | The display client as a Swift package: `CabooseDisplaySession` speaks the Caboose Display Protocol, with native touch, IME text, video layers and Opus sound. Unit-tested against the protocol's golden vectors. |
| **Host** (`apps/host`) | `caboose-host`, TypeScript on Node 22. Owner-token auth, computer lifecycle (wake, lease, park with memory, cold restart), a display relay that never decodes a pixel, the app catalog, files, the agent task API, and the management API. |
| **Console** (`apps/web`) | The self-host web console the host serves, for running the server rather than using the computer: what the computers are given of the machine, each computer's state, wake, park and restart, files, catalog apps, phones and settings, and the host's own health and configuration. |
| **The computer** (`guest/`) | A Debian 13 golden image on Cloud Hypervisor. Each computer is a copy-on-write clone of it and keeps its own installs. The image includes Chromium, Firefox, VS Code, LibreOffice, Obsidian, Docker, a modern shell kit, and Claude Code, Codex, OpenCode and Gemini CLI; more apps, such as GIMP, install from the catalog. On a GPU host it can run as a container instead (WSL2, NVIDIA, or an Intel or AMD render node). |
| **Caboose Display** (`guest/display`) | The computer's display server, in Rust: a headless Wayland compositor with Xwayland that streams each window on its own. |
| **Agents** | Any agent in the [Agent Client Protocol registry](https://github.com/agentclientprotocol/registry), installed and signed in from the iPhone app, run by `caboose-agentd` in the computer on a second display only agents use, with `caboose-desktop-mcp` giving them accessibility-tree, screenshot, click, type, key, scroll, drag and launch tools for GUI apps. |

## How it works

```
 iPhone · iPad · TV                       your server (Linux + /dev/kvm)
 ┌──────────────────────────┐             ┌───────────────────────────────────────┐
 │ Caboose (Swift)          │  HTTPS+WSS  │ caboose-host (Node 22)                │
 │  Home grid, app cards,   │ ──────────▶ │  wake · lease · park-with-memory      │
 │  windows on iPad / TV    │ /v1/session │  display relay (bytes, never pixels)  │
 │  CabooseKit: display     │ /v1/display │  control: apps, agents, settings      │
 │  VideoToolbox → Metal    │ /v1/control │           │ vsock + TAP               │
 └──────────────────────────┘             │ ┌─────────▼─────────────────────────┐ │
                                          │ │ microVM: Debian 13, CoW home      │ │
                                          │ │  Caboose Display :14600  (you)    │ │
                                          │ │  Caboose Display :14601  (agents) │ │
                                          │ │  Chromium, VS Code, Claude Code…  │ │
                                          │ └───────────────────────────────────┘ │
                                          └───────────────────────────────────────┘
```

- **Per-window, not per-desktop.** Every window is its own stream with its own title,
  icon, size hints and parent, and only what changed is re-encoded. That's what lets the
  phone show a Linux app as an app.
- **Relay, don't transcode.** The host passes the stream through untouched, so latency
  is guest-to-phone and the host spends nothing on pixels.
- **Park with memory.** Cloud Hypervisor snapshots (via
  [`appkit-desk`](https://github.com/braedonsaunders/appkit)) make resuming the product
  rather than an optimisation.
- **Fenced by default.** The guest can't open anything on the host, and it reaches only
  the public internet. Private, link-local, CGNAT and Tailscale ranges are blocked unless
  you allow your LAN.
- **Caboose Display.** Caboose's own display server ([guest/display](guest/display),
  [docs/display.md](docs/display.md)): a headless Wayland compositor with Xwayland that
  streams each window on its own, paced by the phone's screen. Nothing runs while nothing
  changes. Video-rate regions become their own motion streams, still text sharpens once,
  and the computer's sound goes as Opus in step with the pictures. Touch and the iOS
  keyboard (autocorrect, dictation, CJK) arrive as native Wayland input, and the
  clipboard works across the phone, Wayland and X11 apps. Players that decode through
  VA-API hand their compressed video straight to the phone ([guest/vaapi](guest/vaapi)).
  It encodes with NVENC where the host has an NVIDIA GPU, otherwise with x264.
- **Two seats.** The owner's display and the agent seat are separate Caboose Display
  instances, each with its own Wayland and X11 displays and its own D-Bus session. The
  phone's on-device agent and the computer's agents read and drive them through the
  accessibility tree and each seat's control socket, Wayland and X11 apps alike, and the
  app watches the agent seat, without sound, in the Agent space.

The full contract between app, host and guest is [docs/architecture.md](docs/architecture.md).

## Run your own

You need an amd64 Linux machine with hardware virtualization (`/dev/kvm`), Docker and
Compose.

```sh
git clone https://github.com/braedonsaunders/caboose.git && cd caboose
docker compose -f deploy/compose.yaml up -d --build

# The owner token the host generated on first start
docker compose -f deploy/compose.yaml exec caboose-host cat /data/caboose/disks/owner-token
```

Then:

1. **Install the computer's image.** A release host fetches it on first start and verifies
   it; until the first release is published, build it with `guest/image/build.sh`, which
   writes `base.raw`, `vmlinux` and `initrd` to `/data/caboose/disks`, the host's disk root
   ([guest/image](guest/image/README.md), [apps/host › Images](apps/host/README.md#images)).
2. **Open the console** at `http://localhost:7310` (or behind your HTTPS proxy), sign in
   with the owner token, open your computer under **Computers**, and on **Phones** use
   **Sign in a phone**: scan the QR code with the iPhone. **New computer** adds more
   computers, each with its own disk and phones.
3. **Build the iOS app** with XcodeGen ([apps/ios](apps/ios/README.md)).

The host listens on loopback by default and speaks plain HTTP. Put HTTPS in front of it
before traffic crosses a network. The container is privileged for KVM and TAP networking,
so run it on a host you trust. All the details, including the GPU container runtime for
WSL2 and NVIDIA, are in [apps/host](apps/host/README.md) and
[guest/container](guest/container/README.md).

## Repository

| Path | What |
| --- | --- |
| [`apps/ios`](apps/ios) | The iPhone and iPad app, its extensions, and `CabooseKit`, its display client |
| [`apps/host`](apps/host) | `caboose-host`: computer lifecycle, display relay, agents and management API |
| [`apps/web`](apps/web) | The self-host console the host serves (React, AppKit UI) |
| [`guest/image`](guest/image) | The golden machine image: Debian 13, Caboose Display, apps and agent runtimes |
| [`guest/container`](guest/container) | The same computer as a GPU container, for WSL2 and Linux GPU hosts |
| [`guest/display`](guest/display) | Caboose Display: the per-window display server, its protocol and golden vectors (Rust) |
| [`guest/vaapi`](guest/vaapi) | The VA-API codec-passthrough driver that forwards apps' compressed video to the phone (C) |
| [`guest/agentd`](guest/agentd) | `caboose-agentd`: the ACP client that runs any registry agent for a task |
| [`guest/desktop-mcp`](guest/desktop-mcp) | GUI tools for agents on their own seat, and the accessibility helper behind `/v1/screen` |
| [`guest/catalog`](guest/catalog) | The optional apps and packs the computer can install |
| [`guest/files`](guest/files) | The file service behind the Files app extension and the console |
| [`guest/notifications`](guest/notifications) | The owner's desktop notifications, forwarded to the phone |
| [`guest/phone`](guest/phone) | Opening, sharing and printing from the computer to the phone |
| [`guest/media-handoff`](guest/media-handoff) | Play on iPhone / Apple TV for video playing in the computer's Chromium |
| [`docs`](docs) | The architecture, and the Caboose Display design and protocol |

Each component's README covers how to build, run and test it. Pure logic is unit-tested
(`swift test` in `apps/ios/CabooseKit`, `cargo test` in `guest/display`, and `pnpm test`
at the root for the host, console and agent runner). Anything that touches KVM, a display
or a device has a scripted check next to the code.

Caboose is built on [AppKit](https://github.com/braedonsaunders/appkit), notably
`appkit-desk`, the Cloud Hypervisor microVM layer it shares with
[Bunkhouse](https://github.com/braedonsaunders/bunkhouse), and it contributes its
improvements upstream. To contribute, start with [AGENTS.md](AGENTS.md) and
[docs/architecture.md](docs/architecture.md).

## License

[AGPL-3.0-or-later](LICENSE).
