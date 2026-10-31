#!/bin/bash
# Routing check for the seat that renders on the phone's GPU (docs/gpu-live.md,
# "Applications"): every GPU toolkit an application uses reaches the phone's driver, and
# each still draws on the computer when no phone answers.
#
#   guest/gpu/check-apps.sh IMAGE BIN DRIVER [OUT]
#       in a disposable container of the computer image IMAGE, with caboose-display and
#       caboose-display-probe from BIN (this branch's release build, target/release) and
#       the built driver DRIVER (libvulkan_gfxstream.so); leaves each application's log
#       and the socket record in OUT (default guest/gpu/out/apps)
#   bash guest/gpu/check-apps.sh --here [OUT]
#       as root where all of that is installed
#
# A private caboose-display is started as the owner's seat with private GPU sockets and
# watched by caboose-display-probe as its client (windows draw only while one is), and
# socket-recorder.py stands in for the broker there: it records the process that opens a
# socket and closes it, as the broker closes a connection when no phone is attached. For
# each application the check asserts that the Vulkan loader loaded the driver from
# caboose-display's launch environment, that the application's own process opened the
# broker's socket, and that the application then ran on the computer's drivers. Whether
# a phone renders what arrives is the phone trial's to show.
#
# The image needs vulkan-tools, mesa-utils, gtk-4-examples and qml-qt6 besides what the
# computer image carries. CABOOSE_CHECK_CPUS and CABOOSE_CHECK_MEMORY (default 4 and 4g)
# bound the container.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)

