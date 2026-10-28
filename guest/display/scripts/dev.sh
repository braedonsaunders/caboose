#!/bin/sh
# Runs a command in the caboose-display dev container (guest/display/Dockerfile) with
# this directory at /src, as the calling user, with a persistent cargo registry.
#
#   guest/display/scripts/dev.sh cargo test
#   CABOOSE_DISPLAY_DRI=1 guest/display/scripts/dev.sh ...   # pass /dev/dri through
#
# CPU and memory are capped (CABOOSE_DISPLAY_CPUS, default 6; CABOOSE_DISPLAY_MEMORY,
# default 6g) so a build does not starve the rest of the machine.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
cache=${XDG_CACHE_HOME:-$HOME/.cache}/caboose-display
mkdir -p "$cache/registry" "$cache/git"
image=${CABOOSE_DISPLAY_IMAGE:-caboose-display-dev}
set -- --rm -i --init \
  --user "$(id -u):$(id -g)" -e HOME=/tmp -e CARGO_BUILD_JOBS="${CABOOSE_DISPLAY_CPUS:-6}" \
  --cpus "${CABOOSE_DISPLAY_CPUS:-6}" --memory "${CABOOSE_DISPLAY_MEMORY:-6g}" \
  -v "$here:/src" -w /src \
  -v "$cache/registry:/opt/cargo/registry" -v "$cache/git:/opt/cargo/git" \
  ${CABOOSE_DISPLAY_DOCKER_ARGS:-} "$image" "$@"
if [ "${CABOOSE_DISPLAY_DRI:-0}" = 1 ] && [ -d /dev/dri ]; then
  for node in /dev/dri/renderD*; do set -- --device "$node" --group-add "$(stat -c %g "$node")" "$@"; done
fi
if [ -t 0 ] && [ -t 1 ]; then set -- -t "$@"; fi
exec docker run "$@"
