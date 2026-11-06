#!/bin/sh
# Builds Debian trixie's Flatpak with the patches beside this script, inside a Debian trixie
# system as root (an image build's stage, or build.sh's container):
#
#   build-in-debian.sh OUTPUT-DIRECTORY
#
# Writes flatpak, libflatpak0 and gir1.2-flatpak-1.0 at version <Debian's>+caboose1.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${1:?usage: build-in-debian.sh OUTPUT-DIRECTORY}
version=1.16.6-1~deb13u3
export DEBIAN_FRONTEND=noninteractive
# HTTP: a base image has no CA certificates, and apt checks the archive signatures itself.
printf 'Types: deb deb-src\nURIs: http://deb.debian.org/debian\nSuites: trixie trixie-updates\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n\nTypes: deb deb-src\nURIs: http://security.debian.org/debian-security\nSuites: trixie-security\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n' \
  > /etc/apt/sources.list.d/debian.sources
apt-get update -q >/dev/null
apt-get install -y -q --no-install-recommends build-essential devscripts dpkg-dev quilt >/dev/null
work=$(mktemp -d)
cd "$work"
apt-get source -q "flatpak=$version" >/dev/null
cd flatpak-1.16.6
apt-get build-dep -y -q . >/dev/null
for patch in "$here"/*.patch; do
  cp "$patch" "debian/patches/caboose-$(basename "$patch")"
  echo "caboose-$(basename "$patch")" >> debian/patches/series
done
QUILT_PATCHES=debian/patches quilt push -a -q >/dev/null
DEBFULLNAME=Caboose DEBEMAIL=caboose@localhost dch -v "$version+caboose1" -D trixie \
  "Retry openat2 on EAGAIN when chasing paths (libglnx eef7f14c), so a concurrent mount does not fail an extension's merge-dirs."
# The architecture's packages only: libflatpak-doc is not installed on computers.
if ! DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)" dpkg-buildpackage -B -uc -us > "$work/build.log" 2>&1; then
  tail -60 "$work/build.log" >&2
  exit 1
fi
mkdir -p "$out"
cp "$work"/flatpak_*+caboose1_*.deb "$work"/libflatpak0_*+caboose1_*.deb "$work"/gir1.2-flatpak-1.0_*+caboose1_*.deb "$out/"
rm -rf "$work"
