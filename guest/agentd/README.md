# caboose-agentd

The agent runner inside a Caboose computer. caboose-host runs any agent from the
[Agent Client Protocol (ACP) registry](https://agentclientprotocol.com/get-started/registry)
through it: this process is the ACP client, the agent is an ACP agent on its stdio, and the
host talks to the runner only through files, because the host's guest channel carries
command arguments, not stdin. Nothing in it knows any particular agent.

It is one file, `caboose-agentd.mjs`, on Node 22 with the official TypeScript SDK
(`@agentclientprotocol/sdk`, pinned with its `zod` in `package.json`).

## Modes

| Command | What it does |
| --- | --- |
| `run <task dir>` | One task. Started detached (`setsid`) by the host as `caboose` with the agent seat's launch environment (`/run/caboose/agent-display.env`: its `WAYLAND_DISPLAY`, Xwayland `DISPLAY=:101` and `XAUTHORITY`, toolkit backends and control socket) and the seat's D-Bus session bus `/run/user/1000/agent-bus`. |
| `install <spec>` | Prefetches the agent, starts it once to learn its sign-in methods, records it as installed. Prints `{ installed: { version }, signIn: [...] }`. |
| `probe <spec>` | `initialize` only; records and prints the sign-in methods. |
| `sign-in <spec>` | Runs one sign-in method, on the phone or the owner's display (see below). |
| `sign-in-callback <id> <attempt> <url>` | Delivers the loopback address sign-in `attempt` on the phone was sent back to. Prints `{ status }`. |
| `sign-in-cancel <id> <attempt>` | Stops the agent's running sign-in if it is `attempt`. Prints `{ cancelled }`. |
| `state` | Prints `{ runner, agents: { <id>: { installed?, authMethods?, signInStatus?, env? } } }`; `env` lists the variable names the agent's environment file sets, never their values. |
| `set-env <id> <json>` | Applies `{ set?: { NAME: value }, remove?: [NAME] }` to `~/.config/caboose/agents/<id>.env`, keeping its other lines and comments, writing values in double quotes (one line each, at most 8192 characters), mode 0600, through a temporary file and a rename. Prints `{ env: [names] }`. |

`<spec>` is base64 JSON. An agent spec is what the host resolved from the registry for
`linux-x86_64`:

```ts
{ id, name, version, distribution: "npx" | "uvx" | "binary",
  package?,               // npx, uvx: the registry's package, version included
  archive?, sha256?, cmd?, // binary: the archive URL, its SHA-256, the command inside it
  args: string[], env: Record<string, string> }
```

The agent starts as `npx -y <package> <args>`, `uvx <package> <args>`, or, for a binary,
`<cmd>` inside `~/.local/share/caboose/agents/<id>/<version>/` (downloaded once, checked
against `sha256` when the registry gives one, else only over HTTPS, then unpacked from
`.zip`, `.tar.gz`/`.tgz`, `.tar.bz2`/`.tbz2`, `.tar.xz` or used as a raw executable).
`install` warms the same cache a task uses: `npm exec --yes --package=<package>` for npx,
`uvx --from <package> python -c ''` for uvx, the download for a binary.

The agent's environment is the runner's, then the registry's `env`, then the owner's file
`~/.config/caboose/agents/<id>.env` when it exists: `KEY=VALUE` lines, `#` comments and blank
lines, no shell expansion, one pair of matching quotes around a value removed. The file must
belong to `caboose` and be closed to group and others (mode 0600), or it is ignored with a
note on stderr. Values are never written to the transcript or logs.

## The task directory

The host writes these, each whole and renamed into place:

- `task.json` — `{ agent: <spec>, cwd, approvals: "ask" | "auto", idleMs, craftServers, mcpLibrary?, profileId? }`.
- `inbox/<turn, 6 digits>.prompt.json` — `{ type: "prompt", turn, deliveryId?, text, attachments?: [{ path, name, mimeType? }] }`.
- `delivery.json` — version 1 journal: `{ version: 1, turns?, original?, startAttachments?, queue, operations, intent?, cancelled? }`.
  `turns` is the monotonic allocated turn count, independent of the launch script's `turns`
  file. `original` is the initial request's SHA-256 fingerprint; `queue` is the ordered list of
  `{ id, hash, prompt, attachments: [{ path, name, mimeType?, bytes }] }`, and `operations`
  retains `{ id, hash, turn? }` for each admitted reply, including replies explicitly dropped
  by Cancel. An intent is `{ id: <delivery UUID>, turn, replies: <operation ids>, claimed?, uncertain?, legacy? }`.
  `legacy` fences the current turn of a runner loaded before receipts, without creating an
  inbox for that turn. `cancelled` records the explicitly cancelled turn. The journal is
  bounded to 1 MiB, 2048 operations and ten waiting replies; strings, paths, numbers and attachment totals are
  validated before recovery. Writes fsync a temporary file, rename it and fsync the directory.
- `deliveries/<turn, 6 digits>.json` — the published prompt, retained for recovery. It is
  committed before inbox publication, which is also atomic and fsynced. Repeating publication
  never recreates a missing inbox. An intent without a publication marker is safe to publish;
  a marker without an inbox requires a receipt or transcript evidence. File payloads and task
  creation are staged before admission; new task directories are renamed into place before
  launching a runner.
- `inbox/cancel-<n>.json` — `{ type: "cancel" }`.
- `approvals/<requestId>.decision` — `{ allow, message?, optionId? }`.

The runner writes:

- `transcript.jsonl` — one event per line, the same for every agent (below).
- `approvals/<requestId>.json` — a permission request, `{ tool, kind, summary, input, options: [{ id, name, kind }], toolCallId, requestedAt }`; `requestId` is a UUID.
- `draft.json` — `{ turn, after, kind: "text" | "thought", text }`, the message still arriving.
  It is atomically replaced at most every 200 ms, carries the last 16000 characters, and
  is removed before the complete message enters the transcript. `after` is the transcript
  byte position before the message, so the host can reject stale or premature snapshots.
  This is transient output, not another transcript event.
- `receipts/<turn, 6 digits>.json` — `{ turn, deliveryId: <UUID or null>, state: "claimed" | "completed", result? }`.
  An exclusive, fsynced claim precedes inbox unlink and all ACP execution. An existing claim,
  including a partial claim file left by a crash, is never executed again. Completion atomically
  replaces the claim after the terminal transcript event is flushed and fsynced; `result` is
  that event. Prompts from older hosts without a delivery id use null.
- `session` — the ACP session id, for the next runner.
- `agent.log` — the agent's stderr (first 4 MiB).

The host's launch script records `pid` (the runner's process group) and `exit-code`.

