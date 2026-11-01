#!/bin/sh
# Records real applications with the cairo recorder and replays what it recorded.
#
#   guest/draw/tests/check.sh [gtk3|writer]...
#
# Each application runs under a headless Weston with libcaboose-draw-cairo.so preloaded,
# capturing its draw lists and, at every commit, the pixels it really drew. The capture is
# replayed with cairo at 1x and compared with those pixels (same rasterizer, so what differs
# is what the recording missed), then at 3x to PNGs. Needs weston, python3-gi with GTK 3,
# python3-cairo, and for `writer` libreoffice-writer and libreoffice-gtk3. Without Weston it runs
# caboose-display from $CABOOSE_DISPLAY_BIN as the compositor. CABOOSE_DRAW_BIN names a directory
# with the recorder and replayer already built, for hosts without a compiler.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'kill $weston 2>/dev/null || true; rm -rf "$work/xdg"' EXIT
if [ -n "${CABOOSE_DRAW_BIN:-}" ]; then mkdir -p "$work/bin" && cp "$CABOOSE_DRAW_BIN"/* "$work/bin/"; else "$here/build.sh" "$work/bin" >/dev/null; fi
export XDG_RUNTIME_DIR="$work/xdg"
mkdir -m 700 "$XDG_RUNTIME_DIR"
if command -v weston >/dev/null; then
  weston --backend=headless --socket=wl-draw-check --idle-time=0 --width=1200 --height=1600 >"$work/server.log" 2>&1 &
else
  # caboose-display serves as the headless compositor where Weston is not installed.
  "${CABOOSE_DISPLAY_BIN:?neither weston nor CABOOSE_DISPLAY_BIN}/caboose-display" --no-auth --x-display 120 --no-audio \
    --no-games --no-devices --listen 127.0.0.1:14690 --socket wl-draw-check >"$work/server.log" 2>&1 &
  export DISPLAY=:120 XAUTHORITY="$XDG_RUNTIME_DIR/caboose-display/wl-draw-check/Xauthority"
fi
weston=$!
for _ in $(seq 100); do [ -S "$XDG_RUNTIME_DIR/wl-draw-check" ] && break; sleep 0.1; done
sleep 2 # Xwayland, when the compositor runs it
export WAYLAND_DISPLAY=wl-draw-check GDK_BACKEND=wayland NO_AT_BRIDGE=1

run() {
  name=$1; shift
  mkdir -p "$work/$name"
  CABOOSE_DRAW_CAPTURE="$work/$name/capture-%p.cdl" CABOOSE_DRAW_PIXELS=1 \
    LD_PRELOAD="$work/bin/libcaboose-draw-cairo.so" "$@" >"$work/$name/app.log" 2>&1 || true
  # One capture per process; helpers that never drew leave theirs empty.
  find "$work/$name" -name 'capture-*.cdl' -size 0 -delete
  set -- "$work/$name"/capture-*.cdl
  if [ ! -s "$1" ]; then echo "$name: nothing recorded"; cat "$work/$name/app.log"; return 1; fi
  mkdir -p "$work/$name/diff"
  echo "$name 1x: $("$work/bin/caboose-draw-replay" --diff "$work/$name/diff" "$@")"
  mkdir -p "$work/$name/3x"
  echo "$name 3x: $("$work/bin/caboose-draw-replay" --scale 3 --png "$work/$name/3x" "$@")"
  echo "$name: $(du -ch "$@" | tail -1 | cut -f1) captured; 3x pictures in $work/$name/3x"
}

doc() {
  python3 - "$1" <<'PY'
import sys
paras = "".join(f"<text:p>{i:4}. The caboose rides at the end of the train; its crew watches the cars ahead for hot boxes, shifted loads and dragging equipment.</text:p>" for i in range(300))
open(sys.argv[1], "w").write('<?xml version="1.0" encoding="UTF-8"?><office:document xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.3" office:mimetype="application/vnd.oasis.opendocument.text"><office:body><office:text>' + paras + '</office:text></office:body></office:document>')
PY
}

wanted=${*:-gtk3 writer}
for name in $wanted; do
  case $name in
    gtk3) run gtk3 python3 "$here/tests/gtk3_scene.py" 3 ;;
    writer)
      doc "$work/train.fodt"
      # LibreOffice's own choice of backend: gtk3 on Wayland when installed, gen (X11) otherwise.
      run writer timeout 25 soffice --writer --norestore --nologo \
        "-env:UserInstallation=file://$work/lo" "$work/train.fodt" ;;
  esac
done
echo "work directory: $work"
