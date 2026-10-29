#!/usr/bin/env bash
# Exercise the opted-in launcher, authenticated guest relay and local fallback in Docker.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
guest=$(cd "$here/.." && pwd)
docker build -q -t caboose-app-check "$here/check" >/dev/null
docker run --rm --init --cpus 2 --memory 1200m --shm-size 256m \
  -v "$here:/src:ro" -v "$guest/files:/files:ro" \
  -v "$guest/game/caboose-game-run:/usr/local/bin/caboose-game-run:ro" \
  caboose-app-check /usr/bin/python3 /src/check/handoff/check.py
