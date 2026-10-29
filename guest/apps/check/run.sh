#!/bin/bash
# The caboose-app runtime check: a real WebKitGTK window on a private Xvfb display, driven by
# the probe app beside this file. Run as root, in the test container (../check-runtime.sh)
# or inside a Caboose computer from a copy of guest/apps:
#
#   sudo bash guest/apps/check/run.sh
#
# It uses the checkout's caboose-app, a throwaway home owned by caboose, display :150 and
# its own session bus, so it touches neither the owner's apps nor their displays. Prints
# PASS/FAIL per assertion and exits 1 if any failed.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
runtime="$here/../caboose-app"
failures=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s: %s\n' "$1" "$2"; failures=$((failures + 1)); }
check() { local name=$1; shift; if "$@"; then pass "$name"; else fail "$name" "${detail:-assertion failed}"; fi; detail=; }
detail=

home=$(mktemp -d /tmp/caboose-app-check.XXXXXX)
chown caboose:caboose "$home"
bus="$home/bus"
Xvfb :150 -screen 0 1280x800x24 -nolisten tcp >"$home/xvfb.log" 2>&1 &
xvfb=$!
runuser -u caboose -- dbus-daemon --session --address="unix:path=$bus" --fork --print-pid >"$home/dbus.pid"
app_pid=
cleanup() {
  [[ -n $app_pid ]] && kill "$app_pid" 2>/dev/null
  kill "$(cat "$home/dbus.pid")" "$xvfb" 2>/dev/null
  pkill -f 'caboose-check-sleeper' 2>/dev/null
  rm -rf "$home"
}
trap cleanup EXIT
as_user() {
  runuser -u caboose -- env -i HOME="$home" PATH=/usr/local/bin:/usr/bin:/bin DISPLAY=:150 \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" XDG_RUNTIME_DIR="$home" "$@"
}
# py EXPR FILE: evaluate a Python expression over the JSON in FILE (as d); prints yes/no for booleans.
py() { python3 -c "import json, sys; d = json.load(open(sys.argv[1])); r = ($1); print(r if not isinstance(r, bool) else ('yes' if r else 'no'))" "$2"; }
yes() { [[ $1 == yes ]]; }
wait_file() { for _ in $(seq 1 300); do [[ -s $1 ]] && return 0; sleep 0.1; done; return 1; }
running() { pgrep -f "^caboose-check-sleeper-$1" >/dev/null; }
gone() { for _ in $(seq 1 60); do running "$1" || return 0; sleep 0.1; done; return 1; }
sleep 1

echo '== publish'
install -d -o caboose -g caboose "$home/Apps"
cp -R "$here/probe" "$home/Apps/runtime-check"
chown -R caboose:caboose "$home/Apps"
as_user python3 "$runtime" publish runtime-check >"$home/publish.json"
check 'publish succeeds' yes "$(py "d['ok'] and d['published']" "$home/publish.json")"
entry="$home/.local/share/applications/caboose.app.runtime-check.desktop"
check 'desktop entry written' grep -qx 'Exec=/usr/local/bin/caboose-app run runtime-check' "$entry"
check 'generated icon' test -s "$home/.local/share/caboose/apps/runtime-check/icon.svg"
printf '<script>inline()</script>' >"$home/Apps/runtime-check/bad.html"
as_user python3 "$runtime" check runtime-check >"$home/bad.json"
check 'inline script refused at check' yes "$(py "not d['ok'] and 'bad.html line 1: an inline <script>' in d['errors'][0]" "$home/bad.json")"
rm "$home/Apps/runtime-check/bad.html"

echo '== first load'
files="$home/.local/share/caboose/apps/runtime-check/files"
as_user python3 "$runtime" run runtime-check >"$home/run.log" 2>&1 &
app_pid=$!
if ! wait_file "$files/probe-1.json"; then
  fail 'probe ran' "no probe-1.json after 30 s; $(tail -5 "$home/run.log" "$home/.local/share/caboose/apps/runtime-check/console.log" 2>&1)"
  exit 1
fi
probe="$files/probe-1.json"
check 'bridge present in the top frame' yes "$(py "d['app'] == 'runtime-check'" "$probe")"
detail="$(py "d['ran']" "$probe")"
check 'inline, data:, blob:, eval and Function script blocked' yes "$(py "not any(d['ran'].values())" "$probe")"
detail="$(py "d['violations']" "$probe")"
check 'policy reports script and frame violations' yes "$(py "'script-src-elem' in d['violations'] or 'script-src' in d['violations']" "$probe")"
check 'remote frame blocked' yes "$(py "'frame-src' in d['violations']" "$probe")"
detail="$(py "d['exec']" "$probe")"
check 'exec returns code, stdout, stderr' yes "$(py "d['exec']['code'] == 3 and d['exec']['stdout'] == 'hello' and d['exec']['stderr'] == 'err'" "$probe")"
check 'exec timeout kills' yes "$(py "d['timeout']['timedOut'] and d['timeout']['signal'] == 'KILL'" "$probe")"
check 'argv must be a list' yes "$(py "'argv must be a list' in d['badArgv']" "$probe")"
check 'undeclared capability refused' yes "$(py "'does not declare the \"notify\" capability' in d['undeclared']" "$probe")"
check 'files round trip' yes "$(py "d['files'] == {'a': 1}" "$probe")"
check 'files outside the home refused' yes "$(py "'must be inside' in d['outside']" "$probe")"
check 'spawn streams output and exit' yes "$(py "d['stream'] == {'code': 0, 'signal': None, 'out': 'one\\ntwo\\n'}" "$probe")"
check 'script navigation away refused' yes "$(py "d['stayed']" "$probe")"
check 'frame request ignored' test ! -e "$files/frame-mark"
check 'console log written' test -f "$home/.local/share/caboose/apps/runtime-check/console.log"
check 'sleeper of load 1 running' running 1

echo '== live reload'
printf "\n" >>"$home/Apps/runtime-check/index.html"
check 'reloads after an edit' wait_file "$files/probe-2.json"
check 'storage survives a reload' yes "$(py "d['load'] == 2" "$files/probe-2.json")"
check 'old page program ended' gone 1
check 'new page program running' running 2

echo '== single instance, shutdown, restart'
as_user python3 "$runtime" run runtime-check >>"$home/run.log" 2>&1
check 'second launch hands over to the first' kill -0 "$app_pid"
kill "$app_pid"
wait "$app_pid" 2>/dev/null
app_pid=
check 'programs end with the app' gone 2
as_user python3 "$runtime" run runtime-check >>"$home/run.log" 2>&1 &
app_pid=$!
check 'restarts' wait_file "$files/probe-3.json"
check 'storage survives a restart' yes "$(py "d['load'] == 3" "$files/probe-3.json")"

echo "== $failures failed"
((failures == 0))
