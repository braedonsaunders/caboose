#!/usr/bin/env bash
# Builds the Caboose WSL distribution: a rootfs for `wsl --import`.
#
#   deploy/windows/distro/build.sh <caboose-host-linux-amd64.tar.zst> <outdir>
#
# The bundle comes from `apps/host/scripts/bundle.sh linux amd64 <dir>`. Writes
# <outdir>/caboose-wsl-amd64.tar.gz and <outdir>/caboose-wsl-amd64.tar.gz.sha256.
#
# CABOOSE_CONTAINER_IMAGE sets the computer image caboose-host.service runs (default
# ghcr.io/braedonsaunders/caboose-computer:latest); releases pin it by digest. Needs Docker
# that can build linux/amd64 images (natively, or with emulation).
set -euo pipefail

bundle=${1:?usage: build.sh <caboose-host-linux-amd64.tar.zst> <outdir>}
out=${2:?usage: build.sh <caboose-host-linux-amd64.tar.zst> <outdir>}
here=$(cd "$(dirname "$0")" && pwd -P)
image=${CABOOSE_CONTAINER_IMAGE:-ghcr.io/braedonsaunders/caboose-computer:latest}
name=caboose-wsl-amd64.tar.gz

[[ -f $bundle ]] || { echo "No bundle at $bundle" >&2; exit 1; }
mkdir -p "$out"
out=$(cd "$out" && pwd -P)

context=$(mktemp -d "${TMPDIR:-/tmp}/caboose-wsl.XXXXXX")
trap 'rm -rf "$context" "$out/$name.part"' EXIT

cp "$here/Dockerfile" "$context/Dockerfile"
cp -R "$here/rootfs" "$context/rootfs"
cp "$bundle" "$context/caboose-host.tar.zst"

# The image's filesystem straight from BuildKit, which is what `docker export` of a container
# made from it would hold, minus what creating a container adds (/.dockerenv and the empty
# /etc/hostname, /etc/hosts and /etc/resolv.conf mount points). WSL writes those itself.
echo "Building the distribution (computer image $image)"
docker build --platform linux/amd64 --pull --build-arg "CABOOSE_CONTAINER_IMAGE=$image" \
  --output type=tar,dest=- "$context" | gzip -6 >"$out/$name.part"
mv "$out/$name.part" "$out/$name"

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
printf '%s  %s\n' "$(sha256 "$out/$name")" "$name" >"$out/$name.sha256"
echo "$out/$name"
