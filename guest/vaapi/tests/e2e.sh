#!/bin/sh
# End-to-end check with real players on a GPU: mpv and Chromium decode through
# caboose_drv_video.so on a headless Weston (GL on the render node), with
# `cbva-capture serve` standing in for caboose-display. Screenshots go through
# the reference marker detector.
#
#   CABOOSE_VAAPI_DRI=1 scripts/dev.sh tests/e2e.sh
#   CABOOSE_VAAPI_DRI=1 CBVA_SANDBOX=1 \
#     CABOOSE_VAAPI_DOCKER_ARGS="--security-opt seccomp=$PWD/../container/caboose-seccomp.json" \
#     scripts/dev.sh tests/e2e.sh            # Chromium with its sandbox on
#
# Needs a render node whose GL driver imports dmabufs (any Mesa GPU driver;
# llvmpipe on Xvfb cannot, and the players then decode in software).
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
build=$(cd "$here" && cd "${CBVA_BUILD:-build}" && pwd)
w=${CBVA_WORK:-$(mktemp -d /tmp/cbva-e2e.XXXXXX)}
mkdir -p "$w/run" && chmod 700 "$w/run"
export XDG_RUNTIME_DIR="$w/run" WAYLAND_DISPLAY=cbva-e2e
export LIBVA_DRIVER_NAME=caboose LIBVA_DRIVERS_PATH="$build" CABOOSE_VA_LOG=1
pass=0 fail=0 pids=
cleanup() { for p in $pids; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT
ls /dev/dri/renderD* >/dev/null 2>&1 || { echo "no render node (run with CABOOSE_VAAPI_DRI=1)"; exit 2; }

cd "$w"
weston --backend=headless --renderer=gl --width=1280 --height=720 --socket=$WAYLAND_DISPLAY \
  --debug --idle-time=0 > weston.log 2>&1 &
pids="$pids $!"
sleep 2
grep -q "Using GL renderer" weston.log || { echo "weston has no GL renderer"; cat weston.log; exit 2; }
ffmpeg -nostdin -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=1280x720:rate=30:duration=30 \
  -c:v libx264 -profile:v high -bf 3 -g 60 -movflags +faststart clip.mp4

result() { # name ok detail
  if [ "$2" = 1 ]; then pass=$((pass + 1)); echo "PASS $1  $3"; else fail=$((fail + 1)); echo "FAIL $1  $3"; fi
}

serve() { # capture decode_after [replay_after]
  rm -f "$XDG_RUNTIME_DIR/caboose-video.sock"
  "$build/cbva-capture" serve "$XDG_RUNTIME_DIR/caboose-video.sock" "$1" "$2" "${3:-0}" &
  server=$!
  pids="$pids $server"
  sleep 0.3
}

shot() { # name -> prints detector output
  rm -f wayland-screenshot-*.png
  weston-screenshooter >/dev/null 2>&1
  convert wayland-screenshot-*.png "$1.ppm" && rm -f wayland-screenshot-*.png
  "$build/cbva-detect" "$1.ppm"
}

near() { awk -v a="$1" -v b="$2" -v t="$3" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= t) }'; }

field() { echo "$1" | sed -n "s/.*$2=\([^ ]*\).*/\1/p" | head -1; }

# mpv: frames stay on the GPU; the window shows the marker at the video's rect.
mpv_case() { # name hwdec decode_after [replay_after]
  serve "$1.cap" "$3" "${4:-0}"
  mpv --no-config --hwdec="$2" --vo=gpu --gpu-context=wayland --geometry=960x540 --osc=no --loop \
    clip.mp4 > "$1.log" 2>&1 &
  player=$!
  sleep 6
  det=$(shot "$1")
  kill "$player"; sleep 0.5; kill "$server"
  sum=$("$build/cbva-capture" split "$1.cap" "$1.out")
  echo "$sum" | sed 's/^/    /'
}

mpv_case mpv-passthrough vaapi 0 40
rect=$(field "$det" rect)
ok=0
if [ -n "$rect" ] && near "$(echo "$rect" | cut -d, -f3)" 960 3 && near "$(echo "$rect" | cut -d, -f4)" 540 3 &&
   [ "$(field "$sum" frames)" -gt 60 ] && [ "$(field "$sum" surfaces_exported)" -gt 0 ] &&
   [ "$(field "$sum" replays)" -gt 0 ] && [ "$(field "$sum" replay_from_key)" = 1 ]; then ok=1; fi
