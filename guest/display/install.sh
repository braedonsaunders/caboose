#!/bin/sh
# Installs caboose-display into a Debian 13 guest (or chroot): the runtime libraries,
# the binaries built by `cargo build --release`, the systemd units for the owner's
# display and the agent seat, and the readiness check. The units are not enabled: the
# host starts the owner's display at each wake and the agent seat when an agent needs it.
#
#   guest/display/install.sh [TARGET_DIR]     # default: guest/display/target/release
set -eu
here=$(cd "$(dirname "$0")" && pwd)
bin=${1:-$here/target/release}
[ "$(id -u)" = 0 ] || { echo 'Run as root' >&2; exit 1; }
for b in caboose-display caboose-display-probe; do
  [ -x "$bin/$b" ] || { echo "missing $bin/$b (build with cargo build --release)" >&2; exit 1; }
done
export DEBIAN_FRONTEND=noninteractive
apt-get install -y --no-install-recommends xwayland libegl1 libgl1-mesa-dri libpixman-1-0 libxkbcommon0 \
  libavcodec61 libavutil59 libavformat61 libswscale8 python3-gi dbus-user-session
install -m 0755 "$bin/caboose-display" "$bin/caboose-display-probe" /usr/local/bin/
install -m 0755 "$here/caboose-display-ready" /usr/local/bin/
install -m 0644 "$here/systemd/caboose-display.service" "$here/systemd/caboose-display-agent.service" /etc/systemd/system/
# Each display's D-Bus notification endpoint, on its seat's session bus.
sh "$here/../notifications/install.sh"
if id caboose >/dev/null 2>&1; then
  mkdir -p /var/lib/systemd/linger
  touch /var/lib/systemd/linger/caboose
fi
if [ -d /run/systemd/system ]; then systemctl daemon-reload; fi