### Transcript events

Every event has `type` and `at` (ISO time).

| `type` | Fields |
| --- | --- |
| `user` | `turn`, `text`, `attachments?` — a turn began |
| `session` | `sessionId`, `continuity: "new" \| "resume" \| "load" \| "recap"`, `agent` (`agentInfo`), `modes`, `configOptions` (`id`, `name`, `currentValue`) |
| `text`, `thought` | `text` — one agent message or thought, its chunks joined |
| `tool` | `id`, `title`, `kind`, `status`, `detail?` (a command, path or URL from the input) |
| `tool_update` | `id`, `title`, `kind`, `status` — only when status or title changes |
| `plan` | `entries: [{ content, status }]` |
| `mode` | `modeId` |
| `permission` | `requestId` (null when answered automatically), `tool`, `summary`, and `optionId`, `kind`, `auto` when automatic |
| `permission_resolved` | `requestId`, `outcome`, `allow`, `optionId?`, `kind?`, `message?` |
| `usage` | `used`, `size`, `cost?` — the turn's last usage report |
| `notice` | `text` |
| `turn_end` | `turn`, `stopReason` (ACP), `summary` (the turn's last message, at most 2000 characters) |
| `turn_failed` | `turn`, `message`, `uncertain?` (true when the agent process died during execution) |
| `auth_required` | `turn`, `message`, `authMethods: [{ id, name, description?, type: "agent" \| "terminal" }]` |

A completed turn ends with exactly one of `turn_end`, `turn_failed` or `auth_required`
carrying its turn number. An interrupted runner leaves a claim without a completed receipt;
its signal handler writes a notice instead of fabricating a terminal result. A runner stopped
after its turn's terminal event is durable, or while it waits for a prompt, interrupts nothing:
it writes no notice and claims no further prompt. Updates outside
a turn (including the history an agent replays on `session/load`) are not written.

## Behaviour

- **Initialize** advertises `fs.readTextFile` and `fs.writeTextFile` (paths are resolved,
  symlinks included, and refused outside the home directory), `terminal: false`, and
  `auth.terminal: true`. The `authMethods` it returns are kept in
  `~/.local/share/caboose/agents/<id>/auth.json`.
- **Session.** `session/new` with the configured task or persistent-profile workspace as `cwd` and the MCP server
  `caboose-desktop` (`node /opt/caboose/desktop-mcp.mjs`, see `guest/desktop-mcp`), so every
  agent can drive GUI apps on the agent seat. Its environment carries the seat's launch
  environment from the runner's: `CABOOSE_AGENT_DISPLAY` (the runner's `DISPLAY`),
  `WAYLAND_DISPLAY`, `CABOOSE_DISPLAY_CONTROL`, `XAUTHORITY`, `XDG_RUNTIME_DIR`,
  `DBUS_SESSION_BUS_ADDRESS`, `GDK_BACKEND`, `QT_QPA_PLATFORM`, `MOZ_ENABLE_WAYLAND`,
  `SDL_VIDEODRIVER`, `ELECTRON_OZONE_PLATFORM_HINT`, `GALLIUM_DRIVER`, `LIBVA_DRIVER_NAME`,
  `GST_VA_ALL_DRIVERS` and `CABOOSE_VIDEO_SOCKET`. When `/opt/caboose/apps/apps-mcp.mjs`
  exists (`CABOOSE_APPS_MCP` overrides the path), `caboose-apps` (see `guest/apps`) follows
  with the same environment, for making agent apps. The host also snapshots installed catalog MCP commands into
  `task.json` and the runner passes them, with `caboose-desktop`, to new, load and resume
  requests. `craftMcp: false` on task creation disables them for that
  task, including replies. A task started with `mcpLibrary: true` also gets `caboose-library`
  (`library-mcp.mjs`), the computer's MCP Library, while its descriptor
  (`~/.local/state/caboose/mcp-library.json`, `CABOOSE_MCP_LIBRARY` overrides) exists; without it
  the transcript says so. See the Agents section of the architecture for the app list.
