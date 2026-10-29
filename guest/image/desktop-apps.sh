#!/usr/bin/env bash
# Official Debian desktop packages; shared by both image builders.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
[[ $(id -u) == 0 ]] || { echo 'Run as root' >&2; exit 1; }
. /etc/os-release
[[ ${ID:-} == debian && ${VERSION_ID:-} == 13 ]] || { echo 'Requires Debian 13' >&2; exit 1; }
arch=$(dpkg --print-architecture)
case $arch in amd64|arm64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; esac
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
apt-get update
# Include desktop credentials and Claude Code runtime helpers, but not Cowork's
# recommended nested VM stack. Preserve the vendors' sandbox and maintainer scripts.
apt-get install -y --no-install-recommends ca-certificates curl \
  libasound2t64 libayatana-appindicator3-1 gnome-keyring bubblewrap socat openssh-client
while IFS=$'\t' read -r package version target sha url; do
  [[ $package != \#* && -n $package && $target == "$arch" ]] || continue
  installed=$(dpkg-query -W -f='${Status} ${Version} ${Architecture}' "$package" 2>/dev/null || true)
  [[ $installed != "install ok installed $version $arch" ]] || continue
  deb="$work/${package}_${version}_${arch}.deb"
  curl -fsSL --retry 3 "$url" -o "$deb"
  printf '%s  %s\n' "$sha" "$deb" | sha256sum -c -
  [[ $(dpkg-deb -f "$deb" Package) == "$package" && \
     $(dpkg-deb -f "$deb" Version) == "$version" && \
     $(dpkg-deb -f "$deb" Architecture) == "$arch" ]] || { echo "Unexpected package metadata: $package" >&2; exit 1; }
  apt-get install -y --no-install-recommends "$deb"
done < "$here/desktop-apps.tsv"
