#!/bin/sh
# Installs caboose-display into a Debian 13 guest (or chroot): the runtime libraries,
# the binaries built by `cargo build --release`, the systemd unit and the readiness
# check. It does not enable the unit: Xpra stays the default display until the host
# chooses Caboose Display (CABOOSE_DISPLAY=caboose).
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
apt-get install -y --no-install-recommends xwayland libpixman-1-0 libxkbcommon0 \
  libavcodec61 libavutil59 libavformat61 libswscale8
install -m 0755 "$bin/caboose-display" "$bin/caboose-display-probe" /usr/local/bin/
install -m 0755 "$here/caboose-display-ready" /usr/local/bin/
install -m 0644 "$here/systemd/caboose-display.service" /etc/systemd/system/
if [ -d /run/systemd/system ]; then systemctl daemon-reload; fi
