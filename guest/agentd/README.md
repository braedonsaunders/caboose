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
| `run <task dir>` | One task. Started detached (`setsid`) by the host as `caboose` with `DISPLAY=:101` and the agent seat D-Bus session at `/run/user/1000/agent-bus`. |
| `install <spec>` | Prefetches the agent, starts it once to learn its sign-in methods, records it as installed. Prints `{ installed: { version }, signIn: [...] }`. |
| `probe <spec>` | `initialize` only; records and prints the sign-in methods. |
| `sign-in <spec>` | Runs one sign-in method on the owner's display (see below). |
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

- `task.json` — `{ agent: <spec>, cwd, approvals: "ask" | "auto", idleMs, craftServers }`.
- `inbox/<turn, 6 digits>.prompt.json` — `{ type: "prompt", turn, text, attachments?: [{ path, name, mimeType? }] }`.
- `inbox/cancel-<n>.json` — `{ type: "cancel" }`.
- `approvals/<requestId>.decision` — `{ allow, message?, optionId? }`.

The runner writes:

- `transcript.jsonl` — one event per line, the same for every agent (below).
- `approvals/<requestId>.json` — a permission request, `{ tool, kind, summary, input, options: [{ id, name, kind }], toolCallId, requestedAt }`; `requestId` is a UUID.
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
| `turn_failed` | `turn`, `message` |
| `auth_required` | `turn`, `message`, `authMethods: [{ id, name, description?, type: "agent" \| "terminal" }]` |

Every turn ends with exactly one of `turn_end`, `turn_failed` or `auth_required` carrying its
turn number. Updates outside a turn (including the history an agent replays on
`session/load`) are not written.

## Behaviour

- **Initialize** advertises `fs.readTextFile` and `fs.writeTextFile` (paths are resolved,
  symlinks included, and refused outside the home directory), `terminal: false`, and
  `auth.terminal: true`. The `authMethods` it returns are kept in
  `~/.local/share/caboose/agents/<id>/auth.json`.
- **Session.** `session/new` with the task directory as `cwd` and one MCP server,
  `caboose-desktop` (`node /opt/caboose/desktop-mcp.mjs`, `CABOOSE_AGENT_DISPLAY` set to the
  runner's display), so every agent can drive GUI apps on the agent seat. The host also
  snapshots installed catalog MCP commands into `task.json` and the runner passes them to
  new, load and resume requests. `craftMcp: false` on task creation disables them for that
  task, including replies. See the Agents section of the architecture for the app list.
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
- **A later runner** reopens the session from `session`: `session/resume` when the agent
  advertises `sessionCapabilities.resume`, else `session/load` when it advertises
  `loadSession` (the replay is not written again), else `session/new` with a recap of the
  earlier turns from the transcript at the start of the first prompt; that turn's summary
  says so.
- **Signed out.** An `auth_required` error (ACP code -32000) from `session/new`, `load`,
  `resume` or `prompt` ends the turn with an `auth_required` event and the runner exits.
- **Sign-in** (`sign-in` mode, spec `{ agent, methodId, env? }`): progress in
  `~/.local/share/caboose/agents/<id>/sign-in.json` `{ methodId, status: "running" |
  "succeeded" | "failed", message?, startedAt, finishedAt? }`. An `agent` method is ACP
  `authenticate`, with the agent started with `env`, the owner display's launch environment
  from the host (`{ DISPLAY: ":100" }` under Xpra, the default; `WAYLAND_DISPLAY`, Xwayland's
  `DISPLAY` and toolkit hints under Caboose Display), so the browser it opens is on the
  owner's screen; it waits up to 30 minutes. A `terminal` method opens
  `xfce4-terminal` (else `x-terminal-emulator`) on that display running the agent's own
  program with the method's `args` in place of the registry's, and its `env` over the
  registry's; exit status 0 is success, after which the runner initializes the agent again.

## Install

`install.sh` (run as root by both image builds) copies the runner to `/opt/caboose/agentd`,
checks the registry integrity of the pinned SDK and `zod`, and installs them there with npm.
The image also gets `uv`/`uvx` (pinned, checksum-verified, in `guest/image/apps.sh`) and
`bzip2` for `.tar.bz2` agents. A computer made from an older image gets the runner by
running `guest/agentd/install.sh` as root inside it.

## Test

```sh
pnpm --filter caboose-agentd test
```

runs the real runner against `test/stand-in-agent.mjs`, a stand-in ACP agent written with the
SDK's agent side: streaming, tool calls, plans, permissions (ask and auto, named options),
cancel (including an agent that ignores it), replies on the same session, `session/resume`,
`session/load` and the recap fallback, `auth_required`, both sign-in kinds, npx prefetch,
a binary download with its checksum, the home-only file system, attachments and the owner's
environment file. `apps/host/scripts/check-agent-shell.sh` runs it again in a Debian 13
container through caboose-host's own guest scripts.
