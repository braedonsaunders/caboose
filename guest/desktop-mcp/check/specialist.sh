#!/bin/bash
# Run inside a disposable image containing Caboose Display, GTK3, AT-SPI and Node.
# No owner seat or profile is used. /src mounts guest/desktop-mcp read-only.
set -euo pipefail
export XDG_RUNTIME_DIR=/tmp/specialist-runtime HOME=/tmp/specialist-home
mkdir -p "$XDG_RUNTIME_DIR" "$HOME"
chmod 700 "$XDG_RUNTIME_DIR"
cleanup() { jobs -pr | xargs -r kill; wait || true; }
trap cleanup EXIT
caboose-display --no-auth --no-audio --no-games --no-devices --listen 127.0.0.1:15499 --socket specialist --x-display 101 --env-file /tmp/specialist.env >/tmp/specialist-display.log 2>&1 &
for n in $(seq 1 100); do test -s /tmp/specialist.env && break; sleep .1; done
set -a
. /tmp/specialist.env
set +a
export ACCESSIBILITY_ENABLED=1 GNOME_ACCESSIBILITY=1
failures=0
for variant in development heldout; do
  python3 /src/check/specialist-fixture.py --variant "$variant" --log /tmp/specialist-effects.jsonl >/tmp/specialist-fixture.log 2>&1 &
  fixture=$!
  node /src/check/specialist.mjs "$variant" "$@" || failures=$((failures + 1))
  kill "$fixture"
  wait "$fixture" || true
done
exit "$failures"
