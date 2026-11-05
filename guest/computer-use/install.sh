#!/bin/sh
# Build the computer-use packages from this directory (package.py) and install them with APT,
# which brings in their declared dependencies. guest/components/install.sh runs it in every
# mode: in an image build, and on a computer at each component update. Run as root.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
export DEBIAN_FRONTEND=noninteractive
out=$(mktemp -d /tmp/caboose-computer-use.XXXXXXXX)
log=$out/apt.log
trap 'rm -rf "$out"' EXIT
# The Wine reader is cross-built only by the image builds, beside its source (so it is no
# file of the host's bundle). A computer that has the one Caboose installed by hand before this
# package keeps it, as the Wine package.
reader=$here/wine/caboose-msaa.exe
if [ ! -f "$reader" ] && [ -f /opt/caboose/caboose-msaa.exe ]; then
  export CABOOSE_MSAA=/opt/caboose/caboose-msaa.exe
fi
python3 "$here/package.py" "$out" >/dev/null

# Files Caboose installed by hand before it shipped this package: the package owns their
# successors, and the configuration it now owns would otherwise be seen as the owner's.
rm -f /opt/caboose/desktop-mcp.mjs /opt/caboose/worker.mjs /opt/caboose/observation.mjs \
  /opt/caboose/ensure-agent-seat.mjs /opt/caboose/seat.py /opt/caboose/launcher.py \
  /opt/caboose/direct.py /opt/caboose/annotate.py \
  /opt/caboose/specialist.mjs /opt/caboose/choices.mjs /usr/local/libexec/caboose-agent-seat
rm -rf /opt/caboose/desktop-mcp /opt/caboose/webmcp /usr/local/libexec/caboose-agent-seat-bin
for file in /opt/caboose/a11y.py /opt/caboose/agent-profile.py /opt/caboose/caboose-targets.py \
  /etc/chromium.d/zz-caboose-agent /etc/chromium/native-messaging-hosts/com.caboose.webmcp.json; do
  if [ -e "$file" ] && ! dpkg -S "$file" >/dev/null 2>&1; then rm -f "$file"; fi
done
rm -f /etc/chromium.d/caboose-accessibility

# Contents decide the version (package.py), so a rebuilt package can sort below the one
# installed; it is installed all the same. APT's lists are fetched only when a dependency is
# missing from them.
apt_install() {
  apt-get install -y -q --allow-downgrades --no-install-recommends -o Dpkg::Options::=--force-confnew "$out"/*.deb >"$log" 2>&1
}
if ! apt_install; then
  if ! apt-get update -q >>"$log" 2>&1 || ! apt_install; then
    tail -n 60 "$log" >&2
    exit 1
  fi
fi
rm -f /opt/caboose/caboose-msaa.exe
