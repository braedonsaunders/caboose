#!/bin/bash
# Frame lab's headless check (README.md): the guest side of the matrix in a disposable
# container, on the computer's own drivers (llvmpipe and lavapipe), without a phone.
#
#   guest/framelab/check.sh IMAGE BIN [OUT] [-- FRAMELAB-GUEST ARGS...]
#       in a disposable container of the computer image IMAGE, with caboose-display and
#       caboose-display-probe from BIN (a release build of guest/display, target/release);
#       leaves the scorecards, pictures and logs in OUT (default guest/framelab/out)
#   bash guest/framelab/check.sh --here [OUT] [-- ARGS...]
#       as root where all of that is installed
#
# A private caboose-display is started as the owner's seat, watched by
# caboose-display-probe as its client (windows draw only while one is), and the matrix
# runs against it with local pages (--offline). Every app then draws on the computer, so
# its frames are the compositor's. A second short run measures vkcube against
# standin-broker.py, which writes the real broker's present trace to a log the way the
# broker does on a seat, to check the path from that log to a scorecard. The check fails
# when an installed app shows no window or is not measured, or when the stand-in's
# presents do not reach the scorecard. Apps the image lacks are reported and skipped.
#
# The image needs chromium, firefox-esr, gtk-4-examples, qml-qt6, code, vulkan-tools,
# mesa-utils, xfce4-terminal, mpv and ffmpeg. CABOOSE_CHECK_CPUS and CABOOSE_CHECK_MEMORY
# (default 4 and 6g) bound the container.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)

