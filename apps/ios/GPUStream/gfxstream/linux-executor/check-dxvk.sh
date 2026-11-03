#!/bin/sh
# DXVK must find an adapter and present under every feature negotiation a phone can make.
#
#   sh apps/ios/GPUStream/gfxstream/linux-executor/check-dxvk.sh COMPUTER WORK BENCH_DIR [OUT]
#
# COMPUTER is a running computer with the Steam Flatpak, its Steam Linux Runtime 4 and a Proton
# (PROTON, default /opt/caboose-games/GE-Proton11-11/proton). BENCH_DIR, inside Steam's
# Flatpak data (default /home/caboose/.var/app/com.valvesoftware.Steam/caboose-bench), holds
# triangle.exe, DXVK's d3d11 triangle test. For each feature list (the phone's and an older
# phone's) the real Linux executor (WORK/build) joins the
# computer's network namespace and serves it, replacing any executor it had, with
# caboose-display-probe as the viewer (DISPLAY_SHAPE, default a phone's 932x1356@60x2); the triangle runs through the computer's own guest
# driver for SECONDS (default 20). Each case requires DXVK to report the device without
# skipping it, a D3D11 device and a swapchain; REQUIRE_FRAMES=1 also requires presented frames,
# which reach the compositor only through a viewer it binds the window for (a phone).
set -eu
[ $# -ge 3 ] && [ $# -le 4 ] || { sed -n '4,14p' "$0" >&2; exit 2; }
computer=$1
work=$(cd "$2" && pwd)
bench=$3
out=${4:-./linux-executor-dxvk}
mkdir -p "$out"; out=$(cd "$out" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../../../.." && pwd)
proton=${PROTON:-/opt/caboose-games/GE-Proton11-11/proton}
seconds=${SECONDS_RUNNING:-20}
name=caboose-dxvk-check-$$
steam=/home/caboose/.var/app/com.valvesoftware.Steam/.local/share/Steam
cleanup() {
  docker rm -f "$name" > /dev/null 2>&1 || true
  docker exec "$computer" pkill -KILL -f "$bench/triangle.exe" > /dev/null 2>&1 || true
  docker exec "$computer" pkill -TERM -f "^caboose-display-probe --token-file /run/caboose/display-token --duration 9$$" > /dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
token=$(docker exec "$computer" cat /run/caboose/display-token)
phone=guest-handles,guest-handle-arrays,completion-feed,ordered-present,guest-images,guest-query-pools,shader-cache,executor-resume,zstd-stream,upload-cache,guest-buffer-views
older=guest-handles,guest-handle-arrays,completion-feed,ordered-present,guest-images,guest-query-pools,executor-resume
docker exec -d -u caboose "$computer" sh -c "exec caboose-display-probe --token-file /run/caboose/display-token --duration 9$$ --display ${DISPLAY_SHAPE:-932x1356@60x2} > /dev/null 2>&1"
for case in phone older; do
  case $case in phone) features=$phone ;; older) features=$older ;; esac
  docker rm -f "$name" > /dev/null 2>&1 || true
  docker run -d --name "$name" --init --network "container:$computer" --cpus 4 --memory 3g \
    -v "$work/build:/build:ro" -v "$repo/guest/gpu:/repo/guest/gpu:ro" -v "$here:/repo/apps/ios/GPUStream/gfxstream/linux-executor:ro" \
    --entrypoint sh caboose-linux-executor -c "printf %s '$token' > /tmp/token; exec python3 -u \
    /repo/apps/ios/GPUStream/gfxstream/linux-executor/executor.py --connect 127.0.0.1:14600 --token-file /tmp/token \
    --library /build/libcaboose_gpu_executor.so --features $features" > /dev/null
  i=0; until docker logs "$name" 2>&1 | grep -q 'session ready'; do i=$((i + 1)); [ $i -le 150 ] || fail "$case: executor readiness"; sleep 0.2; done
  sleep 4
  lines=$(docker exec "$computer" sh -c 'wc -l < /home/caboose/.cache/caboose-display.log')
  docker exec -u caboose "$computer" sh -c "set -a; . /run/caboose/display.env; set +a; DXVK_LOG_LEVEL=info DXVK_LOG_PATH=none \
    timeout $((seconds + 60)) flatpak run --command=sh com.valvesoftware.Steam -c '
    export STEAM_COMPAT_DATA_PATH=$bench/compat/0 STEAM_COMPAT_CLIENT_INSTALL_PATH=$steam
    mkdir -p $bench/compat/0
    exec $steam/steamapps/common/SteamLinuxRuntime_4/_v2-entry-point --verb=waitforexitandrun -- $proton waitforexitandrun $bench/triangle.exe'" \
    > "$out/$case.log" 2>&1 &
  sleep "$seconds"
  docker exec "$computer" sh -c "tail -n +$((lines + 1)) /home/caboose/.cache/caboose-display.log" | grep -a SURFACE_STATS > "$out/$case-stats.log" || true
  docker exec "$computer" pkill -TERM -f "$bench/triangle.exe" > /dev/null 2>&1 || true
  wait || true
  log=$out/$case.log
  grep -a -q 'Found device: ' "$log" || fail "$case: DXVK found no Vulkan device ($log)"
  ! grep -a -q 'Skipping: ' "$log" || fail "$case: DXVK skipped the device: $(grep -a -m1 'Skipping: ' "$log")"
  ! grep -a -q -E 'No adapters found|D3D11CreateDevice: Failed' "$log" || fail "$case: DXVK found no adapter ($log)"
  grep -a -q 'D3D11InternalCreateDevice: Using feature level' "$log" || fail "$case: no D3D11 device ($log)"
  grep -a -q 'Presenter: Actual swapchain properties' "$log" || fail "$case: no swapchain ($log)"
  frames=$(grep -a -o ' fps=[0-9.]*' "$out/$case-stats.log" | tail -1)
  # Frames reach the compositor only through a viewer it binds the window for (the phone).
  [ -z "${REQUIRE_FRAMES:-}" ] || [ -n "$frames" ] || fail "$case: the triangle never presented ($log)"
  echo "PASS DXVK $case: adapter, D3D11 device and swapchain${frames:+, presenting at$frames}"
done
echo 'PASS DXVK found an adapter and made its device and swapchain under every negotiation'
