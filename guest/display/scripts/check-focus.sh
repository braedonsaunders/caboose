#!/bin/sh
# The keyboard comes back to a window without a click: when it maps, after its popup menu
# (a grab) closes, after its transient dialog closes, and on the control socket's `focus`.
#
#   guest/display/scripts/check-focus.sh CONTROL_SOCKET DISPLAY_ENV [WORK_DIR]
#
# Runs inside a computer as the compositor's user, against a running compositor: its control
# socket and the env file it wrote (--env-file). A GTK 3 window (focus_check_app.py, needs
# python3-gi) writes its entry's text to a file; each step types a letter through the control
# socket and checks the letter arrived. Prints PASS or the first step that lost the keyboard.
set -eu
[ $# -ge 2 ] || { sed -n '2,10p' "$0" >&2; exit 2; }
sock=$1; envfile=$2; work=${3:-$(mktemp -d)}
here=$(cd "$(dirname "$0")" && pwd)
out=$work/focus-check.txt
: > "$out"
ctl() {
  python3 -c 'import socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall((" ".join(sys.argv[2:]) + "\n").encode())
b = b""
while not b.endswith(b"\n"):
    d = s.recv(65536)
    if not d: break
    b += d
sys.stdout.write(b.decode())' "$sock" "$@"
}
window() {  # the id of the window titled $1
  ctl windows | python3 -c 'import json, sys
ws = [w["id"] for w in json.load(sys.stdin)["windows"] if w["title"] == sys.argv[1]]
print(ws[0] if ws else "")' "$1"
}
( set -a; . "$envfile"; set +a; GDK_BACKEND=wayland exec python3 "$here/focus_check_app.py" "$out" ) > "$work/focus-check-app.log" 2>&1 &
app=$!
trap 'kill $app 2>/dev/null || true' EXIT INT TERM
i=0; until [ -n "$(window focus-check)" ]; do i=$((i + 1)); [ $i -le 100 ] || { echo "FAIL: the window never appeared"; exit 1; }; sleep 0.1; done
id=$(window focus-check)
sleep 1
expect=""
step() {  # type letter $2 after step $1 and check it arrived
  ctl type "$2" > /dev/null; expect=$expect$2
  i=0; until [ "$(cat "$out")" = "$expect" ]; do i=$((i + 1)); [ $i -le 30 ] || { echo "FAIL: $1: typed '$2', the window has '$(cat "$out")'"; exit 1; }; sleep 0.1; done
  echo "ok $1"
}
step "mapped" a
rect=$(ctl windows | python3 -c 'import json, sys
w = [w for w in json.load(sys.stdin)["windows"] if w["id"] == int(sys.argv[1])][0]
x, y, ww, hh = w["rect"]; print(x + ww // 2, y + hh // 2)' "$id")
ctl click $rect right > /dev/null
i=0; until ctl windows | grep -q '"kind":"popup"'; do i=$((i + 1)); [ $i -le 50 ] || { echo "FAIL: the context menu never opened"; exit 1; }; sleep 0.1; done
ctl key Escape > /dev/null
i=0; while ctl windows | grep -q '"kind":"popup"'; do i=$((i + 1)); [ $i -le 50 ] || { echo "FAIL: the context menu never closed"; exit 1; }; sleep 0.1; done
step "popup menu closed" b
ctl key F2 > /dev/null
i=0; until [ -n "$(window focus-check-dialog)" ]; do i=$((i + 1)); [ $i -le 50 ] || { echo "FAIL: the dialog never opened"; exit 1; }; sleep 0.1; done
i=0; while [ -n "$(window focus-check-dialog)" ]; do i=$((i + 1)); [ $i -le 50 ] || { echo "FAIL: the dialog never closed"; exit 1; }; sleep 0.1; done
step "transient dialog closed" c
ctl focus "$id" > /dev/null
step "focused again" d
echo PASS
