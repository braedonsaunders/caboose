#!/bin/sh
# A broker-client compositor draws real pictures with no phone executor serving it.
#
#   sh guest/display/scripts/check-headless-render.sh COMPOSITOR REPO
#
# Run as root inside a computer (for a microVM, through the host's exec route). It starts a
# private agent-seat compositor (COMPOSITOR, the binary under test) as a client of a stand-in
# broker that then reports the executor suspended past its hold (lifecycle record 11), as the
# shared broker does when the phone goes away. The compositor must keep rendering on the
# computer (no phone, no server GPU): a window it shows must screenshot as a real picture.
# The real seats, their broker and the phone are not touched. REPO is a checkout (for the
# control protocol and the test window).
set -eu
ulimit -c 0
[ $# -eq 2 ] || { sed -n '4,12p' "$0" >&2; exit 2; }
compositor=$1
repo=$2
dir=$(mktemp -d /tmp/headless-render.XXXXXX)
mkdir -p "$dir/gpu/agent" "$dir/run" "$dir/home"
chown -R caboose "$dir"
head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$dir/token"
chown caboose "$dir/token"
port=14791; xdisplay=209
cleanup() {
  [ -n "${window:-}" ] && kill "$window" 2>/dev/null || :
  [ -n "${display_pid:-}" ] && kill "$display_pid" 2>/dev/null || :
  [ -n "${broker:-}" ] && kill "$broker" 2>/dev/null || :
  sleep 1; rm -rf "$dir"
}
trap cleanup EXIT INT TERM
fail() { echo "FAIL headless render: $*" >&2; tail -n 20 "$dir/display.log" >&2 2>/dev/null || :; exit 1; }

# The stand-in broker: accepts the compositor at the seat's control socket and, once it has
# drawn on the computer, reports the executor suspended past the hold (record 11).
runuser -u caboose -- env PYTHONPATH="$repo/guest/gpu/gfxstream" python3 -c '
import socket, sys, time, control_protocol as c
path = sys.argv[1]
s = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET); s.bind(path); s.listen(1)
conn, _ = s.accept()
time.sleep(4)
conn.send(c.encode_lifecycle(c.ExecutorLifecycle(11, b"\x01" * 16, 1)))
time.sleep(3600)
' "$dir/gpu/agent/control.sock" > "$dir/broker.log" 2>&1 &
broker=$!
i=0; until [ -S "$dir/gpu/agent/control.sock" ]; do i=$((i + 1)); [ $i -le 50 ] || fail "stand-in broker"; sleep 0.1; done

runuser -u caboose -- env CABOOSE_SEAT=agent HOME="$dir/home" XDG_RUNTIME_DIR="$dir/run" \
  "$compositor" --listen "127.0.0.1:$port" --token-file "$dir/token" --socket wayland-headless \
  --x-display "$xdisplay" --no-audio --no-games --no-devices --env-file "$dir/display.env" \
  --private-gpu-broker "$dir/gpu/agent/control.sock" --private-gpu-stream-socket "$dir/gpu/agent/gpu.sock" \
  --private-gpu-surface-socket "$dir/gpu/agent/surface.sock" --private-gpu-indexed > "$dir/display.log" 2>&1 &
display_pid=$!
i=0; until [ -s "$dir/display.env" ]; do i=$((i + 1)); [ $i -le 150 ] || fail "compositor did not start"; sleep 0.2; done

runuser -u caboose -- env XDG_RUNTIME_DIR="$dir/run" WAYLAND_DISPLAY=wayland-headless GDK_BACKEND=wayland \
  python3 "$repo/guest/display/scripts/focus_check_app.py" "$dir/typed" > "$dir/window.log" 2>&1 &
window=$!

control() {
  runuser -u caboose -- python3 -c '
import socket, sys, json
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall(sys.argv[2].encode() + b"\n")
data = b""
while b"\n" not in data:
    chunk = s.recv(65536)
    if not chunk: break
    data += chunk
head, _, rest = data.partition(b"\n")
answer = json.loads(head)
if "png" in answer:
    need = answer["png"]
    while len(rest) < need:
        chunk = s.recv(1 << 20)
        if not chunk: break
        rest += chunk
    open(sys.argv[3], "wb").write(rest[:need])
print(json.dumps(answer))
' "$dir/run/caboose-display/wayland-headless/control.sock" "$1" "${2:-/dev/null}"
}

# After the suspension report the compositor must still render: wait past it, then shoot.
sleep 8
grep -q "rendering on the computer until it resumes" "$dir/display.log" || fail "no local renderer after the suspension"
answer=$(control screenshot "$dir/shot.png") || fail "screenshot failed"
echo "$answer" | grep -q '"png"' || fail "screenshot answered $answer"
python3 - "$dir/shot.png" <<'PY' || fail "the screenshot is not a real picture"
import sys, zlib, struct
data = open(sys.argv[1], "rb").read()
assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
pos, idat, width, height = 8, b"", 0, 0
while pos < len(data):
    length, kind = struct.unpack(">I4s", data[pos:pos + 8])
    chunk = data[pos + 8:pos + 8 + length]
    if kind == b"IHDR": width, height = struct.unpack(">II", chunk[:8])
    if kind == b"IDAT": idat += chunk
    pos += 12 + length
raw = zlib.decompress(idat)
# A real picture has many distinct byte values; black, blank or a flat fill has a handful.
distinct = len(set(raw))
print(f"screenshot {width}x{height}, {distinct} distinct byte values")
assert width > 0 and height > 0 and distinct > 16
PY
echo "PASS headless render: the agent seat draws on the computer after the executor suspended ($(grep -o 'renderer [0-9]*: [^,]*' "$dir/display.log" | tail -1))"
