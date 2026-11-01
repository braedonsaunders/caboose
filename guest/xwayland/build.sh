#!/bin/sh
# Builds Debian's xwayland package with this directory's patches, into OUTPUT_DIRECTORY.
# usage: build.sh OUTPUT_DIRECTORY
# Needs deb-src entries for the release, xwayland's build dependencies and dpkg-dev
# (apt-get build-dep xwayland). XWAYLAND_JOBS sets the build's parallelism (default 2).
set -eu
[ "$#" -eq 1 ] || { echo "usage: $0 OUTPUT_DIRECTORY" >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$1"
out=$(cd "$1" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
apt-get source --download-only xwayland >/dev/null
dpkg-source -x xwayland_*.dsc source >/dev/null
cd source
for patch in "$here"/*.patch; do
    cp "$patch" debian/patches/
    basename "$patch" >> debian/patches/series
done
# A local version above Debian's, so the package manager keeps this build.
sed -i '1s/^xwayland (\([^)]*\))/xwayland (\1+caboose1)/' debian/changelog
DEB_BUILD_OPTIONS="nocheck parallel=${XWAYLAND_JOBS:-2}" dpkg-buildpackage -b -uc -us > ../build.log 2>&1 ||
    { tail -n 40 ../build.log >&2; exit 1; }
cp ../xwayland_*+caboose1_*.deb "$out/"
ls "$out"