- **Prompt.** A text block, then each attachment as an `image` block when the agent's
  `promptCapabilities.image` is set and the file is a PNG, JPEG, GIF or WebP under 10 MB, and
  otherwise a `resource_link` to its `file://` path.
- **Permissions.** With `approvals: "ask"` each `session/request_permission` becomes an
  approval file and waits, without a time limit, for its decision: the requested `optionId`,
  else the first `allow_once` (`allow_always`) for allow or `reject_once` (`reject_always`)
  for deny. ACP has no place for a denial message, so `message` is kept in the transcript
  only. With `"auto"` the runner picks `allow_once`, else `allow_always`.
- **Cancel.** `session/cancel`, every waiting permission request answered `cancelled` (and
  its decision file written `{ allow: false, cancelled: true }`), then the turn ends with
  `stopReason: "cancelled"`. An agent that has not stopped after 15 s is terminated; the
  next prompt starts it again.
- **Between turns** the runner keeps the agent and its session for `idleMs` waiting for the
  next prompt, then stops the agent and exits 0. It checks the inbox one last time before it
  decides to exit and never takes a prompt after that, so a prompt written in that moment is
  left for the next runner.
- **Recovery.** A missing inbox is never an acknowledgement. The host reconciles claims,
  completion receipts, transcript turn boundaries, the published prompt and runner liveness.
  Runners loaded before a component update have no receipts; their transcript still proves
  started or completed turns. An interrupted claimed or possibly delivered turn is explicitly
  uncertain and is not replayed, and later admitted replies remain durable. The task's
  published prompts retain the payload even if it stopped before writing its first user event.
- **A later runner** reopens the session from `session`: `session/resume` when the agent
  advertises `sessionCapabilities.resume`, else `session/load` when it advertises
  `loadSession` (the replay is not written again), else `session/new` with a recap of the
  earlier turns from the transcript at the start of the first prompt; that turn's summary
  says so.
