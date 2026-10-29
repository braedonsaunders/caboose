#!/bin/bash
# GPU stream check: a Vulkan application under caboose-gpu-run on a private caboose-display,
# rendering nothing, with caboose-display-probe taking its stream like a client.
#
#   guest/gpu/check.sh [OUT]          # in the display's dev container, the bundle built there
#   bash guest/gpu/check.sh --here    # as root where caboose-display, the probe, vkcube and
#                                     # /usr/local/lib/caboose-gpu are installed
#
# It checks that the probe gets gpu.create for the application's window, that the window
# sends no pictures, and that the stream it saves is a GFXReconstruct capture; the stream is
# left in OUT/gpu-check.gfxr (default guest/gpu/out) for `gfxrecon-replay` on any GPU.
set -euo pipefail
here=0
for arg; do case $arg in --here) here=1 ;; --dev) ;; *) out_arg=$arg ;; esac; done

if ((!here)); then
  gpu=$(cd "$(dirname "$0")" && pwd)
  display=$(cd "$gpu/../display" && pwd)
  out=$(mkdir -p "${out_arg:-$gpu/out}" && cd "${out_arg:-$gpu/out}" && pwd)
  [[ -x $display/target/debug/caboose-display && -x $display/target/debug/caboose-display-probe ]] ||
    { echo 'Build the display first: guest/display/scripts/dev.sh cargo build' >&2; exit 1; }
  exec docker run --rm -i --init --cpus "${CABOOSE_DISPLAY_CPUS:-2}" --memory "${CABOOSE_DISPLAY_MEMORY:-3g}" \
    -v "$display:/src:ro" -v "$gpu:/gpu:ro" -v "$out:/out" -e CABOOSE_GPU_JOBS="${CABOOSE_GPU_JOBS:-2}" \
    -e CABOOSE_GPU_CHECK_BIN=/src/target/debug -e CABOOSE_GPU_DIR=/out/caboose-gpu \
    "${CABOOSE_DISPLAY_IMAGE:-caboose-display-dev}" bash /gpu/check.sh --here --dev /out
fi

fail() {
  echo "FAIL: $*" >&2
  [[ -n ${rt:-} && -f $rt/display.log ]] && tail -n 30 "$rt/display.log" >&2
  [[ -n ${work:-} && -f $work/app.log ]] && tail -n 20 "$work/app.log" >&2
  exit 1
}
[[ $(id -u) == 0 ]] || fail 'run as root'
out=${out_arg:-/tmp}
lib=${CABOOSE_GPU_DIR:-/usr/local/lib/caboose-gpu}
if [[ $* == *--dev* ]]; then
  apt-get update -qq >/dev/null
  apt-get install -y -qq --no-install-recommends python3 python3-venv libpython3-dev vulkan-tools libvulkan1 git cmake ninja-build g++ pkg-config \
    libx11-dev libx11-xcb-dev libxcb1-dev libxcb-keysyms1-dev libxrandr-dev libwayland-dev wayland-protocols >/dev/null || fail 'apt-get'
  [[ -f $lib/icd.json ]] || /gpu/build.sh "$lib" || fail 'build.sh'
  id caboose >/dev/null 2>&1 || useradd -m caboose
  run=/gpu/caboose-gpu-run
else
  run=caboose-gpu-run
fi
bin=${CABOOSE_GPU_CHECK_BIN:-}
display=${bin:+$bin/}caboose-display
probe_bin=${bin:+$bin/}caboose-display-probe
for command in "$display" "$probe_bin" "$run" vkcube; do command -v "$command" >/dev/null || fail "$command is missing"; done
port=${CABOOSE_CHECK_PORT:-14691}
owner() { runuser -u caboose -- "$@"; }
work=$(owner mktemp -d /tmp/caboose-gpu-check.XXXXXX)
rt=$(owner mktemp -d /tmp/caboose-gpu-check-runtime.XXXXXX)
pids=()
cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  rm -rf "$work" "$rt"
}
trap cleanup EXIT

owner sh -c 'umask 077; od -An -N16 -tx1 /dev/urandom | tr -d " \n" > "$1/token"' sh "$rt"
owner env CABOOSE_DISPLAY_LOG=info HOME="$(getent passwd caboose | cut -d: -f6)" XDG_RUNTIME_DIR="$rt" "$display" --listen "127.0.0.1:$port" --token-file "$rt/token" \
  --socket wayland-caboose-gpu-check --x-display 131 --no-audio --env-file "$rt/display.env" > "$rt/display.log" 2>&1 &
pids+=($!)
probe() { owner "$probe_bin" --url "ws://127.0.0.1:$port/" --token-file "$rt/token" "$@"; }
for _ in $(seq 1 150); do probe --check >/dev/null 2>&1 && break; sleep 0.2; done
probe --check >/dev/null 2>&1 || fail 'the private caboose-display did not answer'
for _ in $(seq 1 50); do grep -q '^DISPLAY=' "$rt/display.env" 2>/dev/null && break; sleep 0.2; done
grep -q '^CABOOSE_GAME_SOCKET=' "$rt/display.env" || fail 'caboose-display offers no game socket'

probe --gpu-save "$work/hello" --check | grep -q '"gpu"' || fail "the display does not offer gpu: $(probe --gpu-save "$work/hello" --check)"
frames=${CABOOSE_GPU_CHECK_FRAMES:-300}
probe --gpu-save "$work/streams" --json --duration 30 > "$work/probe.json" 2> "$work/probe.err" &
probe_pid=$!
pids+=("$probe_pid")
sleep 1
owner sh -c 'set -a; . "$1"; set +a; export CABOOSE_GPU_DIR="$2"; exec "$3" --title "GPU check" -- vkcube --wsi xcb --use_staging --c "$4"' \
  sh "$rt/display.env" "$lib" "$run" "$frames" > "$work/app.log" 2>&1 &
app=$!
pids+=("$app")
for _ in $(seq 1 250); do kill -0 "$app" 2>/dev/null || break; sleep 0.1; done
grep -iE "gpu|game|launcher|session|connection" "$rt/display.log" | tail -12 || true
if kill -0 "$app" 2>/dev/null; then
  grep -E 'game|gpu|bound' "$rt/display.log" | tail -6 >&2 || true
  wait "$probe_pid" || true
  fail "vkcube did not finish $frames frames in 25 s; the probe saw: $(cat "$work/probe.json")"
fi
wait "$probe_pid" || true
python3 - "$work/probe.json" <<'PY' || fail "the probe's report: $(cat "$work/probe.json")"
import json, sys
report = json.load(open(sys.argv[1]))
gpus = report['gpus']
assert len(gpus) == 1, f'{len(gpus)} GPU streams'
stream = gpus[0]
assert stream['bytes'] > 0, 'no stream bytes'
window = [w for w in report['windows'] if w['id'] == stream['window']]
assert window, 'the stream names no window the probe knows'
assert window[0]['frames'] == 0, f"the window sent {window[0]['frames']} pictures"
print(f"gpu stream {stream['id']} for window {stream['window']} ({window[0]['title']!r}): {stream['bytes']} bytes, "
      f"no pictures, destroyed={stream['destroyed']}")
PY
stream=$(ls "$work"/streams/gpu-*.gfxr)
[[ $(head -c 4 "$stream") == GFXR ]] || fail 'the stream is not a GFXReconstruct capture'
install -m 644 "$stream" "$out/gpu-check.gfxr"
echo "stream saved to $out/gpu-check.gfxr ($(stat -c %s "$out/gpu-check.gfxr") bytes)"
echo OK
