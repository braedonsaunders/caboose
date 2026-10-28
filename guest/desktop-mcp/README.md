# caboose-desktop-mcp

An MCP server (stdio, JSON-RPC 2.0) that lets a CLI agent — Claude Code or Codex — see and
drive GUI apps on the agent seat, display `:101`, without ever touching the owner's display.

Tools: `screenshot`, `list_windows`, `focus`, `click`, `drag`, `type`, `key`, `scroll`, `launch`,
and `approve`.

`approve` is Claude Code's `--permission-prompt-tool` for tasks started with
`approvals: "ask"` (caboose-host passes `--permission-prompt-tool mcp__caboose-desktop__approve`).
Called with `{ tool_name, input }`, it writes `approvals/<uuid>.json` `{ tool, input, requestedAt }`
(long input strings cut to 2000 characters) under `$CABOOSE_TASK_DIR`, or the working
directory when that is unset, and waits without a time limit for `approvals/<uuid>.decision`
`{ allow, message? }`, which caboose-host writes when the owner answers. It then returns
`{"behavior":"allow","updatedInput":<input>}` or `{"behavior":"deny","message":…}` as text.
Both files are written to a temporary name and renamed, so neither side reads half a file.
Verified against Claude Code 2.1.310: allow runs the tool, deny returns the message to the
model as the tool's error, and the environment and working directory reach the server.

- **Runtime:** Node (no packages) plus `xdotool`, `wmctrl` and ImageMagick's `import` in the
  guest. `CABOOSE_AGENT_DISPLAY` overrides the display (default `:101`).
- **Install:** `install.sh` (run by the image build as root) copies it to
  `/opt/caboose/desktop-mcp.mjs` and registers it for user `caboose` in `~/.claude.json`
  and `~/.codex/config.toml`. caboose-host allows its tools for Claude tasks with
  `--allowedTools mcp__caboose-desktop`.
- **Test:** `node selftest.mjs` checks the protocol, input validation and both `approve`
  answers without an X server.
