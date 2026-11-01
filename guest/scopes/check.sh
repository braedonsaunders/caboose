#!/bin/bash
# The live check for app scopes against a running container computer (README.md, Tests).
#
#   guest/scopes/check.sh CONTAINER [--window]
#
# Runs on the computer's Docker host. Starts its own processes only, as the owner, and ends
# them; --window also opens a small GTK window on the owner's display for a few seconds.
set -euo pipefail
container=${1:?usage: check.sh CONTAINER [--window]}
window=${2:-}
started=()

in_guest() { docker exec "$container" "$@"; }
owner() { docker exec -u caboose "$container" "$@"; }
scopes() { in_guest /usr/local/bin/caboose-scopes "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }
# EXPR (Python, over `app`) for the newest listed app whose name or desktop id is NAME.
app() {
  scopes list | python3 -c '
import json, sys
answer = json.load(sys.stdin)
assert answer["ok"], answer
apps = [a for a in answer["result"]["apps"] if a["name"] == sys.argv[1] or a["desktopId"] == sys.argv[1]]
app = apps[-1] if apps else None
print(eval(sys.argv[2]) if app else "")' "$1" "$2"
}
# Waits up to 10 s for `app NAME EXPR` to print something other than empty.
wait_app() {
  local value=
  for _ in $(seq 1 20); do
    value=$(app "$1" "$2")
    [ -n "$value" ] && { printf '%s\n' "$value"; return 0; }
    sleep 0.5
  done
  return 1
}
cleanup() {
  for scope in "${started[@]}"; do scopes kill "$scope" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

# 1. The hierarchy and the daemon.
in_guest grep -q ' /sys/fs/cgroup cgroup2 rw,' /proc/self/mounts || fail 'the cgroup tree is not writable'
[ "$(in_guest cat /proc/self/cgroup)" = '0::/init.scope' ] || fail 'docker exec does not land in /init.scope'
[ -z "$(in_guest cat /sys/fs/cgroup/cgroup.procs)" ] || fail 'the namespace root still has processes'
in_guest grep -qw memory /sys/fs/cgroup/owner.slice/cgroup.subtree_control || fail 'no memory accounting for apps'
scopes list | grep -q '"ok":true' || fail 'caboose-scopes list failed'
pass 'hierarchy and daemon'

# 2. A scoped process tree, including a child that double-forks away from its parent.
owner /usr/local/bin/caboose-scopes run caboose-check.desktop -- /bin/sh -c 'setsid sh -c "sleep 600 &"; exec sleep 601' >/dev/null &
scope=$(wait_app caboose-check.desktop 'app["id"] if app["processCount"] >= 2 else ""') || fail 'the scoped tree did not appear'
started+=("$scope")
[[ "$scope" == 'app-caboose\x2dcheck-'*'.scope' ]] || fail "unexpected scope name $scope"
commands=$(app caboose-check.desktop '" ".join(p["command"] for p in app["processes"])')
[[ "$commands" == *'sleep 600'* && "$commands" == *'sleep 601'* ]] || fail "the double-forked child escaped: $commands"
pass "scoped tree in $scope"

# 3. A fake Steam reaper (argv[0] `reaper`, `SteamLaunch AppId=N`) under a launcher is split
#    into its game's scope with its tree; the launcher keeps its own scope.
owner /usr/local/bin/caboose-scopes run caboose-steam-check.desktop -- /usr/bin/python3 -c '
import subprocess, time
subprocess.Popen(["/tmp/reaper", "-c", "sleep 602 & wait", "SteamLaunch", "AppId=999999", "--"], executable="/bin/sh")
time.sleep(600)' >/dev/null &
game=$(wait_app 'Steam game 999999' 'app["id"] if app["origin"] == "game" and app["processCount"] >= 2 else ""') || fail 'the game was not split off'
launcher=$(wait_app caboose-steam-check.desktop 'app["id"]') || fail 'the launcher lost its scope'
started+=("$game" "$launcher")
[[ "$(app caboose-steam-check.desktop '" ".join(p["command"] for p in app["processes"])')" != *'sleep 602'* ]] ||
  fail 'the game tree stayed with its launcher'
pass "game split into $game"

# 4. Force Quit ends a tree on SIGTERM.
answer=$(scopes force-quit "$scope")
[[ "$answer" == *'"ended":true'* && "$answer" == *'"killed":false'* ]] || fail "force quit: $answer"
pass 'force quit (SIGTERM)'

# 5. Force Quit kills a tree that ignores SIGTERM, after the grace period.
owner /usr/local/bin/caboose-scopes run caboose-stubborn.desktop -- /usr/bin/python3 -c '
import signal, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
time.sleep(600)' >/dev/null &
stubborn=$(wait_app caboose-stubborn.desktop 'app["id"]') || fail 'the stubborn app did not appear'
started+=("$stubborn")
answer=$(scopes force-quit "$stubborn")
[[ "$answer" == *'"ended":true'* && "$answer" == *'"killed":true'* ]] || fail "force quit (kill): $answer"
pass 'force quit (SIGKILL after the grace period)'

# 6. Kill ends everything at once; the session scope cannot be ended.
answer=$(scopes kill "$game")
[[ "$answer" == *'"ended":true'* ]] || fail "kill: $answer"
pass 'kill'
answer=$(scopes kill session.scope)
[[ "$answer" == *'"error":"forbidden"'* ]] || fail "the session scope was not refused: $answer"
pass 'session scope refused'

# 7. With --window: a window opened outside any app gets a scope; Quit closes it politely.
if [ "$window" = --window ]; then
  env=$(in_guest cat /run/caboose/display.env | sed -n "s/^\(WAYLAND_DISPLAY\|DISPLAY\|XAUTHORITY\|XDG_RUNTIME_DIR\|GDK_BACKEND\)='\(.*\)'$/\1=\2/p")
  vars=()
  while IFS= read -r line; do [ -n "$line" ] && vars+=(-e "$line"); done <<< "$env"
  docker exec -u caboose "${vars[@]}" "$container" /usr/bin/python3 -c '
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk
GLib.set_prgname("caboose-scopes-check")
window = Gtk.Window(title="Caboose scopes check")
window.set_wmclass("caboose-scopes-check", "caboose-scopes-check")
window.connect("delete-event", lambda *a: Gtk.main_quit())
window.show_all()
Gtk.main()' >/dev/null 2>&1 &
  windowed=$(wait_app caboose-scopes-check 'app["id"] if app["windows"] else ""') || fail 'the window did not get a scope with its window'
  started+=("$windowed")
  answer=$(scopes quit "$windowed")
  [[ "$answer" == *'"closed":1'* ]] || fail "quit: $answer"
  for _ in $(seq 1 20); do [ -z "$(app caboose-scopes-check 'app["id"]')" ] && break; sleep 0.5; done
  [ -z "$(app caboose-scopes-check 'app["id"]')" ] || fail 'the window app did not quit'
  pass "window scope $windowed quit politely"
fi
echo 'All checks passed.'