result mpv-passthrough $ok "detector: ${det:-none}; replayed $(field "$sum" replays) frames from a key frame"

mpv_case mpv-readback vaapi-copy 0
ok=0; [ -z "$det" ] && [ "$(field "$sum" close)" = 1 ] && ok=1
result mpv-readback $ok "stream closed with reason $(field "$sum" close) (1 = readback); marker on screen: ${det:-none}"

mpv_case mpv-compositor-decode vaapi 30
ok=0; [ -z "$det" ] && [ "$(field "$sum" close)" = 2 ] && [ "$(field "$sum" frames)" = 30 ] && ok=1
result mpv-compositor-decode $ok "forwarded $(field "$sum" frames) frames, then reason $(field "$sum" close) (2 = DECODE); marker on screen: ${det:-none}"

# Chromium: a <video> at 800x450 CSS px in a page; the GPU process decodes through the
# driver. One run per codec Chromium decodes with VA on Linux.
ffmpeg -nostdin -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=1280x720:rate=30:duration=30 \
  -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -b:v 2M clip.webm
ffmpeg -nostdin -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=1280x720:rate=30:duration=30 \
  -c:v libsvtav1 -preset 12 -b:v 2M clip-av1.webm
ffmpeg -nostdin -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=1280x720:rate=30:duration=30 \
  -c:v libx265 -tag:v hvc1 -x265-params log-level=error -b:v 2M -movflags +faststart clip-hevc.mp4
sandbox=--no-sandbox
[ "${CBVA_SANDBOX:-0}" = 1 ] && sandbox=
for clip in clip.mp4 clip.webm clip-av1.webm clip-hevc.mp4; do
  name=chromium-$(echo "${clip#clip}" | tr -d .-)
  cat > page.html <<H
<html><body style="margin:0;background:#334"><video src="$clip" autoplay muted loop
 style="position:absolute;left:40px;top:30px;width:800px;height:450px"></video></body></html>
H
  serve "$name.cap" 0
  chromium $sandbox --ozone-platform=wayland --user-data-dir="$w/profile-$name" --no-first-run \
    --enable-features=VaapiVideoDecoder,VaapiVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxZeroCopyGL,VaapiIgnoreDriverChecks \
    --ignore-gpu-blocklist --window-size=1000,600 --app="file://$w/page.html" > "$name.log" 2>&1 &
  player=$!
  pids="$pids $player"
  sleep 12
  det=$(shot "$name")
  kill "$player"; sleep 1; kill "$server"
  sum=$("$build/cbva-capture" split "$name.cap" "$name.out")
  echo "$sum" | sed 's/^/    /'
  # What Chromium fed the driver must decode to the source's first frames, exactly.
  n=$(field "$sum" frames)
  # Decode order runs ahead of display order by the reorder depth (B-frames), so
  # leave a margin at the end.
  shown=$((n - $(field "$sum" hidden) - 8))
  fwd=$(ls "$name".out-1.* | head -1)
  ffmpeg -nostdin -loglevel error -i "$clip" -frames:v "$shown" -f framemd5 - | grep -v '^#' | cut -d, -f6 | sort > "$name.src"
  ffmpeg -nostdin -loglevel error -i "$fwd" -f framemd5 - 2> /dev/null | grep -v '^#' | cut -d, -f6 | sort > "$name.fwd"
  missing=$(comm -23 "$name.src" "$name.fwd" | wc -l)
  rect=$(field "$det" rect)
  ok=0
  if [ -n "$rect" ] && near "$(echo "$rect" | cut -d, -f3)" 800 3 && near "$(echo "$rect" | cut -d, -f4)" 450 3 &&
     [ "$n" -gt 60 ] && [ "$missing" -eq 0 ]; then ok=1; fi
  result "$name${sandbox:+ (no sandbox)}" $ok "detector: ${det:-none}; first $shown source frames all in the forwarded stream ($missing missing)"
done

