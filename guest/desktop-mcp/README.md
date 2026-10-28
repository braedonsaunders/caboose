# caboose-desktop-mcp

An MCP server (stdio, JSON-RPC 2.0) that lets a CLI agent — Claude Code or Codex — see and
drive GUI apps on the agent seat, display `:101`, without ever touching the owner's display.

Tools: `screenshot`, `list_windows`, `focus`, `click`, `drag`, `type`, `key`, `scroll`, `launch`.

- **Runtime:** Node (no packages) plus `xdotool`, `wmctrl` and ImageMagick's `import` in the
  guest. `CABOOSE_AGENT_DISPLAY` overrides the display (default `:101`).
- **Install:** `install.sh` (run by the image build as root) copies it to
  `/opt/caboose/desktop-mcp.mjs` and registers it for user `caboose` in `~/.claude.json`
  and `~/.codex/config.toml`. caboose-host allows its tools for Claude tasks with
  `--allowedTools mcp__caboose-desktop`.
- **Test:** `node selftest.mjs` checks the protocol and input validation without an X server.
