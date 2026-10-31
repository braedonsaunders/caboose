#!/bin/bash
# The touch-targeting benchmark's guest side (README.md) in a disposable container of a
# Caboose computer image, without a phone.
#
#   guest/touch-targets/check.sh IMAGE OUT [BIN] [-- BENCH-GUEST ARGS...]
#       IMAGE: a computer image; OUT: where the fixtures go; BIN: a release build of
#       guest/display (target/release) to use instead of the image's caboose-display
#   bash guest/touch-targets/check.sh --here OUT [-- ARGS...]
#       as root where all of that is installed
#
# CABOOSE_CHECK_CPUS and CABOOSE_CHECK_MEMORY (default 4 and 4g) bound the container.
# CABOOSE_CHECK_DISPLAY (default 1920x1080@60x1) is the probe's display.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)

if [[ ${1:-} != --here ]]; then
  [[ $# -ge 2 ]] || { sed -n '5,10p' "$0" >&2; exit 2; }
  image=$1 out=$(mkdir -p "$2" && cd "$2" && pwd)
  shift 2
  mounts=()
  if [[ $# -gt 0 && $1 != -- ]]; then
    bin=$(realpath "$1"); shift
    mounts+=(-v "$bin/caboose-display:/usr/local/bin/caboose-display:ro"
             -v "$bin/caboose-display-probe:/usr/local/bin/caboose-display-probe:ro")
  fi
  exec docker run --rm -i --init --network none --cpus "${CABOOSE_CHECK_CPUS:-4}" --memory "${CABOOSE_CHECK_MEMORY:-4g}" \
    --security-opt seccomp="$here/../container/caboose-seccomp.json" \
    -v "$here:/tt/touch-targets:ro" -v "$here/../desktop-mcp/caboose-targets.py:/opt/caboose/caboose-targets.py:ro" \
    -v "$here/../desktop-mcp:/tt/desktop-mcp:ro" "${mounts[@]}" \
    -e CABOOSE_CHECK_DISPLAY="${CABOOSE_CHECK_DISPLAY:-1920x1080@60x1}" \
    -v "$out:/out" "$image" bash /tt/touch-targets/check.sh --here /out "$@"
fi

shift
out=$1; shift
[[ ${1:-} == -- ]] && shift
fail() { echo "FAIL: $*" >&2; [[ -f $out/display.log ]] && tail -n 20 "$out/display.log" >&2; exit 1; }
[[ $(id -u) == 0 ]] || fail 'run as root'
owner() { runuser -u caboose -- "$@"; }
mkdir -p "$out" && chown caboose: "$out"

pids=()
cleanup() {
  for pid in "${pids[@]}"; do pkill -TERM -P "$pid" 2>/dev/null || true; kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
}
trap cleanup EXIT

rt=/run/user/1000
install -d -o caboose -g caboose -m 0700 "$rt" "$rt/caboose-targets-check"
dir=$rt/caboose-targets-check
owner sh -c 'umask 077; od -An -N16 -tx1 /dev/urandom | tr -d " \n" > "$1/token"' sh "$dir"
owner dbus-daemon --session --address="unix:path=$rt/bus" --nofork --nopidfile > "$out/bus.log" 2>&1 &
pids+=($!)
export ACCESSIBILITY_ENABLED=1 GNOME_ACCESSIBILITY=1 QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1
owner env HOME=/home/caboose XDG_RUNTIME_DIR="$rt" DBUS_SESSION_BUS_ADDRESS="unix:path=$rt/bus" \
  ACCESSIBILITY_ENABLED=1 GNOME_ACCESSIBILITY=1 QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1 \
  CABOOSE_DISPLAY_LOG=info caboose-display --listen 127.0.0.1:14690 --token-file "$dir/token" \
  --socket wayland-caboose-check --x-display 140 --no-audio --env-file "$out/display.env" > "$out/display.log" 2>&1 &
pids+=($!)
for _ in $(seq 1 150); do grep -q '^DISPLAY=' "$out/display.env" 2>/dev/null && break; sleep 0.2; done
grep -q '^DISPLAY=' "$out/display.env" || fail 'caboose-display did not become ready'
echo "DBUS_SESSION_BUS_ADDRESS='unix:path=$rt/bus'" >> "$out/display.env"
owner caboose-display-probe --url ws://127.0.0.1:14690/ --token-file "$dir/token" --display "$CABOOSE_CHECK_DISPLAY" \
  --duration 3600 --json --targets "$out/targets.jsonl" > "$out/probe.json" 2> "$out/probe.log" &
pids+=($!)
# The seat's accessibility bus, before any app, as caboose-session starts it.
owner env HOME=/home/caboose XDG_RUNTIME_DIR="$rt" DBUS_SESSION_BUS_ADDRESS="unix:path=$rt/bus" /bin/sh -c \
  'set -a; . "$0"; exec python3 /tt/desktop-mcp/a11y.py bus --display "$DISPLAY" --wait 30' "$out/display.env" > "$out/a11y-bus.json" ||
  fail 'no accessibility bus'
owner env HOME=/home/caboose XDG_RUNTIME_DIR="$rt" ACCESSIBILITY_ENABLED=1 GNOME_ACCESSIBILITY=1 \
  python3 /tt/touch-targets/bench/bench-guest.py --env "$out/display.env" --out "$out" --targets-log "$out/targets.jsonl" "$@"
