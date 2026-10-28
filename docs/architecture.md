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

On a WSL2 host that exposes its GPU through `/dev/dxg`, the host can instead run
the computer as a Debian container using `CABOOSE_RUNTIME=container`. Mesa's
D3D12 driver renders on the WSL GPU and Xpra can use NVENC; display ports,
authentication, application discovery and the two-seat protocol remain the
same. The home directory is a persistent host bind mount or volume. Parking
pauses the container in RAM, and waking unpauses it; a Docker or WSL restart
loses the process tree, but not the home directory. This volatile pause does
not claim the durable microVM snapshot semantics described below. The runtime
and its build and checks are documented in `guest/container/README.md`.

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
  audio, printing, webcam and cursor shapes. The owner seat forwards speaker audio
  via a PulseAudio monitor, with MP3 available for iOS; microphone forwarding is off.
  A Wayland compositor of our own can replace it later behind the same client model.
- **Session auth.** Xpra requires a per-boot token (`tcp-auth`/`ws-auth` via an
  `env`/file authenticator). The host writes it with `desk.exec` at wake and hands
  it to the client inside the authenticated `/v1/session` response.
- **Apps** installed in the image: Chromium, Firefox ESR, VS Code, xfce4-terminal,
  Thunar, Mousepad, LibreOffice, Obsidian, document, media and image tools; developer
  tools including Git, Neovim, Lazygit, Lazydocker, btop, mise and modern shell tools;
  and the Claude Code, Codex, OpenCode and Gemini CLI agents. Terminal tools and agents
  have desktop launchers. Fonts: Inter, JetBrains Mono and Noto (incl. CJK, emoji).
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

