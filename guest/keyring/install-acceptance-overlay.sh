#!/bin/sh
# Test-only narrow overlay. Run in a fresh, capped container from a verified base image.
# The source is an immutable checkout export plus its newly compiled display binaries.
set -eu
[ "${CABOOSE_ACCEPTANCE_OVERLAY:-}" = 1 ] && [ -f /.dockerenv ] && [ "$(id -u)" = 0 ] || exit 2
src=${1:?expected mounted source export}
for command in chromium gnome-keyring-daemon dbus-daemon runuser sudo; do
  command -v "$command" >/dev/null || { echo "Missing acceptance dependency: $command" >&2; exit 1; }
done
python3 -c 'from gi.repository import Gio, GLib; import websockets'
[ -x /usr/lib/chromium/chrome-sandbox ] || { echo 'Chromium sandbox helper is missing' >&2; exit 1; }
for program in caboose-display caboose-display-probe; do
  dependencies=$(ldd "$src/out/$program")
  if printf '%s\n' "$dependencies" | grep -q 'not found'; then
    printf '%s\n' "$dependencies" >&2
    exit 1
  fi
  install -Dm755 "$src/out/$program" "/usr/local/bin/$program"
done
install -Dm755 "$src/guest/display/caboose-display-ready" /usr/local/bin/caboose-display-ready
install -Dm755 "$src/guest/container/caboose-session" /usr/local/bin/caboose-session
for name in agent-profile.py a11y.py seat.py; do
  install -Dm755 "$src/guest/desktop-mcp/$name" "/opt/caboose/$name"
done
install -Dm755 "$src/guest/desktop-mcp/caboose-agent-seat" /usr/local/libexec/caboose-agent-seat
install -Dm755 "$src/guest/desktop-mcp/caboose-desktop-mcp.mjs" /opt/caboose/desktop-mcp.mjs
install -Dm644 "$src/guest/desktop-mcp/ensure-agent-seat.mjs" /opt/caboose/ensure-agent-seat.mjs
install -Dm644 "$src/guest/desktop-mcp/ensure-agent-seat.mjs" /opt/caboose/desktop-mcp/ensure-agent-seat.mjs
install -Dm755 "$src/guest/apps/apps-mcp.mjs" /opt/caboose/apps/apps-mcp.mjs
install -d -m755 /usr/local/libexec/caboose-agent-seat-bin
for app in chromium google-chrome google-chrome-stable firefox firefox-esr code; do
  ln -sf /opt/caboose/agent-profile.py "/usr/local/libexec/caboose-agent-seat-bin/$app"
done
sh "$src/guest/keyring/install.sh"
install -Dm644 "$src/guest/notifications/caboose-agent-bus.service" /etc/systemd/system/caboose-agent-bus.service
install -Dm644 "$src/guest/display/systemd/caboose-display-agent.service" /etc/systemd/system/caboose-display-agent.service
# No apt/npm, service starts, owner-home writes, or components.version stamp.
printf '%s\n' 'Acceptance overlay installed; full component upgrade is not claimed'