if [[ ${1:-} != --here ]]; then
  [[ $# -ge 3 ]] || { sed -n '6,13p' "$0" >&2; exit 2; }
  image=$1 bin=$(realpath "$2") driver=$(realpath "$3")
  out=$(mkdir -p "${4:-$here/out/apps}" && cd "${4:-$here/out/apps}" && pwd)
  # The computer's own seccomp policy, which Chromium's sandbox needs, and this branch's
  # Chromium flags and policy.
  exec docker run --rm -i --init --network none --cpus "${CABOOSE_CHECK_CPUS:-4}" --memory "${CABOOSE_CHECK_MEMORY:-4g}" \
    --security-opt seccomp="$here/../container/caboose-seccomp.json" \
    -v "$here/../container/chromium-gpu:/etc/chromium.d/caboose-gpu:ro" \
    -v "$here/../container/chromium-policy.json:/etc/chromium/policies/managed/caboose-gpu.json:ro" \
    -v "$here:/gpu:ro" -v "$bin/caboose-display:/usr/local/bin/caboose-display:ro" \
    -v "$bin/caboose-display-probe:/usr/local/bin/caboose-display-probe:ro" -v "$driver:/check/libvulkan_gfxstream.so:ro" \
    -v "$out:/out" "$image" bash -c \
    'python3 /gpu/install-live.py --source-root /gpu --driver /check/libvulkan_gfxstream.so && bash /gpu/check-apps.sh --here /out'
fi

out=${2:-/tmp/caboose-gpu-apps}
icd=/usr/local/lib/caboose-gpu-live/icd.json
fail() { echo "FAIL: $*" >&2; [[ -f $out/display.log ]] && tail -n 20 "$out/display.log" >&2; exit 1; }
[[ $(id -u) == 0 ]] || fail 'run as root'
for command in caboose-display caboose-display-probe vkcube glxinfo eglinfo gtk4-widget-factory qml6 chromium \
  /usr/share/code/code; do
  command -v "$command" >/dev/null || fail "$command is missing"
done
[[ -f $icd ]] || fail "no driver at $icd"
owner() { runuser -u caboose -- "$@"; }
mkdir -p "$out" && chown caboose: "$out"

pids=()
cleanup() { for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done; wait 2>/dev/null || true; }
trap cleanup EXIT

rt=/run/user/1000
install -d -o caboose -g caboose -m 0700 "$rt" "$rt/caboose-gpu-check"
gpu=$rt/caboose-gpu-check
owner sh -c 'umask 077; od -An -N16 -tx1 /dev/urandom | tr -d " \n" > "$1/token"' sh "$gpu"
owner env HOME=/home/caboose XDG_RUNTIME_DIR="$rt" CABOOSE_DISPLAY_LOG=info caboose-display \
  --listen 127.0.0.1:14690 --token-file "$gpu/token" --socket wayland-caboose-check --x-display 140 \
  --no-audio --env-file "$out/display.env" \
  --private-gpu-stream-socket "$gpu/gpu.sock" --private-gpu-surface-socket "$gpu/surface.sock" --private-gpu-indexed \
  > "$out/display.log" 2>&1 &
pids+=($!)
for _ in $(seq 1 150); do grep -q '^DISPLAY=' "$out/display.env" 2>/dev/null && break; sleep 0.2; done
grep -q '^DISPLAY=' "$out/display.env" || fail 'caboose-display did not become ready'
owner caboose-display-probe --url ws://127.0.0.1:14690/ --token-file "$gpu/token" --duration 900 --json \
  > "$out/probe.json" 2> "$out/probe.log" &
pids+=($!)

# The launch environment names the driver and the broker's sockets, and leaves Mesa free
# to choose Zink.
control=$(sed -n "s/^CABOOSE_DISPLAY_CONTROL='\(.*\)'$/\1/p" "$out/display.env")
[[ -S $control ]] || fail 'no control socket'
expect_env() { grep -qx "$1='$2'" "$out/display.env" || fail "launch environment lacks $1='$2'"; }
expect_env VK_ADD_DRIVER_FILES "$icd"
expect_env CABOOSE_GFXSTREAM_SOCKET "$gpu/gpu.sock"
expect_env CABOOSE_GFXSTREAM_SURFACE_SOCKET "$gpu/surface.sock"
expect_env LIBGL_KOPPER_DRI2 1
expect_env GSK_RENDERER vulkan
! grep -q '^GALLIUM_DRIVER=' "$out/display.env" || fail 'launch environment selects a Gallium driver'

# No phone: nothing listens, and every toolkit draws on the computer as before.
owner sh -c 'set -a; . "$1"; exec glxinfo -B' sh "$out/display.env" > "$out/no-phone-glxinfo.log" 2>&1 ||
  fail 'OpenGL without a phone'
grep -q 'OpenGL renderer string: llvmpipe' "$out/no-phone-glxinfo.log" || fail 'OpenGL without a phone is not llvmpipe'

# The broker's sockets, standing in for an attached phone.
records=$out/sockets.jsonl
: > "$records"; chown caboose: "$records"
owner python3 "$here/socket-recorder.py" "$gpu/gpu.sock" "$gpu/surface.sock" "$records" &
pids+=($!)
for _ in $(seq 1 50); do [[ -S $gpu/gpu.sock && -S $gpu/surface.sock ]] && break; sleep 0.1; done
[[ -S $gpu/gpu.sock ]] || fail 'socket recorder did not start'

# app NAME SECONDS PATTERN [--window[=WINDOW]] COMMAND...: runs COMMAND as the owner with
# the seat's launch environment for at most SECONDS. A process whose command line matches
# PATTERN must have opened the broker's socket, and COMMAND must have run on: exited 0, or
# still running and, with --window, showing a window with a picture drawn in it, of a
# process whose command line matches WINDOW (default PATTERN).
app() {
  local name=$1 seconds=$2 pattern=$3 window=0 shown=$3 pid status=0
  shift 3
  case $1 in --window) window=1; shift ;; --window=*) window=1 shown=${1#--window=}; shift ;; esac
  : > "$records"
  # A session bus of its own, as every seat has one: GTK waits for it.
  owner sh -c 'set -a; . "$1"; set +a; export VK_LOADER_DEBUG=driver LANG=C.UTF-8; shift; exec dbus-run-session -- "$@"' \
    sh "$out/display.env" "$@" > "$out/$name.log" 2>&1 &
  pid=$!
  pids+=("$pid")
  for _ in $(seq 1 "$((seconds * 10))"); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$pid" 2>/dev/null; then
    if ((window)); then
      owner python3 - "$control" "$shown" "$out/$name.png" <<'PY' || fail "$name: no window with a picture"
import json, re, socket, sys, time, zlib
control, pattern, png_out = sys.argv[1:]

def ask(request):
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(10)
        s.connect(control)
        s.sendall(request.encode() + b'\n')
        data = b''
        while b'\n' not in data:
            data += s.recv(65536)
        head, rest = data.split(b'\n', 1)
        reply = json.loads(head)
        while len(rest) < reply.get('png', 0):
            rest += s.recv(1 << 20)
        return reply, rest

def cmdline(pid):
    try:
        return open(f'/proc/{pid}/cmdline', 'rb').read().replace(b'\0', b' ').decode()
    except OSError:
        return ''


def drawn(png):
    # The decoded rows of an undrawn (uniform) window are almost one byte value.
    at, raw = 8, b''
    while at < len(png):
        length = int.from_bytes(png[at:at + 4], 'big')
        if png[at + 4:at + 8] == b'IDAT':
            raw += png[at + 8:at + 8 + length]
        at += 12 + length
    return len(set(zlib.decompress(raw)))

# A picture can lag the window; look for ten seconds.
for _ in range(20):
    # An X11 window without _NET_WM_PID is matched by its title.
    windows = [w for w in ask('windows')[0]['windows']
               if re.search(pattern, cmdline(w['pid']) if w['pid'] else w['title'])]
    if windows:
        png = ask(f"screenshot {windows[0]['id']}")[1]
        values = drawn(png)
        if values >= 16:
            open(png_out, 'wb').write(png)
            print(f"window {windows[0]['id']} {windows[0]['rect'][2]}x{windows[0]['rect'][3]}, {values} byte values")
            sys.exit(0)
    time.sleep(0.5)
sys.exit('no window' if not windows else f'window {windows[0]["id"]} shows no picture')
PY
    fi
    pkill -TERM -P "$pid" 2>/dev/null || true; kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  else
    wait "$pid" || status=$?
    [[ $status == 0 ]] || { tail -n 15 "$out/$name.log" >&2; fail "$name exited with $status"; }
    ((!window)) || fail "$name exited before showing its window"
  fi
  grep -q "caboose-gpu-live/icd.json" "$out/$name.log" || fail "$name: the Vulkan loader did not load the driver"
  python3 - "$records" "$pattern" "$name" <<'PY' || fail "$name: no process matching '$pattern' opened the broker's socket"
import json, re, sys
records = [json.loads(line) for line in open(sys.argv[1])]
hits = [r for r in records if re.search(sys.argv[2], r['cmdline']) and r['socket'] == 'gpu.sock' and r['hello']]
for r in hits[:1]:
    print(f"{sys.argv[3]}: pid {r['pid']} ({r['comm']}) opened gpu.sock, hello {r['hello']}")
sys.exit(0 if hits else 1)
PY
}

app vulkan-wayland 30 '^vkcube' vkcube --wsi wayland --c 120
app vulkan-x11 30 '^vkcube' vkcube --wsi xcb --c 120
app opengl-gears 10 '^glxgears' --window glxgears
app opengl-glx 20 '^glxinfo' glxinfo -B
grep -q 'OpenGL renderer string: llvmpipe' "$out/opengl-glx.log" || fail 'GLX did not fall back to llvmpipe'
app opengl-egl-x11 20 '^eglinfo' eglinfo -p x11
# The image's WhiteSur theme takes GTK half a minute to load on a busy computer.
app gtk4 30 '^gtk4-widget-factory' --window env GTK_THEME=Adwaita gtk4-widget-factory
cat > "$out/scene.qml" <<'QML'
import QtQuick
import QtQuick.Window
Window {
    visible: true; width: 320; height: 240; title: "Qt Quick check"
    Rectangle {
        anchors.fill: parent
        gradient: Gradient { GradientStop { position: 0; color: "steelblue" } GradientStop { position: 1; color: "gold" } }
        Text { anchors.centerIn: parent; text: "Caboose"; font.pixelSize: 48 }
    }
}
QML
app qt-quick 20 '^qml6' --window env QSG_INFO=1 qml6 "$out/scene.qml"
app chromium 40 'type=gpu-process' --window='^/usr/lib/chromium/chromium (?!.*--type=)' chromium --user-data-dir="$out/chromium" --no-first-run --no-default-browser-check about:blank
# Electron, here Visual Studio Code: an X11 client whose ANGLE draws with OpenGL, so Zink.
app electron 40 'type=gpu-process' --window='^/usr/share/code/code (?!.*--type=)' \
  /usr/share/code/code --user-data-dir="$out/code" --disable-workspace-trust
echo "PASS: every toolkit reached the phone's driver and ran on without a phone; records in $records"
