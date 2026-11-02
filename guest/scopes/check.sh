#!/bin/bash
# The live check for app scopes against a running container computer (README.md, Tests).
#
#   guest/scopes/check.sh CONTAINER [--window]
#
# Runs on the computer's Docker host. Starts its own processes only, as the owner, and ends
# them; --window also opens small GTK windows on the owner's display for a few seconds.
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
services=()
cleanup() {
  for scope in "${started[@]}"; do scopes kill "$scope" >/dev/null 2>&1 || true; done
  for service in "${services[@]}"; do scopes service-delete "$service" >/dev/null 2>&1 || true; done
}
# A field of a service's status: `service NAME EXPR`, EXPR over `service`.
service() {
  scopes list | python3 -c '
import json, sys
answer = json.load(sys.stdin)
found = [s for s in answer["result"]["services"] if s["name"] == sys.argv[1]]
service = found[0] if found else None
print(eval(sys.argv[2]) if service else "")' "$1" "$2"
}
wait_service() {
  for _ in $(seq 1 40); do [ "$(service "$1" "$2")" = "$3" ] && return 0; sleep 0.5; done
  return 1
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
owner /usr/local/bin/caboose-scopes run caboose-kill-check.desktop -- /bin/sh -c 'sleep 602 & exec sleep 603' >/dev/null &
killed=$(wait_app caboose-kill-check.desktop 'app["id"] if app["processCount"] >= 2 else ""') || fail 'the app to kill did not appear'
started+=("$killed")
answer=$(scopes kill "$killed")
[[ "$answer" == *'"ended":true'* ]] || fail "kill: $answer"
pass 'kill'
answer=$(scopes kill session.scope)
[[ "$answer" == *'"error":"forbidden"'* ]] || fail "the session scope was not refused: $answer"
pass 'session scope refused'

# 7. Services: an owner service starts in its cgroup, is restarted when it dies, listens
#    where activity can see it, stops; one that keeps failing stops being restarted.
services+=(caboose-check-http caboose-check-fail)
answer=$(scopes service-put caboose-check-http '{"command":["python3","-m","http.server","18765","--bind","0.0.0.0"],"restart":"always","autostart":false}')
[[ "$answer" == *'"state":"inactive"'* ]] || fail "service-put: $answer"
scopes service start caboose-check-http | grep -q '"state":"active"' || fail 'the service did not start'
wait_service caboose-check-http 'service["processCount"]' 1 || fail 'the service has no process in its cgroup'
[ -n "$(in_guest cat /sys/fs/cgroup/services.slice/caboose-check-http.service/cgroup.procs)" ] || fail 'no services cgroup'
for _ in $(seq 1 20); do
  scopes activity | grep -q '"port":18765,"pid":[0-9]*,"owner":"caboose-check-http.service"' && break; sleep 0.5
done
scopes activity | grep -q '"port":18765,"pid":[0-9]*,"owner":"caboose-check-http.service"' || fail 'activity does not show the listener'
pid=$(service caboose-check-http 'service["processes"][0]["pid"]')
in_guest kill -9 "$pid"
wait_service caboose-check-http 'service["restarts"] >= 1 and service["state"] == "active"' True || fail 'the service was not restarted'
scopes service stop caboose-check-http | grep -q '"state":"inactive"' || fail 'the service did not stop'
scopes logs caboose-check-http 20 | grep -q 'starting python3 -m http.server' || fail 'no service log'
pass 'service start, restart, listener, stop and log'
scopes service-put caboose-check-fail '{"command":["/bin/false"],"autostart":false}' >/dev/null
scopes service start caboose-check-fail >/dev/null
wait_service caboose-check-fail 'service["state"]' failed || fail 'a crash-looping service was not failed'
pass "a crash loop fails: $(service caboose-check-fail 'service["error"]')"

# 8. With --window: a window opened outside any app gets a scope; Quit closes it politely.
#    An app that opens a window and starts a second application with a window of another
#    class keeps its scope; the second leaves it for one of its own.
if [ "$window" = --window ]; then
  env=$(in_guest cat /run/caboose/display.env | sed -n "s/^\(WAYLAND_DISPLAY\|DISPLAY\|XAUTHORITY\|XDG_RUNTIME_DIR\|GDK_BACKEND\)='\(.*\)'$/\1=\2/p")
  vars=()
  while IFS= read -r line; do [ -n "$line" ] && vars+=(-e "$line"); done <<< "$env"
  gtk_window='
import sys, gi
gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk
GLib.set_prgname(sys.argv[1])
window = Gtk.Window(title="Caboose scopes check")
window.set_wmclass(sys.argv[1], sys.argv[1])
window.connect("delete-event", lambda *a: Gtk.main_quit())
window.show_all()
if len(sys.argv) > 2:
    import subprocess
    subprocess.Popen([sys.executable, "-c", sys.argv[2], sys.argv[3]])
Gtk.main()'
  docker exec -u caboose "${vars[@]}" "$container" /usr/bin/python3 -c "$gtk_window" caboose-scopes-check >/dev/null 2>&1 &
  windowed=$(wait_app caboose-scopes-check 'app["id"] if app["windows"] else ""') || fail 'the window did not get a scope with its window'
  started+=("$windowed")
  answer=$(scopes quit "$windowed")
  [[ "$answer" == *'"closed":1'* ]] || fail "quit: $answer"
  for _ in $(seq 1 20); do [ -z "$(app caboose-scopes-check 'app["id"]')" ] && break; sleep 0.5; done
  [ -z "$(app caboose-scopes-check 'app["id"]')" ] || fail 'the window app did not quit'
  pass "window scope $windowed quit politely"

  docker exec -u caboose "${vars[@]}" "$container" /usr/local/bin/caboose-scopes run caboose-launcher-check.desktop -- \
    /usr/bin/python3 -c "$gtk_window" caboose-launcher-check "$gtk_window" caboose-launched-check >/dev/null 2>&1 &
  launched=$(wait_app caboose-launched-check 'app["id"] if app["origin"] == "window" and app["windows"] else ""') ||
    fail 'the launched application was not split off'
  launcher=$(wait_app caboose-launcher-check.desktop 'app["id"] if app["windows"] else ""') || fail 'the launcher lost its scope'
  started+=("$launched" "$launcher")
  [ "$(app caboose-launcher-check.desktop 'app["processCount"]')" = 1 ] || fail 'the launched application stayed with its launcher'
  pass "launched application split into $launched, launcher kept $launcher"
fi
echo 'All checks passed.'
