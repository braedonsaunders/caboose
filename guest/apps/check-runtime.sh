#!/usr/bin/env bash
# Prove the caboose-app runtime in a real WebKitGTK window, under Docker on any amd64 or
# arm64 machine (no KVM): Debian 13 with Xvfb and WebKitGTK 4.1. See README.md for what it
# asserts; check/run.sh also runs inside a Caboose computer.
#
#   guest/apps/check-runtime.sh [--rmi]
#
# Builds the test image caboose-app-check, runs check/run.sh in a throwaway container with
# this directory mounted read-only, and removes the container. --rmi removes the image too.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
image=caboose-app-check
container=caboose-app-check-$$
docker build -q -t "$image" "$here/check" >/dev/null
cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  if [[ ${1:-} == --rmi ]]; then docker rmi "$image" >/dev/null 2>&1 || true; fi
}
trap 'cleanup "${1:-}"' EXIT
docker run -d --name "$container" --memory 1500m --shm-size 256m -v "$here:/src:ro" "$image" >/dev/null
docker exec "$container" bash /src/check/run.sh