# GStreamer's va decoders (they need a render node, and GST_VA_ALL_DRIVERS=1 to accept a
# driver outside their allow-list). Frames in VA memory: passthrough must be bit-exact.
# Frames downloaded to system memory: readback, then local decoding, also bit-exact.
export GST_VA_ALL_DRIVERS=1 GST_REGISTRY="$w/gst-registry.bin"
hashes() { ffmpeg -nostdin -loglevel error "$@" -f framemd5 - | grep -v '^#' | cut -d, -f6; }
ffmpeg -nostdin -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=640x360:rate=30:duration=2 \
  -c:v libx264 -bf 3 -g 30 g.mp4
ffmpeg -nostdin -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=640x360:rate=30:duration=2 \
  -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -b:v 500k g.webm
hashes -i g.mp4 > g.src
hashes -i g.webm | sort > g9.src
CABOOSE_VA_SINK="$w/g.cap" gst-launch-1.0 -q filesrc location=g.mp4 ! qtdemux ! h264parse ! vah264dec ! \
  'video/x-raw(memory:VAMemory)' ! fakesink sync=false > g.log 2>&1
"$build/cbva-capture" split g.cap g.out > /dev/null
hashes -i g.out-1.h264 -vf crop=640:360:0:0 > g.fwd 2> /dev/null
ok=0; cmp -s g.src g.fwd && ok=1
result gstreamer-h264-passthrough $ok "$(wc -l < g.fwd) of $(wc -l < g.src) frames bit-exact"
CABOOSE_VA_SINK="$w/g9.cap" gst-launch-1.0 -q filesrc location=g.webm ! matroskademux ! vp9parse ! vavp9dec ! \
  'video/x-raw(memory:VAMemory)' ! fakesink sync=false > g9.log 2>&1
"$build/cbva-capture" split g9.cap g9.out > /dev/null
hashes -i g9.out-1.ivf 2> /dev/null | sort > g9.fwd
missing=$(comm -23 g9.src g9.fwd | wc -l)
ok=0; [ "$missing" -eq 0 ] && [ -s g9.fwd ] && ok=1
result gstreamer-vp9-passthrough $ok "$missing source frames missing"
for codec in h265 av1; do
  case $codec in
    h265) ffmpeg -nostdin -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=640x360:rate=30:duration=2 \
            -c:v libx265 -x265-params log-level=error g.$codec.mp4
          parse="qtdemux ! h265parse" ;;
    av1)  ffmpeg -nostdin -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=640x360:rate=30:duration=2 \
            -c:v libsvtav1 -preset 12 g.$codec.mp4
          parse="qtdemux ! av1parse" ;;
  esac
  hashes -i g.$codec.mp4 | sort > g.$codec.src
  # shellcheck disable=SC2086
  CABOOSE_VA_SINK="$w/g.$codec.cap" gst-launch-1.0 -q filesrc location=g.$codec.mp4 ! $parse ! va${codec}dec ! \
    'video/x-raw(memory:VAMemory)' ! fakesink sync=false > g.$codec.log 2>&1
  "$build/cbva-capture" split g.$codec.cap g.$codec.out > /dev/null
  [ $codec = h265 ] && crop=crop=640:360:0:0 || crop=null
  hashes -i "$(ls g.$codec.out-1.* | head -1)" -vf $crop 2> /dev/null | sort > g.$codec.fwd
  missing=$(comm -23 g.$codec.src g.$codec.fwd | wc -l)
  ok=0; [ "$missing" -eq 0 ] && [ -s g.$codec.fwd ] && ok=1
  result gstreamer-$codec-passthrough $ok "$(wc -l < g.$codec.src) source frames, $missing missing"
done
CABOOSE_VA_SINK="$w/gr.cap" gst-launch-1.0 -q filesrc location=g.mp4 ! qtdemux ! h264parse ! vah264dec ! \
  videoconvert ! video/x-raw,format=I420 ! filesink location=gr.yuv > gr.log 2>&1
sum=$("$build/cbva-capture" split gr.cap gr.out)
hashes -f rawvideo -pix_fmt yuv420p -s 640x360 -i gr.yuv > gr.rb
ok=0; cmp -s g.src gr.rb && [ "$(field "$sum" close)" = 1 ] && ok=1
result gstreamer-h264-readback $ok "switched at frame $(field "$sum" frames); $(wc -l < gr.rb) frames read back"

echo "e2e: $pass passed, $fail failed (work: $w)"
[ "$fail" -eq 0 ]
