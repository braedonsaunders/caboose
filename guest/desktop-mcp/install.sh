#!/bin/sh
# Install caboose-desktop-mcp and its accessibility helper into the guest, switch on the
# accessibility trees of the apps it reads, and register it with the agent CLIs for user
# caboose. Run inside the image build (as root), after Node, the apps and the CLIs.
set -eu
here=$(dirname "$0")
install -d -m 0755 /opt/caboose
install -m 0755 "$here/caboose-desktop-mcp.mjs" /opt/caboose/desktop-mcp.mjs
install -m 0755 "$here/a11y.py" /opt/caboose/a11y.py
# Chromium joins the accessibility bus and builds page trees only when asked.
install -d -m 0755 /etc/chromium.d
install -m 0644 "$here/chromium-accessibility" /etc/chromium.d/caboose-accessibility
# The desktop-wide switch toolkits consult (org.a11y.Status IsEnabled follows it): Firefox,
# Qt and Chromium-based apps launched without Caboose's environment still expose a tree.
if [ -f /usr/share/glib-2.0/schemas/org.gnome.desktop.interface.gschema.xml ]; then
    printf '[org.gnome.desktop.interface]\ntoolkit-accessibility=true\n' \
        > /usr/share/glib-2.0/schemas/90_caboose-accessibility.gschema.override
    glib-compile-schemas /usr/share/glib-2.0/schemas
fi
home=/home/caboose
# Directories under the home are created owned by caboose (uid 1000), never by root.
userdir() { for dir in "$@"; do [ -d "$dir" ] || install -d -o 1000 -g 1000 -m 0700 "$dir"; done; }
userdir "$home/.vscode" "$home/.codex"
python3 - "$home" <<'PY'
import json, os, re, sys
home = sys.argv[1]
server = {"command": "node", "args": ["/opt/caboose/desktop-mcp.mjs"], "env": {"CABOOSE_AGENT_DISPLAY": ":101"}}

def merge(path, update):
    """Add Caboose's entry to a JSON config, keeping everything else in it."""
    data = {}
    if os.path.exists(path):
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        if text.strip():
            data = json.loads(text)
    update(data)
    with open(path + ".tmp", "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")
    os.replace(path + ".tmp", path)

# Claude Code reads user-scope MCP servers from ~/.claude.json.
merge(f"{home}/.claude.json", lambda data: data.setdefault("mcpServers", {}).update(
    {"caboose-desktop": {"type": "stdio", **server}}))

# VS Code (Electron) builds its renderer's accessibility tree with this switch. argv.json
# is JSON with comments, so the key is inserted, not parsed and rewritten.
path = f"{home}/.vscode/argv.json"
note = "\t// Caboose: expose the editor's accessibility tree to agents and the phone.\n"
if not os.path.exists(path):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("{\n" + note + '\t"force-renderer-accessibility": true\n}\n')
else:
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    if '"force-renderer-accessibility"' not in text and "{" in text:
        start = text.index("{") + 1
        comma = "," if '"' in text[start:] else ""
        text = text[:start] + "\n" + note + '\t"force-renderer-accessibility": true' + comma + text[start:]
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)
PY
# Codex reads MCP servers from ~/.codex/config.toml.
if ! grep -qs '^\[mcp_servers.caboose-desktop\]' "$home/.codex/config.toml"; then
    cat >> "$home/.codex/config.toml" <<'TOML'

[mcp_servers.caboose-desktop]
command = "node"
args = ["/opt/caboose/desktop-mcp.mjs"]
env = { CABOOSE_AGENT_DISPLAY = ":101" }
TOML
fi
chown -R 1000:1000 "$home/.claude.json" "$home/.codex" "$home/.vscode"
