#!/usr/bin/env bash
# Prove a11y.py and the accessibility tools in real X sessions, under Docker on any amd64
# or arm64 machine (no KVM): Debian 13 with Xvfb, Caboose Display (built from this checkout)
# for the owner's display and the agent seat, D-Bus, at-spi2-core, GTK apps and Chromium.
# See README.md for what it asserts.
#
#   guest/desktop-mcp/check-a11y.sh [--rmi]
#
# Builds the test image caboose-a11y-check, runs check/run.sh in a throwaway container with
# this directory mounted read-only, and removes the container. --rmi removes the image too.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
image=caboose-a11y-check
container=caboose-a11y-check-$$
docker build -q -t "$image" -f "$here/check/Dockerfile" "$here/.." >/dev/null
cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  if [[ ${1:-} == --rmi ]]; then docker rmi "$image" >/dev/null 2>&1 || true; fi
}
trap 'cleanup "${1:-}"' EXIT
docker run -d --name "$container" --memory 1500m --shm-size 256m -v "$here:/src:ro" "$image" >/dev/null
docker exec "$container" bash /src/check/run.sh
