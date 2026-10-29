#!/usr/bin/env bash
# End-to-end check for game handoff: caboose-game-run against a real caboose-display,
# driven by caboose-display-probe (README.md, "Test").
#
#   guest/game/check.sh                      # in the caboose-display dev container (Docker)
#   sudo bash guest/game/check.sh --here     # as root on a computer (microVM)
#   docker exec -i -u root caboose-owner bash -s -- --here < guest/game/check.sh   # container
#
# Without --here it runs itself in the dev container (guest/display/Dockerfile) with the
# debug binaries `guest/display/scripts/dev.sh cargo build` made, adding the GTK bindings the
# launcher needs and a `caboose` user. With --here it uses caboose-display,
# caboose-display-probe and caboose-game-run from PATH, or from CABOOSE_GAME_CHECK_BIN (the
# display's binaries) and CABOOSE_GAME_CHECK_RUN (the launcher).
#
# It starts a private caboose-display as caboose (its own runtime directory, port and
# Wayland socket, no Xwayland or sound), so the owner's display and devices are untouched,
# and writes a throwaway bundle with a native fallback under caboose's home. Then:
#
#   1. a probe that plays games (--wasm) gets game.create for the launcher's window, with the
#      bundle's root, entry and saves, and no picture of that window; the native fallback
#      does not run; closing the window from the probe ends the launcher, and the game is
#      destroyed;
#   2. with a probe that does not play games, native_fallback replaces the launcher (same
#      process id);
#   3. without CABOOSE_GAME_SOCKET, native_fallback replaces the launcher at once.
#
# CABOOSE_CHECK_PORT picks the private display's port (default 14690). Exits non-zero on the
# first failure, with the launcher's output and the display's log.
set -euo pipefail
here=0 dev=0
for argument; do
  case $argument in
    --here) here=1 ;;
    --dev) dev=1 ;;
    *) echo "usage: $0 [--here]" >&2; exit 2 ;;
  esac
done

if ((!here)); then
  game=$(cd "$(dirname "$0")" && pwd)
  display=$(cd "$game/../display" && pwd)
  [[ -x $display/target/debug/caboose-display && -x $display/target/debug/caboose-display-probe ]] ||
    { echo 'Build the display first: guest/display/scripts/dev.sh cargo build' >&2; exit 1; }
  exec docker run --rm -i --init --cpus "${CABOOSE_DISPLAY_CPUS:-2}" --memory "${CABOOSE_DISPLAY_MEMORY:-2g}" \
    -v "$display:/src:ro" -v "$game:/game:ro" \
    -e CABOOSE_GAME_CHECK_BIN=/src/target/debug -e CABOOSE_GAME_CHECK_RUN=/game/caboose-game-run \
    -e CABOOSE_CHECK_PORT="${CABOOSE_CHECK_PORT:-14690}" \
    "${CABOOSE_DISPLAY_IMAGE:-caboose-display-dev}" bash /game/check.sh --here --dev
fi

port=${CABOOSE_CHECK_PORT:-14690}
fail() {
  echo "FAIL: $*" >&2
  [[ -n ${rt:-} && -f $rt/display.log ]] && tail -n 40 "$rt/display.log" >&2
  exit 1
}
[[ $(id -u) == 0 ]] || fail 'run as root'
if ((dev)); then
  # The dev container has the display's dependencies; the launcher also needs GTK.
  if ! { apt-get update -qq && apt-get install -y -qq --no-install-recommends python3-gi gir1.2-gtk-3.0; } >/dev/null; then
    fail 'could not install python3-gi and gir1.2-gtk-3.0'
  fi
  id caboose >/dev/null 2>&1 || useradd -m caboose
fi
bin=${CABOOSE_GAME_CHECK_BIN:-}
display=${bin:+$bin/}caboose-display
probe_bin=${bin:+$bin/}caboose-display-probe
run=${CABOOSE_GAME_CHECK_RUN:-caboose-game-run}
for command in "$display" "$probe_bin" "$run"; do
  command -v "$command" >/dev/null || fail "$command is not installed"
