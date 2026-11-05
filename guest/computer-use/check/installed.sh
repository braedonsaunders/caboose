#!/bin/sh
# Checks the installed computer-use packages in a freshly built image: every packaged file as
# shipped, the entry points, the runtime the helpers need, and the MCP server answering. The
# image builds run it after the component install; it needs no display. Run as root.
set -eu
fail() { echo "computer use: $*" >&2; exit 1; }
[ "$(dpkg-query -W -f='${db:Status-Status}' caboose-computer-use)" = installed ] || fail 'caboose-computer-use is not installed'
dpkg --verify caboose-computer-use || fail 'packaged files differ from the package'
if [ "$(dpkg --print-architecture)" = amd64 ]; then
  [ "$(dpkg-query -W -f='${db:Status-Status}' caboose-computer-use-wine)" = installed ] || fail 'caboose-computer-use-wine is not installed'
  [ -f /usr/lib/caboose/computer-use/wine/caboose-msaa.exe ] || fail 'the Wine reader is missing'
fi
for entry in /usr/bin/caboose-computer-use /usr/libexec/caboose/agent-seat /usr/libexec/caboose/agent-profile \
  /usr/libexec/caboose/a11y /usr/libexec/caboose/seat /usr/libexec/caboose/touch-targets; do
  [ -x "$entry" ] || fail "$entry is not executable"
done
for command in node tesseract convert xdotool xprop gdbus sudo; do
  command -v "$command" >/dev/null || fail "$command is missing"
done
python3 -c "import gi; gi.require_version('Atspi', '2.0'); gi.require_version('GdkPixbuf', '2.0'); from gi.repository import Atspi, GdkPixbuf, Gio" \
  || fail 'the helpers cannot load AT-SPI'
[ "$(GSETTINGS_BACKEND=memory gsettings get org.gnome.desktop.interface toolkit-accessibility)" = true ] \
  || fail 'toolkit accessibility is not on by default'
python3 - <<'PY' || fail 'the MCP server did not answer'
import json, subprocess
server = subprocess.Popen(['/usr/bin/caboose-computer-use'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
requests = [{'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-06-18', 'capabilities': {}}},
            {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}]
replies, _ = server.communicate(''.join(json.dumps(r) + '\n' for r in requests), timeout=30)
replies = [json.loads(line) for line in replies.splitlines()]
assert replies[0]['result']['serverInfo']['name'] == 'caboose-desktop', replies
assert [t['name'] for t in replies[1]['result']['tools']] == ['look', 'act', 'screenshot'], replies
PY
echo 'computer use: installed and answering'
