# Caboose architecture

Caboose is your phone's computer. It is a persistent Linux machine that lives on a
server, wakes the moment you open the app, parks itself (memory and all) when you
leave, and is shared by you and your agents. On the phone it does not look like a
remote desktop: each Linux application arrives as its own native iOS surface.

This document is the contract every component is built against. Change it in the
same pull request as the code that changes the contract.

## The pieces

```
 iPhone / iPad / external display                     server (Linux + /dev/kvm)
 ┌───────────────────────────────┐                     ┌──────────────────────────────────────┐
 │ Caboose app (Swift)           │   HTTPS + WSS       │ caboose-host (TypeScript, Node 22)    │
 │  ├ Shell: home grid, app      │ ──────────────────▶ │  ├ Accounts + device tokens           │
 │  │  cards, windows on iPad/TV │   /v1/session       │  ├ Desk lifecycle (appkit-desk):      │
 │  ├ CabooseKit (Swift package) │   /v1/display (WS)  │  │  wake, lease, park-with-memory     │
 │  │  ├ Xpra protocol client    │   /v1/control (WS)  │  ├ Display relay: WS ⇄ guest TCP       │
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

A Debian 13 (trixie, amd64) golden image booted by Cloud Hypervisor. Each computer's
disk is a reflink copy-on-write clone of the base, exactly the appkit-desk model: it
costs no space up front and each user's installs and home persist. A clone is
independent of the base once made, so a new base image reaches new computers only;
updating existing ones is a guest-side upgrade (apt and the Caboose units), not a
base swap.

- **Display server: Xpra in seamless mode** on display `:100`, listening for
  WebSocket on `0.0.0.0:14500` inside the guest (reachable only from the host over
  the desk's TAP device). Seamless mode is the reason for the choice: every
  application window is its own stream with its own title, icon, class, size
  hints, transient/popup relationships and damage-driven H.264, which is what lets
  the phone render Linux apps as native surfaces instead of a picture of a
  desktop. Xpra also already carries clipboard, notifications, file transfer,
  audio, printing, webcam and cursor shapes. A Wayland compositor of our own can
  replace it later behind the same client window model.
- **Session auth.** Xpra requires a per-boot token (`tcp-auth`/`ws-auth` via an
  `env`/file authenticator). The host writes it with `desk.exec` at wake and hands
  it to the client inside the authenticated `/v1/session` response.
- **Apps** installed in the image: Chromium, Firefox ESR, VS Code, a terminal
  (xfce4-terminal), Thunar, Mousepad, LibreOffice, Node 22, git, ripgrep, Claude
  Code, Codex CLI. Fonts: Inter, JetBrains Mono, Noto (incl. CJK, emoji).
- **Guest agent.** The appkit-desk guest agent (vsock 5252) for exec, jobs,
  observe/a11y and agent input. Agents drive the machine through it; humans drive
  it through Xpra.
- **Agent seat.** A second Xpra display (`:101`) is reserved for agents so an
  agent never steals the user's pointer; its windows appear in the app's Agent
  space.

### 2. Host: `caboose-host` (`apps/host/`)

TypeScript on Node 22, built on AppKit packages. It owns no display logic: the
Xpra byte stream is relayed, not parsed.

HTTP API (all JSON, all behind `Authorization: Bearer <device token>`):

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/v1/health` | host + KVM + desk host stats |
| `POST` | `/v1/session` | wake the user's computer (start or resume), ensure Xpra is up, return `{ state, display: { path, token, protocol: "xpra-ws" }, computer: { name, image, memoryMb, vcpus } }` |
| `GET` | `/v1/display` | **WebSocket.** Binary relay to the guest's Xpra WS. Subprotocol passthrough (`binary`). One relay per client connection |
| `GET` | `/v1/apps` | launchable apps from the guest's `.desktop` files: `{ id, name, icon (PNG data URL), categories, exec }` |
| `POST` | `/v1/apps/:id/launch` | start an app on display `:100` |
| `POST` | `/v1/session/park` | park now (snapshot with memory); otherwise parked on idle |
| `GET` | `/v1/control` | **WebSocket.** JSON events: `computer.state`, `notification`, `agent.*` |

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

### 3. App: Caboose for iOS (`apps/ios/`)

Swift, SwiftUI shell over UIKit surfaces, iOS 26+, project generated by XcodeGen.