done
owner() { runuser -u caboose -- "$@"; }
home=$(getent passwd caboose | cut -d: -f6)
[[ -d $home ]] || fail 'the caboose user has no home'
owner mkdir -p "$home/.cache"
work=$(owner mktemp -d "$home/.cache/caboose-game-check.XXXXXX")
rt=$(owner mktemp -d /tmp/caboose-game-check-runtime.XXXXXX)
pids=()
cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  for file in "$work"/*.pid; do [[ -s $file ]] && kill "$(cat "$file")" 2>/dev/null || true; done
  wait 2>/dev/null || true
  rm -rf "$work" "$rt"
}
trap cleanup EXIT
relative=${work#"$home"/}
title="Caboose game check $RANDOM"

# The bundle: a page, and a native fallback that records the process id it runs as.
owner sh -c 'umask 022
  mkdir -p "$1/game/web" "$1/game/native"
  printf "<!DOCTYPE html><title>check</title>\n" > "$1/game/web/index.html"
  printf "#!/bin/sh\necho \$\$ > \"\$1\"\n" > "$1/game/native/fallback"
  chmod 755 "$1/game/native/fallback"' sh "$work"
owner python3 -I - "$work" "$relative" "$title" <<'PY'
import json, sys
work, relative, title = sys.argv[1:]
json.dump({'version': 1, 'title': title, 'app_id': 'org.caboose.GameCheck', 'root': 'web', 'entry': 'index.html',
           'saves': [{'mount': '/check', 'path': f'{relative}/saves'}],
           'native_fallback': ['native/fallback', f'~/{relative}/fallback.pid'],
           'window': {'size': [800, 600], 'min': [320, 240]}}, open(f'{work}/game/caboose-game.json', 'w'))
PY

# The private display.
owner sh -c 'umask 077; od -An -N16 -tx1 /dev/urandom | tr -d " \n" > "$1/token"' sh "$rt"
owner env XDG_RUNTIME_DIR="$rt" "$display" --listen "127.0.0.1:$port" --token-file "$rt/token" \
  --socket wayland-caboose-game-check --no-xwayland --no-audio --env-file "$rt/display.env" > "$rt/display.log" 2>&1 &
pids+=($!)
probe() { owner "$probe_bin" --url "ws://127.0.0.1:$port/" --token-file "$rt/token" "$@"; }
for _ in $(seq 1 100); do probe --check >/dev/null 2>&1 && break; sleep 0.2; done
probe --check >/dev/null 2>&1 || fail 'the private caboose-display did not answer'
for _ in $(seq 1 50); do grep -q '^CABOOSE_GAME_SOCKET=' "$rt/display.env" 2>/dev/null && break; sleep 0.1; done
grep -q '^CABOOSE_GAME_SOCKET=' "$rt/display.env" || fail 'caboose-display does not offer a game socket'

# Starts the launcher as caboose in the display's launch environment, after any command
# prefix given; $name.pid holds the launcher's process id, which native_fallback keeps.
launch() {
  local name=$1
  shift
  owner sh -c 'echo $$ > "$1"; set -a; . "$2"; set +a; shift 2; exec "$@"' sh "$work/$name.pid" "$rt/display.env" \
    "$@" "$run" "$work/game" > "$work/$name.log" 2>&1 &
  pids+=($!)
  for _ in $(seq 1 50); do [[ -s $work/$name.pid ]] && break; sleep 0.1; done
  [[ -s $work/$name.pid ]] || fail "$name: the launcher did not start"
}
gone() {
  for _ in $(seq 1 "$2"); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; done
  return 1
}
fallback() {
  for _ in $(seq 1 "$1"); do [[ -s $work/fallback.pid ]] && return 0; sleep 0.1; done
  return 1
}

# 1. Handoff.
probe --wasm --json --duration 10 --actions 'wait:1500;close' > "$work/handoff.json" 2> "$work/handoff.err" &
probe_pid=$!
pids+=("$probe_pid")
sleep 1
launch handoff
launcher=$(cat "$work/handoff.pid")
gone "$launcher" 120 || fail "handoff: the launcher still runs after the client closed its window: $(cat "$work/handoff.log")"
wait "$probe_pid" || true
[[ ! -e $work/fallback.pid ]] || fail 'handoff: the native fallback ran although a client played the game'
python3 -I - "$work/handoff.json" "$relative" "$title" <<'PY' || fail "handoff: $(cat "$work/handoff.json" "$work/handoff.err" "$work/handoff.log")"
import json, sys
path, relative, title = sys.argv[1:]
report = json.loads(open(path).read().strip().splitlines()[-1])
games = report['games']
assert len(games) == 1, f'expected one game, got {games}'
game = games[0]
assert game['root'] == f'{relative}/game/web' and game['entry'] == 'index.html', game
assert game['saves'] == [{'mount': '/check', 'path': f'{relative}/saves'}], game
assert game['destroyed'], 'the game was not destroyed when its window closed'
window = next((w for w in report['windows'] if w['id'] == game['window']), None)
assert window, f'game window {game["window"]} was never created'
assert window['title'] == title, window
assert window['frames'] == 0, f'the game window sent {window["frames"]} pictures'
assert window['destroyed'], 'the game window was not destroyed'
PY
echo "handoff: game.create for the launcher's window, no pictures, destroyed on close"

# 2. A client that does not play games.
probe --json --duration 6 > "$work/local.json" 2> "$work/local.err" &
probe_pid=$!
pids+=("$probe_pid")
sleep 1
launch local
fallback 100 || fail "local: native_fallback did not run: $(cat "$work/local.log")"
[[ $(cat "$work/fallback.pid") == $(cat "$work/local.pid") ]] || fail 'local: native_fallback did not replace the launcher'
wait "$probe_pid" || true
python3 -I -c 'import json, sys; r = json.loads(open(sys.argv[1]).read().strip().splitlines()[-1]); assert r["games"] == [], r["games"]' \
  "$work/local.json" || fail "local: a client without wasm was sent a game: $(cat "$work/local.json")"
rm -f "$work/fallback.pid"
echo 'local: native_fallback replaced the launcher'

# 3. No game socket.
launch nosocket env -u CABOOSE_GAME_SOCKET
fallback 50 || fail "no socket: native_fallback did not run: $(cat "$work/nosocket.log")"
[[ $(cat "$work/fallback.pid") == $(cat "$work/nosocket.pid") ]] || fail 'no socket: native_fallback did not replace the launcher'
echo 'no socket: native_fallback replaced the launcher'
echo OK