- **Signed out.** An `auth_required` error (ACP code -32000) from `session/new`, `load`,
  `resume` or `prompt` ends the turn with an `auth_required` event and the runner exits.
- **Sign-in** (`sign-in` mode, spec `{ agent, methodId, on?: "phone" | "display", attempt?,
  env? }`, `on` defaulting to `"display"`, `attempt` a UUID the host chooses, else one is
  made up): progress in `~/.local/share/caboose/agents/<id>/sign-in.json` `{ methodId,
  status: "running" | "succeeded" | "failed", attempt, on, pid, url?, terminal?, message?,
  startedAt, finishedAt? }`. An `agent` method is ACP `authenticate`, waiting up to 30
  minutes. A `terminal` method runs the agent's own program with the method's `args` in
  place of the registry's, and its `env` over the registry's; exit status 0 is success, after
  which the runner initializes the agent again.
  - **Attempts and the lock.** Every read-then-write of `sign-in.json` (starting, which stops
    the running attempt first; each record of progress; cancelling; delivering a callback)
    holds `agents/<id>/sign-in.lock`, created exclusively with the holder's pid. A lock
    whose holder is gone, that stayed empty for 5 seconds, or that is older than two minutes
    is taken over, through `sign-in.lock.takeover` so only one process does it and only while
    the lock is unchanged. Progress is written only while `sign-in.json` still names this
    attempt and it is still running; a runner that finds otherwise (replaced, cancelled or
    finished) hangs up its terminal session, stops its agent, removes its own files and exits
    1. Each attempt's files (its page list, browser commands, scripts, exit and environment
    files) are in `agents/<id>/attempts/<attempt>/`, removed when it ends, so cleaning up
    never touches another attempt's. Stopping an attempt reads the recorded pid's command line
    (from `/proc`, else `ps`) and signals its process group only when it is the sign-in runner
    of that attempt: SIGTERM, then SIGKILL after three seconds; once that runner is gone, its
    attempt's directory is removed too. For tests,
    `CABOOSE_AGENTD_SIGN_IN_PAUSE_MS` makes every holder wait between reading the state and
    acting on it, so overlapping operations can be ordered exactly.
  - **On the display**, the agent starts with `env`, the owner display's launch environment
    from the host (its Wayland socket, Xwayland's `DISPLAY` and `XAUTHORITY`, toolkit
    hints), plus the owner's session bus, so the browser it opens is on the owner's screen;
    a `terminal` method opens `xfce4-terminal` (else `x-terminal-emulator`) there.
  - **On the phone**, the desktop's variables are removed and the attempt's `bin`
    (`xdg-open`, `x-www-browser`, `www-browser`, `sensible-browser`, `gnome-www-browser`,
    each appending the pages it is given to the attempt's `pages`) comes first on `PATH`, with
    `BROWSER` set to its `xdg-open`; the latest page is `url`. A `terminal` method runs in a
    session of the terminal service, started with its `/start` route and the token in
    `/run/caboose/display-token`, and the session id is `terminal`; its environment goes
    through a file of mode 0600 that the session reads and removes.
- **`sign-in-callback <id> <attempt> <url>`** fetches `url`, which must be `http://` on
  `localhost`, `127.0.0.1` or `[::1]` with a port, inside the computer (trying both loopback
  addresses for `localhost`), following up to five redirects that stay on the loopback,
  within 30 seconds, and prints `{ status }`. It holds the sign-in lock throughout and
  refuses unless `attempt` is the agent's running sign-in on the phone.
- **`sign-in-cancel <id> <attempt>`** stops the agent's running sign-in if it is `attempt`
  (its runner and terminal session), records it as failed with "Sign-in cancelled." and
  prints `{ cancelled: true }`; any other attempt is left running and it prints
  `{ cancelled: false }`.

## Install

`install.sh` (run as root by both image builds) copies the runner to `/opt/caboose/agentd`,
checks the registry integrity of the pinned SDK and `zod`, and installs them there with npm.
The image also gets `uv`/`uvx` (pinned, checksum-verified, in `guest/image/apps.sh`) and
`bzip2` for `.tar.bz2` agents. To install or update the runner on a running computer, run
`guest/agentd/install.sh` as root inside it; it checks the result with
`caboose-agentd --version`.

## Test

```sh
pnpm --filter caboose-agentd test
```

runs the real runner against `test/stand-in-agent.mjs`, a stand-in ACP agent written with the
SDK's agent side: streaming, tool calls, plans, permissions (ask and auto, named options),
cancel (including an agent that ignores it), replies on the same session, `session/resume`,
`session/load` and the recap fallback, `auth_required`, both sign-in kinds on the display and
on the phone (the page handed over, the callback delivered, a terminal session, and attempts:
overlapping starts, a cancel overlapping a newer start, a replaced runner's late report, a
stale callback, a lock left by a dead or hung holder, and never signalling a process that is
not the attempt's runner), npx prefetch,
a binary download with its checksum, the home-only file system, attachments and the owner's
environment file, durable claims, duplicate suppression and interrupted execution.
The host's focused recovery tests run with
`pnpm --filter caboose-host exec vitest run src/agents.test.ts src/agent-delivery.test.ts`;
they cover host restarts, ordered files, idempotent admission, delayed and failed writes,
publication crash points, old runners, uncertain claims and Send Now/poll races.
`apps/host/scripts/check-agent-shell.sh` runs it again in a Debian 13
container through caboose-host's own guest scripts.

The guest components installer also installs the runner on existing computers. Matching
pinned runtime dependencies are reused; both image builders retain their image install.
An already running task keeps its loaded script until its runner exits.

When `task.json` names a profile UUID, `profile-instructions.txt` contains its admitted
identity/instruction/memory snapshot (at most 400 KB). The runner supplies this as a separate
text block on every turn; user transcript entries retain only the actual owner prompt.
Missing or oversized profile context fails the runner instead of silently dropping identity.
The host keeps `profile-id` alongside the config to restore the task's identity after restart.
The runner reads `task.json` when it starts, so a configuration the host changes between
turns applies to the next runner, which reopens the same session with the new MCP servers.

Profile tasks configured by the host with its agent-tool journal advertise the
`caboose-agent-tools` stdio MCP server. It uses `tool-turn` and the bounded
`tool-mailbox` in the task directory to exchange UUID requests and responses with
the host. Stdio close cancels pending waits; a timeout reports that an operation may
have completed. The mailbox carries no owner or phone bearer token. All guest agent
processes share the `caboose` user; the host enforces profile scope independently.
See [agent routines](../../docs/agent-routines.md#agent-tools-and-durability).

### Model selection

`models <spec base64>` initializes the installed agent and opens a discovery session with
no MCP servers or prompt. It prints `{ models? }` from ACP session config options
(`category: model`, `type: select`, including grouped values), or the legacy `models`
field. The child process closes on success, failure, or the 60-second session timeout.
An agent without either advertisement returns `{}`.

`task.json.model` is the requested model id. Before each prompt, including after
new/load/resume, the runner reads `requested-model.json` if present and negotiates the
selection with `session/set_config_option` (or legacy `session/set_model`). Unadvertised
ids and unconfirmed config selections fail the turn before prompting. `models.json`
atomically records `{ requestedModel?, models? }`; `models` transcript events report the
same state. Config-option notifications update the recorded actual selection. Choices
and labels come from the agent, never from environment variables or a built-in list.

The schema comes from the pinned `@agentclientprotocol/sdk` dependency. The upstream
[session config contract](https://agentclientprotocol.com/protocol/v1/session-config-options)
defines grouped select values, the model category, setter responses and update notifications.
The [Codex ACP implementation](https://github.com/zed-industries/codex-acp/blob/main/src/codex_agent.rs)
returns this configuration from session creation/resume and implements the config setter.

The runner supplies Caboose presentation guidance with each prompt: downloadable guest-file
links, image previews, and complete self-contained `inline-html` widgets with responsive,
accessible controls. Widgets have no network or file access; data comes from the agent’s
computer tools. `window.Caboose.compose(message)` proposes a native follow-up for the owner
to review and send, and cannot execute a tool itself. When the owner asks for an app, or
for something they will come back to, the guidance points the agent to a Caboose app
(`guest/apps`) instead of a widget.