- **CabooseKit** (Swift package, no UI): `XpraConnection` (WebSocket transport,
  packet framing, rencodeplus codec, hello/capabilities, keepalive), `XpraSession`
  (window registry, metadata, cursors, clipboard, notifications), decoders
  (`VTDecompressionSession` for H.264; ImageIO for png/jpeg/webp; raw rgb), and
  input encoders (pointer, scroll, key events with keysyms). Unit-tested on macOS.
- **Shell.** On iPhone each Linux window is an app card: full screen, native
  app-switcher gestures between them, home grid of Linux apps with their real
  icons. On iPad and external displays the same windows float, resize and stack,
  with a dock and menu bar. Transient windows (menus, dialogs, tooltips) are
  positioned relative to their parent, never as separate cards.
- **Input.** Touch maps to pointer with tap/drag/long-press, swipe to scroll
  with momentum (precise wheel motion when the server reports `wheel.precise`,
  otherwise whole wheel clicks, since Xpra's XTest pointer drops `pointer-wheel`);
  a tap shows the keyboard when the app answers it with a text cursor and hides
  it otherwise; dialogs are fitted and centred on the phone; hardware trackpad and mouse through `UIPointerInteraction` and
  `GCMouse`; the iOS keyboard (including dictation and autocorrect) through
  `UIKeyInput` (moving to `UITextInput` for marked text), sent as key events, with
  multi-scalar characters typed scalar by scalar; Apple Pencil as a tablet later.
- **Lifecycle.** The display socket closes when the app backgrounds; the computer
  parks on idle and resumes on the next foreground. The last frame of every
  window is cached so reopening is instant while the stream reconnects.

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

Agents are the coding and computer-use CLIs already installed in the computer — Claude
Code and Codex — signed in once with the owner's own accounts from Caboose's terminal.
The host holds no model keys. An agent works on its **own seat**, so it never moves the
owner's pointer or types into the owner's windows.

- **Agent seat.** `caboose-xpra-agent.service` runs a second Xpra seamless display `:101`
  (WebSocket `0.0.0.0:14501`, same token file and username as `:100`). GUI apps an agent
  starts appear there. The app shows them in an Agent space, view-only. **Take Over**
  stops the running agents (SIGSTOP to each task's process group) and gives the owner
  input; **Hand Back**, or leaving the window, continues them, so the owner and an agent
  never type into the same app at once. The seat's display starts only once an agent is in
  use.
- **Desktop tools.** `caboose-desktop-mcp` (stdio MCP server, in the image) gives an agent
  `screenshot`, `click`, `type`, `key`, `scroll`, `launch`, `list_windows` and `focus` on
  `:101`, so a CLI agent can drive GUI apps as well as the shell. Claude Code and Codex
  are configured to load it.
- **Tasks.** The host runs a task as a keep-alive desk job, as user `caboose`, in
  `/home/caboose/Agents/<task-id>/` (or a chosen directory), with `DISPLAY=:101`:
  `claude -p <prompt> --output-format stream-json` or `codex exec --json <prompt>`.
  Output is parsed into events; the raw transcript is kept in the task directory.

| Method | Path | Purpose |
| --- | --- | --- |
| `POST` | `/v1/agent/tasks` | `{ prompt, agent: "claude" \| "codex", cwd? }` → `{ id }` |
| `GET` | `/v1/agent/tasks` | recent tasks: `{ id, agent, prompt, status, startedAt, finishedAt, summary }` |
| `POST` | `/v1/agent/tasks/:id/cancel` | stop a running task |
| `POST` | `/v1/agent/tasks/:id/pause` | stop a running task in place for take-over (`status: "paused"`) |
| `POST` | `/v1/agent/tasks/:id/resume` | continue a paused task |
| `GET` | `/v1/display?seat=agent` | **WebSocket.** Relay to the agent seat's Xpra on `:101` |

Control-socket events: `agent.task.started { id, agent, prompt }`,
`agent.task.output { id, kind: "text" | "tool" | "error", text }`,
`agent.task.paused { id }`, `agent.task.resumed { id }`,
`agent.task.finished { id, status: "succeeded" | "failed" | "cancelled", summary }`.
A task that finds its CLI signed out fails with `status: "failed"` and a summary telling
the owner to sign in from Terminal. Tasks keep running while the phone is locked: the
computer is a server, and the host holds a lease while any task runs, so the computer is
not parked under a working agent. Each task directory records its agent, prompt, pid
and exit code, so a restarted host rebuilds the task list from the guest and re-takes the
lease for tasks still running.

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
