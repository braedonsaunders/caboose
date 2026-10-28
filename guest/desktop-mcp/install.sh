#!/bin/sh
# Install caboose-desktop-mcp into the guest image and register it with the agent CLIs
# for user caboose. Run inside the image build (as root), after Node and the CLIs.
set -eu
install -d -m 0755 /opt/caboose
install -m 0755 "$(dirname "$0")/caboose-desktop-mcp.mjs" /opt/caboose/desktop-mcp.mjs
home=/home/caboose
# Claude Code reads user-scope MCP servers from ~/.claude.json.
python3 - "$home/.claude.json" <<'PY'
import json, os, sys
path = sys.argv[1]
data = json.load(open(path)) if os.path.exists(path) else {}
data.setdefault("mcpServers", {})["caboose-desktop"] = {
    "type": "stdio", "command": "node", "args": ["/opt/caboose/desktop-mcp.mjs"], "env": {"CABOOSE_AGENT_DISPLAY": ":101"},
}
json.dump(data, open(path, "w"), indent=2)
PY
# Codex reads MCP servers from ~/.codex/config.toml.
install -d -m 0700 "$home/.codex"
if ! grep -qs '^\[mcp_servers.caboose-desktop\]' "$home/.codex/config.toml"; then
    cat >> "$home/.codex/config.toml" <<'TOML'

[mcp_servers.caboose-desktop]
command = "node"
args = ["/opt/caboose/desktop-mcp.mjs"]
env = { CABOOSE_AGENT_DISPLAY = ":101" }
TOML
fi
chown -R 1000:1000 "$home/.claude.json" "$home/.codex"