HTTP API (all JSON, all behind `Authorization: Bearer <device token>`):

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/v1/health` | host + KVM + desk host stats |
| `POST` | `/v1/session` | wake the user's computer (start or resume), ensure Xpra is up, return `{ state, display: { path, token, protocol: "xpra-ws" }, computer: { name, image, memoryMb, vcpus } }` |
| `GET` | `/v1/display` | **WebSocket.** Binary relay to the guest's Xpra WS. Subprotocol passthrough (`binary`). One relay per client connection |
| `GET` | `/v1/apps` | launchable apps from the guest's `.desktop` files: `{ id, name, icon (PNG data URL), categories, exec }` |
| `POST` | `/v1/apps/:id/launch` | start an app on display `:100` |
| `POST` | `/v1/session/park` | park now (snapshot with memory); otherwise parked on idle |
| `GET` | `/v1/control` | **WebSocket.** JSON events: `computer.state`, `notification`, `agent.*`, `media.*` |
| `GET` | `/v1/computer` | management status and persisted computer settings; does not wake or lease the computer |
| `PATCH` | `/v1/computer/settings` | update any of `name`, `memoryMb`, `vcpus`, `idleMs`; returns management status |
| `POST` | `/v1/computer/restart` | requires `{ "confirm": true }`; cold restart, preserving the disk and discarding memory; returns management status |
| `POST` | `/v1/files` | `{ name, data (base64), open? }` → `{ path }`: save a file into the computer's `~/Downloads` (see Agents › Files) |
| `POST` | `/v1/open` | `{ url }` → `{ opened: true }`: open an `http(s)` URL in the default browser on `:100` |

Management status has this shape (resources are MiB and idle time is milliseconds):

```ts
{
  state: "parked" | "waking" | "running" | "parking" | "restarting" | "error",
  settings: { name: string, memoryMb: number, vcpus: number, idleMs: number },
  limits: { memoryMb: { min: number, max: number }, vcpus: { min: number, max: number }, idleMs: { min: number, max: number } },
  activeResources: { memoryMb: number, vcpus: number } | null,
  restartRequired: boolean,
  clients: { display: number, control: number },
  tasks: { running: number, paused: number },
  capabilities: { restart: boolean },
  lastError: string | null
}
```

The name is 1–80 characters without control characters, trimmed on save. Memory is
512–65536 MiB, vCPUs 1–32, and idle time 60000–86400000 ms; numeric values are integers.
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
  scalar; Apple Pencil as a tablet later.
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
  are configured to load it. It also carries `approve`, the permission-prompt tool behind
  **Ask before acting** (below).
- **Tasks.** The host starts a task detached (`setsid`), as user `caboose`, in
  `/home/caboose/Agents/<task-id>/`, with `DISPLAY=:101` and `CABOOSE_TASK_DIR` set to that
  directory: `claude -p <prompt> --output-format stream-json --verbose` or
  `codex exec --json --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox <prompt>`.
  Without approvals Claude runs with `--permission-mode acceptEdits` and the shell, file,
  web and desktop tools pre-allowed; Codex runs without its own sandbox, since the computer is one.
  Output is parsed into events; the raw JSONL transcript is kept in the task directory.
- **Replies.** A finished task (succeeded, failed or cancelled) can be continued with a new
  prompt. The host records the conversation id from the transcript — Claude's
  `system`/`init` `session_id`, Codex's `thread.started` `thread_id` — in the task's
  `session` file and runs `claude -p <prompt> --resume <session_id> …` or
  `codex exec resume --json --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox <thread_id> <prompt>`.
  Each turn appends to the same `transcript.jsonl`; the task keeps its id, `prompt` (the
  first one) and `startedAt`, goes back to `running`, and `turns` counts the turns. A task
  that never reported a conversation id (for example, cancelled before the CLI started)
  cannot be continued.
- **Ask before acting** (`approvals: "ask"`, Claude Code only; `codex exec` cannot ask, so
  Codex rejects it). Claude runs with `--permission-prompt-tool mcp__caboose-desktop__approve`
  and no pre-allowed tools, so every tool use that needs permission asks. The `approve`
  tool writes `<taskdir>/approvals/<requestId>.json` `{ tool, input, requestedAt }` (long
  input strings cut for display) and waits — with no time limit; the task's lease keeps
  the computer awake — for `<taskdir>/approvals/<requestId>.decision` `{ allow, message? }`,
  then answers Claude with `{ "behavior": "allow", "updatedInput": <input> }` or
  `{ "behavior": "deny", "message": … }`. Both files are written whole and renamed into
  place. The host's poll reports requests without a decision; answering writes the decision
  file as `caboose`. Request ids are UUIDs minted by the tool and validated before use.
- **Attachments.** Up to 4 files, at most 10 MB decoded together, are written to
  `<taskdir>/attachments/<name>` (the last path component without control characters or
  leading dots, at most 120 characters, made unique as `name (2).ext`). The prompt given to
  the CLI ends with `\n\nAttached files:\n- <absolute path>` per file, so the agent reads them
  (Claude Code reads PNG and JPEG natively); the task's `prompt` stays as the owner wrote it.
- **Polling.** While any task is live the host runs one guest command per second for all
  of them: new transcript bytes from each task's byte offset (1 MiB per tick shared between
  tasks, read as base64 so offsets stay exact), the exit code, and pending approval
  requests. A tick with no live task does nothing.

| Method | Path | Purpose |
| --- | --- | --- |
| `POST` | `/v1/agent/tasks` | `{ prompt, agent?: "claude" \| "codex", approvals?: "ask" \| "auto", attachments?: [{ name, type, data (base64) }] }` → `{ id }` |
| `GET` | `/v1/agent/tasks` | recent tasks, newest first (task record below) |
| `POST` | `/v1/agent/tasks/:id/reply` | `{ prompt }` → `{ task }`; continue a finished task's conversation. 409 while the task is running or paused, or when it has no conversation to continue; 404 for an unknown task |
| `POST` | `/v1/agent/tasks/:id/approvals/:requestId` | `{ allow: boolean, message?: string }` → `{ resolved }`; `resolved: false` when that request is no longer waiting |
| `POST` | `/v1/agent/tasks/:id/cancel` | stop a running task |
| `POST` | `/v1/agent/tasks/:id/pause` | stop a running task in place for take-over (`status: "paused"`) |
| `POST` | `/v1/agent/tasks/:id/resume` | continue a paused task |
| `GET` | `/v1/display?seat=agent` | **WebSocket.** Relay to the agent seat's Xpra on `:101` |

A task record:

```ts
{
  id: string,
  agent: "claude" | "codex",
  prompt: string,                 // the first prompt, as written
  status: "running" | "paused" | "succeeded" | "failed" | "cancelled",
  startedAt: string,              // ISO 8601
  finishedAt?: string,            // absent while running
  summary?: string,               // the last turn's result; absent while running
  turns: number,                  // 1, plus one per reply
  approvals: "ask" | "auto",
  pendingApproval?: { id: string, tool: string, summary: string },  // oldest request waiting
  attachments?: string[]          // absolute guest paths
}
```

Prompts are 1–32000 characters after trimming. `message` is at most 2000 characters and
is shown to Claude when a request is denied. Agent requests answer 400 for invalid input
and 409 while the computer is not running.

Control-socket events: `agent.task.started { id, agent, prompt }`,
`agent.task.output { id, kind: "text" | "tool" | "error", text }`,
`agent.task.paused { id }`, `agent.task.resumed { id }`,
`agent.task.finished { id, status: "succeeded" | "failed" | "cancelled", summary }`,
`agent.task.replied { id, prompt, turn }`,
`agent.task.approval { id, request: { id, tool, summary } }` (once per request),
`agent.task.approval.resolved { id, requestId, allow }`.
A task that finds its CLI signed out fails with `status: "failed"` and a summary telling
the owner to sign in from Terminal. Tasks keep running while the phone is locked: the
computer is a server, and the host holds a lease while any task runs, so the computer is
not parked under a working agent. Each task directory records its agent, prompt, approval
mode, turn count, conversation id, pid and exit code, so a restarted host rebuilds the
task list from the guest, re-takes the lease for tasks still running, and can still reply.

### Files

`POST /v1/files` saves `{ name, data }` (at most 50 MB decoded) into
`/home/caboose/Downloads/`, owned by `caboose`. The name is sanitised as for attachments
and made unique (`report (2).pdf`); the response is the absolute path. `open: true` then
opens it with the desktop's default application on the owner's display `:100`
(`xdg-open`, else `gio open`). `POST /v1/open` opens an `http`/`https` URL the same way;
other schemes, control characters and spaces are rejected with 400. Both answer 409 while
the computer is not running. The guest command channel carries arguments, not stdin, so
file contents travel base64-encoded in chunks of at most 96 KiB per argument and 768 KiB
per command and are decoded in the guest; no driver needs more than `run(command, args)`.

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
