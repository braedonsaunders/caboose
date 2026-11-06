#!/bin/sh
# Builds the computers' Flatpak packages (build-in-debian.sh) in a debian:trixie container on
# any Linux machine with Docker:
#
#   guest/flatpak/package/build.sh OUTPUT-DIRECTORY
#
# The container is named caboose-flatpak-build-<pid> and removed at the end; CPUS (default 4)
# caps the build.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=$(mkdir -p "${1:?usage: build.sh OUTPUT-DIRECTORY}" && cd "$1" && pwd)
name=caboose-flatpak-build-$$
trap 'docker rm -f "$name" >/dev/null 2>&1 || :' EXIT
docker run --name "$name" --cpus "${CPUS:-4}" -v "$here:/package:ro" -v "$out:/out" debian:trixie \
  sh -euc '/package/build-in-debian.sh /out; chown '"$(id -u):$(id -g)"' /out/*.deb'
ls "$out"
