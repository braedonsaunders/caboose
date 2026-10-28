#!/bin/sh
# Measures caboose-display on a WSL2 GPU host (CABOOSE_GPU=wsl): Chromium playing a
# 60 fps video full-window as a Wayland client at 1080p and 4K, streamed with libx264
# and with NVENC, decoded and acknowledged by the probe. Run from the repository root on
# the WSL machine. It builds the dev image, then uses a disposable, uniquely named
# container with /dev/dxg and /usr/lib/wsl, capped at CABOOSE_DISPLAY_CPUS (default 4);
# it never touches the caboose-owner container or caboose-host.
#
#   guest/display/scripts/wsl-check.sh            # results on stdout, logs in target/wsl
#   guest/display/scripts/wsl-check.sh --clean    # also remove the dev image afterwards
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
[ -e /dev/dxg ] || { echo 'no /dev/dxg: not a WSL2 GPU host' >&2; exit 1; }
export CABOOSE_DISPLAY_CPUS=${CABOOSE_DISPLAY_CPUS:-4}
docker build -q -t caboose-display-dev "$root" >/dev/null
"$root/scripts/dev.sh" cargo build -q
name=caboose-display-wsl-check-$$
mkdir -p "$root/target/wsl"
docker run --rm -i --name "$name" --init --cpus "$CABOOSE_DISPLAY_CPUS" --memory 8g \
  --user "$(id -u):$(id -g)" -e HOME=/tmp \
  --device /dev/dxg -v /usr/lib/wsl:/usr/lib/wsl:ro \
  -e LD_LIBRARY_PATH=/usr/lib/wsl/lib -e GALLIUM_DRIVER=d3d12 -e CABOOSE_GPU=wsl \
  -v "$root:/src" -w /src caboose-display-dev sh -s <<'INNER'
set -eu
export XDG_RUNTIME_DIR=/tmp/xdg; mkdir -p -m 0700 $XDG_RUNTIME_DIR
bin=/src/target/debug
echo "== encoders"
$bin/caboose-display --list-encoders 2>/dev/null
nvidia=$(ls /usr/lib/wsl/lib/libnvidia-encode.so* 2>/dev/null | head -1 || true)
echo "libnvidia-encode: ${nvidia:-missing}"
echo "== making a 4K60 test video (10 s)"
mkdir -p /tmp/video
ffmpeg -loglevel error -y -f lavfi -i 'testsrc2=size=3840x2160:rate=60:duration=10' \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 120 /tmp/video/video.mp4
cp /src/scripts/pages/video.html /tmp/video/
run() { # label WxH encoder chromium-extra-flags...
  label=$1; size=$2; enc=$3; shift 3
  log=/src/target/wsl/$label.log
  $bin/caboose-display --no-auth --listen 127.0.0.1:14600 --encoder "$enc" --display "$size@60x1" -- \
    chromium --ozone-platform=wayland --no-sandbox --no-first-run --user-data-dir=/tmp/chromium-$label \
    --autoplay-policy=no-user-gesture-required --window-size=$(echo "$size" | tr x ,) "$@" \
    --app=file:///tmp/video/video.html > "$log" 2>&1 &
  pid=$!
  sleep 8
  printf '%s: ' "$label"
  $bin/caboose-display-probe --duration 15 --display "$size@60x1" --server-pid $pid --decoders hevc,h264 --json || true
  kill $pid; wait $pid 2>/dev/null || true
  grep exiting "$log" | sed 's/.*exiting: /   server: /' || true
}
echo "== Chromium playing 60 fps video full-window (title = fps the page itself presents)"
for size in 1920x1080 3840x2160; do
  run "x264-$size" "$size" software --ignore-gpu-blocklist
  run "nvenc-$size" "$size" nvenc --ignore-gpu-blocklist
done
run x264-1920x1080-cpu-raster 1920x1080 software --disable-gpu
INNER
if [ "${1:-}" = --clean ]; then docker rmi caboose-display-dev >/dev/null; fi
