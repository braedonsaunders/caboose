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
  <img alt="Status: pre-alpha" src="https://img.shields.io/badge/status-pre--alpha-ef4444" />
  <img alt="iOS 26+" src="https://img.shields.io/badge/iOS-26%2B-1b2b4a" />
  <img alt="Self-hostable" src="https://img.shields.io/badge/self--host-Docker%20%2B%20KVM-1b2b4a" />
</p>

<p align="center">
  <a href="#why-caboose">Why</a> ·
  <a href="#what-it-feels-like">What it feels like</a> ·
  <a href="#whats-inside">What's inside</a> ·
  <a href="#how-it-works">How it works</a> ·
  <a href="#run-your-own">Run your own</a> ·
  <a href="#status">Status</a> ·
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
| **iOS app** (`apps/ios`) | SwiftUI shell over UIKit and Metal. Each Linux window is a Metal texture; H.264 and HEVC decode in VideoToolbox straight into GPU memory, and redraws present only what changed. Touch, hardware trackpad and mouse, the iOS keyboard with dictation, ⌘ shortcuts mapped for Mac hands, and a TV mode with the phone as a trackpad. |
| **CabooseKit** (`apps/ios/CabooseKit`) | A native Xpra client as a Swift package: rencodeplus codec, packet framing, WebSocket transport, capabilities and HMAC auth, window registry, flow-controlled draw pipelines, clipboard and notifications. Unit-tested against captured protocol vectors. |
| **Host** (`apps/host`) | `caboose-host`, TypeScript on Node 22. Owner-token auth, computer lifecycle (wake, lease, park with memory, cold restart), a display relay that never decodes a pixel, the agent task API, and the management API. |
| **Console** (`apps/web`) | The self-host web console the host serves: state and resources, wake, park and restart, settings, agent tasks, and the link that signs an iPhone in. |
| **The computer** (`guest/`) | A Debian 13 golden image on Cloud Hypervisor. Each computer is a copy-on-write clone, so it costs nothing up front and keeps its own installs. The image includes Chromium, Firefox, VS Code, LibreOffice, GIMP, Obsidian, Docker, a modern shell kit, and Claude Code, Codex, OpenCode and Gemini CLI. On a GPU host it can run as a container with NVENC, VA-API or D3D12 instead. |
| **Agents** | Any agent in the [Agent Client Protocol registry](https://github.com/agentclientprotocol/registry), installed and signed in from the console, run by `caboose-agentd` in the computer on a second display only agents use, with `caboose-desktop-mcp` giving them screenshot, click, type, scroll and launch tools for GUI apps. |

## How it works

```
 iPhone · iPad · TV                       your server (Linux + /dev/kvm)
 ┌──────────────────────────┐             ┌───────────────────────────────────────┐
 │ Caboose (Swift)          │  HTTPS+WSS  │ caboose-host (Node 22)                │
 │  Home grid, app cards,   │ ──────────▶ │  wake · lease · park-with-memory      │
 │  windows on iPad / TV    │ /v1/session │  display relay (bytes, never pixels)  │
 │  CabooseKit: Xpra client │ /v1/display │  control: apps, agents, settings      │
 │  VideoToolbox → Metal    │ /v1/control │           │ vsock + TAP               │
 └──────────────────────────┘             │ ┌─────────▼─────────────────────────┐ │
                                          │ │ microVM: Debian 13, CoW home      │ │
                                          │ │  Xpra seamless :100  (you)        │ │
                                          │ │  Xpra seamless :101  (agents)     │ │
                                          │ │  Chromium, VS Code, Claude Code…  │ │
                                          │ └───────────────────────────────────┘ │
                                          └───────────────────────────────────────┘
```

- **Per-window, not per-desktop.** Xpra in seamless mode streams every window with its
  own title, icon, size hints and parent, and only re-encodes what changed. That's what
  lets the phone show a Linux app as an app.
- **Relay, don't transcode.** The host passes the stream through untouched, so latency
  is guest-to-phone and one host can serve many computers.
- **Park with memory.** Cloud Hypervisor snapshots (via
  [`appkit-desk`](https://github.com/braedonsaunders/appkit)) make resuming the product
  rather than an optimisation.
- **Fenced by default.** The guest can't open anything on the host, and it reaches only
  the public internet. Private, link-local, CGNAT and Tailscale ranges are blocked unless
  you allow your LAN.
- **Next: Caboose Display.** A GPU-native per-window compositor that encodes straight from
  GPU memory, aiming at 4K60 on the phone and TV. It's designed but not built yet; see
  [docs/display.md](docs/display.md).

The full contract between app, host and guest is [docs/architecture.md](docs/architecture.md).

## Run your own

You need an amd64 Linux machine with hardware virtualization (`/dev/kvm`), Docker and
Compose.

```sh
git clone https://github.com/braedonsaunders/caboose.git && cd caboose

# A long random owner token, kept private
umask 077 && printf 'CABOOSE_OWNER_TOKEN=%s\n' "$(openssl rand -hex 32)" > deploy/.env

docker compose -f deploy/compose.yaml up -d --build
```

Then:

1. **Build the computer's image** with `guest/image/build.sh` and copy `base.raw`,
   `vmlinux` and `initrd` into the host's disk root ([guest/image](guest/image/README.md)).
2. **Open the console** at `http://localhost:7310` (or behind your HTTPS proxy), sign in
   with the owner token, and use **Connect your iPhone** to sign the app in.
3. **Build the iOS app** with XcodeGen ([apps/ios](apps/ios/README.md)).

The host listens on loopback by default and speaks plain HTTP. Put HTTPS in front of it
before traffic crosses a network. The container is privileged for KVM and TAP networking,
so run it on a host you trust. All the details, including the GPU container runtime for
WSL2 and NVIDIA, are in [apps/host](apps/host/README.md) and
[guest/container](guest/container/README.md).

## Status

**Pre-alpha, moving fast.** The host, guest image, iOS app and console have run together
against a real KVM host, covering wake, park and resume, per-window H.264 and HEVC, the
TV desktop, sound, agents on their own seat, and settings and restart. The Docker
deployment hasn't been verified end to end yet, and Caboose Display is a design. Iteration
1 is done when you can open the app, watch your computer wake, tap Chromium or the
terminal, use it, leave, and come back to find it exactly as you left it.

## Repository

| Path | What |
| --- | --- |
| [`apps/ios`](apps/ios) | The iPhone and iPad app, and `CabooseKit`, its Xpra client |
| [`apps/host`](apps/host) | `caboose-host`: computer lifecycle, display relay, agents and management API |
| [`apps/web`](apps/web) | The self-host console the host serves (React, AppKit UI) |
| [`guest/image`](guest/image) | The golden machine image: Debian 13, Xpra seamless, apps and agent CLIs |
| [`guest/container`](guest/container) | The same computer as a GPU container, for WSL2 and Linux GPU hosts |
| [`guest/display`](guest/display) | Caboose Display: the per-window display server, its protocol and golden vectors (Rust) |
| [`guest/agentd`](guest/agentd) | `caboose-agentd`: the ACP client that runs any registry agent for a task |
| [`guest/desktop-mcp`](guest/desktop-mcp) | GUI tools for agents on their own seat |
| [`docs`](docs) | Architecture, the Xpra protocol notes and the Caboose Display design |

Each component's README covers how to build, run and test it. Pure logic is unit-tested
(`swift test` in `apps/ios/CabooseKit`, and `pnpm test` at the root for the host,
console and agent runner). Anything that touches KVM, Xpra or a device has a scripted check next to the
code.

Caboose is built on [AppKit](https://github.com/braedonsaunders/appkit), notably
`appkit-desk`, the Cloud Hypervisor microVM layer it shares with
[Bunkhouse](https://github.com/braedonsaunders/bunkhouse), and it contributes its
improvements upstream. To contribute, start with [AGENTS.md](AGENTS.md) and
[docs/architecture.md](docs/architecture.md).

## License

[AGPL-3.0-or-later](LICENSE).
