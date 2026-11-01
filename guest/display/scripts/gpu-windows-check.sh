#!/bin/bash
# The GPU compositor's window pictures and their cost (README.md, "Checking the pictures"),
# in a disposable container of a computer image, on the computer's own Vulkan device
# (lavapipe, presented as a GPU by the routing layer), without a phone.
#
#   guest/display/scripts/gpu-windows-check.sh IMAGE BIN LIBS [OUT]
#       IMAGE   a computer image (caboose-computer:…)
#       BIN     a release build of guest/display (target/release)
#       LIBS    a directory with vgem_gbm.so (guest/gpu/gbm) and
#               libVkLayer_caboose_gpu_routing.so (guest/gpu/routing-layer)
#       OUT     where the pictures, logs and report go [default: guest/display/out/gpu-windows]
#   bash guest/display/scripts/gpu-windows-check.sh --here OUT
#       as root where all of that is installed
#
# The container installs foot, xterm and Wine from the distribution when the image lacks
# them, so it needs the network. CABOOSE_CHECK_CPUS and CABOOSE_CHECK_MEMORY (default 4
# and 6g) bound it.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)

if [[ ${1:-} != --here ]]; then
  [[ $# -ge 3 ]] || { sed -n '5,12p' "$0" >&2; exit 2; }
  image=$1 bin=$(realpath "$2") libs=$(realpath "$3")
  dest=${4:-$here/../out/gpu-windows}
  out=$(mkdir -p "$dest" && cd "$dest" && pwd)
  devices=()
  [[ -e /dev/dri ]] && devices=(--device /dev/dri)
  exec docker run --rm -i --init --cpus "${CABOOSE_CHECK_CPUS:-4}" --memory "${CABOOSE_CHECK_MEMORY:-6g}" "${devices[@]}" \
    -v "$here:/check:ro" -v "$here/../../gpu:/gpu:ro" -v "$libs:/libs:ro" \
    -v "$bin/caboose-display:/usr/local/bin/caboose-display:ro" \
    -v "$bin/caboose-display-probe:/usr/local/bin/caboose-display-probe:ro" \
    -v "$out:/out" "$image" bash /check/gpu-windows-check.sh --here /out
fi

out=$2
fail() { echo "FAIL: $*" >&2; [[ -f $out/display.log ]] && tail -n 20 "$out/display.log" >&2; exit 1; }
[[ $(id -u) == 0 ]] || fail 'run as root'
missing=()
for command in foot:foot xterm:xterm wine:wine; do
  command -v "${command%%:*}" >/dev/null || missing+=("${command##*:}")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends "${missing[@]}" >/dev/null ||
    fail "cannot install ${missing[*]}"
fi
if [[ -d /libs ]]; then
  install -D -m 0644 /libs/vgem_gbm.so "/usr/lib/$(uname -m)-linux-gnu/gbm/vgem_gbm.so"
  python3 /gpu/install-live.py --routing-layer /libs/libVkLayer_caboose_gpu_routing.so >/dev/null
fi
chmod a+rw /dev/dri/* 2>/dev/null || true
owner() { runuser -u caboose -- env HOME=/home/caboose XDG_RUNTIME_DIR="$rt" DBUS_SESSION_BUS_ADDRESS="unix:path=$rt/bus" "$@"; }
rt=/run/user/1000
install -d -o caboose -g caboose -m 0700 "$rt" "$rt/gpu-windows-check"
dir=$rt/gpu-windows-check
owner sh -c 'umask 077; od -An -N16 -tx1 /dev/urandom | tr -d " \n" > "$1/token"' sh "$dir"
mkdir -p "$out" && chown caboose: "$out"

pids=()
cleanup() {
  for pid in "${pids[@]}"; do pkill -TERM -P "$pid" 2>/dev/null || true; kill "$pid" 2>/dev/null || true; done
  pkill -u caboose wineserver 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT

owner dbus-daemon --session --address="unix:path=$rt/bus" --nofork --nopidfile > "$out/bus.log" 2>&1 &
pids+=($!)
owner env CABOOSE_DISPLAY_LOG=info caboose-display --listen 127.0.0.1:14691 --token-file "$dir/token" \
  --socket wayland-caboose-gpucheck --x-display 141 --no-audio --env-file "$out/display.env" > "$out/display.log" 2>&1 &
display=$!
pids+=($display)
for _ in $(seq 1 150); do grep -q '^DISPLAY=' "$out/display.env" 2>/dev/null && break; sleep 0.2; done
grep -q '^DISPLAY=' "$out/display.env" || fail 'caboose-display did not become ready'
# The compositor draws windows while a client is connected: the probe is that client.
owner caboose-display-probe --url ws://127.0.0.1:14691/ --token-file "$dir/token" --display 1920x1080@60x1 \
  --duration 3600 --json > "$out/probe.json" 2> "$out/probe.log" &
pids+=($!)
server=$(pgrep -u caboose -x caboose-display | head -1)
owner env WINEDEBUG=-all python3 /check/gpu-windows-check.py --env "$out/display.env" \
  --control "$rt/caboose-display/wayland-caboose-gpucheck/control.sock" --pid "$server" --out "$out" \
  > "$out/report.json" || fail "$(cat "$out/report.json")"
cat "$out/report.json"
echo "PASS: every window's picture is what its application drew; report in $out/report.json"