if [[ ${1:-} != --here ]]; then
  [[ $# -ge 2 ]] || { sed -n '5,10p' "$0" >&2; exit 2; }
  image=$1 bin=$(realpath "$2")
  shift 2
  dest=$here/out
  if [[ $# -gt 0 && $1 != -- ]]; then dest=$1; shift; fi
  out=$(mkdir -p "$dest" && cd "$dest" && pwd)
  exec docker run --rm -i --init --network none --cpus "${CABOOSE_CHECK_CPUS:-4}" --memory "${CABOOSE_CHECK_MEMORY:-6g}" \
    --security-opt seccomp="$here/../container/caboose-seccomp.json" \
    -v "$here:/framelab:ro" -v "$here/../gpu:/gpu:ro" \
    -v "$bin/caboose-display:/usr/local/bin/caboose-display:ro" \
    -v "$bin/caboose-display-probe:/usr/local/bin/caboose-display-probe:ro" \
    -v "$out:/out" "$image" bash /framelab/check.sh --here /out "$@"
fi

shift
out=/tmp/caboose-framelab-check
if [[ $# -gt 0 && $1 != -- ]]; then out=$1; shift; fi
[[ ${1:-} == -- ]] && shift
fail() { echo "FAIL: $*" >&2; [[ -f $out/display.log ]] && tail -n 20 "$out/display.log" >&2; exit 1; }
[[ $(id -u) == 0 ]] || fail 'run as root'
for command in caboose-display caboose-display-probe python3 dbus-daemon; do
  command -v "$command" >/dev/null || fail "$command is missing"
done
owner() { runuser -u caboose -- "$@"; }
mkdir -p "$out" && chown caboose: "$out"

pids=()
cleanup() {
  for pid in "${pids[@]}"; do pkill -TERM -P "$pid" 2>/dev/null || true; kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
}
trap cleanup EXIT

rt=/run/user/1000
install -d -o caboose -g caboose -m 0700 "$rt" "$rt/caboose-framelab-check"
dir=$rt/caboose-framelab-check
owner sh -c 'umask 077; od -An -N16 -tx1 /dev/urandom | tr -d " \n" > "$1/token"' sh "$dir"
# A session bus, as every seat has one: GTK and the terminal wait for it.
owner dbus-daemon --session --address="unix:path=$rt/bus" --nofork --nopidfile > "$out/bus.log" 2>&1 &
pids+=($!)
owner env HOME=/home/caboose XDG_RUNTIME_DIR="$rt" DBUS_SESSION_BUS_ADDRESS="unix:path=$rt/bus" \
  CABOOSE_DISPLAY_LOG=info caboose-display --listen 127.0.0.1:14690 --token-file "$dir/token" \
  --socket wayland-caboose-check --x-display 140 --no-audio --env-file "$out/display.env" > "$out/display.log" 2>&1 &
pids+=($!)
for _ in $(seq 1 150); do grep -q '^DISPLAY=' "$out/display.env" 2>/dev/null && break; sleep 0.2; done
grep -q '^DISPLAY=' "$out/display.env" || fail 'caboose-display did not become ready'
echo "DBUS_SESSION_BUS_ADDRESS='unix:path=$rt/bus'" >> "$out/display.env"
owner caboose-display-probe --url ws://127.0.0.1:14690/ --token-file "$dir/token" --display 1920x1080@60x1 \
  --duration 3600 --json > "$out/probe.json" 2> "$out/probe.log" &
pids+=($!)

guest() { owner env HOME=/home/caboose XDG_RUNTIME_DIR="$rt" python3 /framelab/framelab-guest.py --env "$out/display.env" "$@"; }

# The matrix, every app on the computer's drivers.
guest --out "$out/matrix" --offline "$@" > "$out/matrix.jsonl" || fail 'the matrix did not complete'
python3 - "$out/matrix" /framelab/matrix.json <<'PY' || fail 'an app was not measured'
import json, pathlib, sys
out, matrix = pathlib.Path(sys.argv[1]), json.loads(pathlib.Path(sys.argv[2]).read_text())
bad = []
for app in matrix['apps']:
    path = out / f"{app['id']}.json"
    if not path.exists():
        continue  # not in this run's --apps
    card = json.loads(path.read_text())
    if card.get('skipped'):
        print(f"{app['id']}: skipped ({card['skipped']})")
    elif not card['ok'] and any(m in (card.get('error') or '') for m in ('is not installed', 'no desktop entry')):
        print(f"{app['id']}: not in this image ({card['error']})")
    elif not card['ok'] or card['pacing']['frames'] == 0:
        bad.append(f"{app['id']}: {card.get('error') or 'no frames'}")
    elif app.get('correctness') and not (card.get('correctness') or {}).get('ssim'):
        bad.append(f"{app['id']}: no picture comparison ({card.get('correctness')})")
print('\n'.join(bad))
sys.exit(1 if bad else 0)
PY

# The broker's present trace, through a stand-in that writes it as the broker does.
: > "$out/broker.log"; chown caboose: "$out/broker.log"
owner env XDG_RUNTIME_DIR="$rt" python3 /framelab/standin-broker.py /gpu "$out/broker.log" &
pids+=($!)
if command -v vkcube >/dev/null; then
  guest --out "$out/broker" --apps vkcube --no-reference --broker-log "$out/broker.log" > "$out/broker.jsonl" ||
    fail 'the stand-in run did not complete'
  python3 - "$out/broker/vkcube.json" <<'PY' || fail "the stand-in broker's presents did not reach the scorecard"
import json, sys
card = json.load(open(sys.argv[1]))
pace = card['pacing']
print(f"stand-in: path {card['path']}, {pace['per_s']} presents/s, phone results {pace.get('phone_results_per_s')}/s, "
      f"stream {card['resources']['stream_bytes_per_s']} B/s")
assert card['path'] == 'gpu' and pace['source'] == 'CABOOSE_GPU_PRESENT', card
assert 40 <= pace['per_s'] <= 55 and pace['phone_results_per_s'] > 40, pace
assert card['resources']['stream_bytes_per_s'] > 1_000_000, card['resources']
PY
fi
[[ ! -e $rt/caboose-gpu-present-trace ]] || fail 'the present trace was left on'
echo "PASS: frame lab measured the matrix headless; scorecards in $out/matrix"
