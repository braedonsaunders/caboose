#!/usr/bin/env bash
# Disposable Debian 13 install + real X11 window check; native amd64 or arm64.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
image="caboose-desktop-check:local-$$"
container="caboose-desktop-check-$$"
cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker image rm "$image" >/dev/null 2>&1 || true
}
trap cleanup EXIT
# Use the project's existing Chromium namespace policy, never --no-sandbox.
docker build -t "$image" -f "$here/desktop-check/Dockerfile" "$here"
docker run --name "$container" --init --cpus 2 --memory 2g --shm-size 256m \
  --security-opt "seccomp=$here/../container/chromium-seccomp.json" "$image"
