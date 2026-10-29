#!/bin/bash
# GPU stream check: a Vulkan application under caboose-gpu-run on a private caboose-display,
# rendering nothing, with caboose-display-probe taking its stream like a client.
#
#   guest/gpu/check.sh [OUT]          # in the display's dev container, the bundle built there
#   bash guest/gpu/check.sh --here    # as root where caboose-display, the probe, vkcube and
#                                     # /usr/local/lib/caboose-gpu are installed
#
# It checks that a Vulkan application's stream reaches the probe as gpu.data for its window,
# which sends no pictures, and saves it to OUT/gpu-check.gfxr (default guest/gpu/out) for
# `gfxrecon-replay` on any GPU; that 80 MiB written before the window exists all arrive; and
# that a stream outgrowing --gpu-spool-limit ends with the reason the client is given.
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
  apt-get install -y -qq --no-install-recommends python3 python3-venv libpython3-dev vulkan-tools x11-utils libvulkan1 git cmake ninja-build g++ pkg-config \
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
for command in "$display" "$probe_bin" "$run" vkcube xmessage; do command -v "$command" >/dev/null || fail "$command is missing"; done
owner() { runuser -u caboose -- "$@"; }
work=$(owner mktemp -d /tmp/caboose-gpu-check.XXXXXX)
rts=()
pids=()
cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  rm -rf "$work" "${rts[@]}"
}
trap cleanup EXIT

# A private display, on its own port and runtime directory, with any extra options.
start_display() { # name port options...
  local name=$1 port=$2
  shift 2
  rt=$(owner mktemp -d "/tmp/caboose-gpu-check-$name.XXXXXX")
  rts+=("$rt")
  owner sh -c 'umask 077; od -An -N16 -tx1 /dev/urandom | tr -d " \n" > "$1/token"' sh "$rt"
  owner env CABOOSE_DISPLAY_LOG=info HOME="$(getent passwd caboose | cut -d: -f6)" XDG_RUNTIME_DIR="$rt" "$display" \
    --listen "127.0.0.1:$port" --token-file "$rt/token" --socket "wayland-caboose-gpu-$name" --x-display "$((130 + ${#rts[@]}))" \
    --no-audio --env-file "$rt/display.env" "$@" > "$rt/display.log" 2>&1 &
  display_pid=$!
  pids+=("$display_pid")
  url="ws://127.0.0.1:$port/"
  for _ in $(seq 1 150); do probe --check >/dev/null 2>&1 && break; sleep 0.2; done
  probe --check >/dev/null 2>&1 || fail "$name: the private caboose-display did not answer"
  for _ in $(seq 1 50); do grep -q '^DISPLAY=' "$rt/display.env" 2>/dev/null && break; sleep 0.2; done
  probe --gpu-save "$work/hello" --check | grep -q '"gpu"' || fail "$name: the display does not offer gpu"
}
probe() { owner "$probe_bin" --url "$url" --token-file "$rt/token" "$@"; }
stop_display() { kill "$display_pid" 2>/dev/null || true; wait "$display_pid" 2>/dev/null || true; }

# Runs COMMAND under caboose-gpu-run while a probe takes the stream; leaves the report in
# $work/$name.json and the stream in $work/$name/.
stream() { # name seconds command...
  local name=$1 seconds=$2 probe_pid app
  shift 2
  probe --gpu-save "$work/$name" --json --duration "$((seconds + 5))" > "$work/$name.json" 2> "$work/$name.err" &
  probe_pid=$!
  pids+=("$probe_pid")
  sleep 1
  owner sh -c 'set -a; . "$1"; set +a; export CABOOSE_GPU_DIR="$2"; shift 2; exec "$@"' \
    sh "$rt/display.env" "$lib" "$run" --title "GPU check $name" -- "$@" > "$work/app.log" 2>&1 &
  app=$!
  pids+=("$app")
  for _ in $(seq 1 "$((seconds * 10))"); do kill -0 "$app" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$app" 2>/dev/null; then
    grep -E 'game|gpu|bound' "$rt/display.log" | tail -6 >&2 || true
    wait "$probe_pid" || true
    fail "$name: the application did not finish in $seconds s; the probe saw: $(cat "$work/$name.json")"
  fi
  wait "$probe_pid" || true
}
report() { # name python-assertions
  python3 - "$work/$1.json" "$2" <<'PY' || fail "$1: the probe's report: $(cat "$work/$1.json")"
import json, sys
report = json.load(open(sys.argv[1]))
gpus = report['gpus']
assert len(gpus) == 1, f'{len(gpus)} GPU streams'
stream = gpus[0]
window = [w for w in report['windows'] if w['id'] == stream['window']]
assert window, 'the stream names no window the probe knows'
window = window[0]
exec(sys.argv[2])
print(f"stream {stream['id']} for window {stream['window']}: {stream['bytes']} bytes, {window['frames']} pictures, "
      f"destroyed={stream['destroyed']} reason={stream['reason']}")
PY
}

# 1. A Vulkan application: its stream reaches the client and its window sends no pictures.
frames=${CABOOSE_GPU_CHECK_FRAMES:-300}
start_display relay 14691
stream relay 25 vkcube --wsi xcb --use_staging --c "$frames"
report relay "assert stream['bytes'] > 0 and window['frames'] == 0 and stream['reason'] is None"
saved=$(ls "$work"/relay/gpu-*.gfxr)
[[ $(head -c 4 "$saved") == GFXR ]] || fail 'relay: the stream is not a GFXReconstruct capture'
install -m 644 "$saved" "$out/gpu-check.gfxr"
echo "relay: OK, saved to $out/gpu-check.gfxr ($(stat -c %s "$out/gpu-check.gfxr") bytes)"

# 2. An application that writes 80 MiB, more than the client may fall behind, before it maps
# its window: the relay reads it all and the client gets every byte.
upload='head -c 83886080 /dev/urandom > "$GFXRECON_CAPTURE_FILE" && exec xmessage -timeout 12 "GPU check"'
stream upload 30 sh -c "$upload"
report upload "assert stream['bytes'] == 83886080, stream['bytes']"
echo 'upload before the window: OK'
stop_display

# 3. A stream that outgrows the spool limit ends, and the client is told why.
start_display limit 14692 --gpu-spool-limit 16777216
stream limit 30 sh -c "$upload"
report limit "assert stream['destroyed'] and stream['reason'] == 'spool-limit', stream"
echo 'spool limit: OK'
stop_display
echo OK
