#!/bin/sh
# DXVK must find an adapter and present under every feature negotiation a phone can make.
#
#   sh apps/ios/GPUStream/gfxstream/linux-executor/check-dxvk.sh COMPUTER WORK DRIVER BENCH_DIR [OUT]
#
# COMPUTER is a running computer with the Steam Flatpak and a Proton (PROTON, default
# /opt/caboose-games/GE-Proton11-11/proton). BENCH_DIR, inside Steam's Flatpak data (for
# example /home/caboose/.var/app/com.valvesoftware.Steam/caboose-bench), holds triangle.exe,
# DXVK's d3d11 triangle test. A broker from this checkout (broker_host.py, every bind granted)
# runs in the computer on a port of its own, so the computer's own executor and displays are
# untouched; the real Linux executor (WORK/build) joins the computer's network namespace and
# serves it under each feature list (the phone's, with batched descriptor sets, guest-chosen set
# ids, completion payloads, ordering barriers and silent success; the same with only the set ids;
# without the set ids; without batched sets; an older phone's), and the
# triangle runs through Proton with DRIVER (the guest driver under test, loaded for that process
# only, with CABOOSE_READ_PROFILE=1) for SECONDS (default 20). Each case requires DXVK to report
# the device without skipping it, a D3D11 device, a swapchain and presented frames, and the
# executor to end without a fault. The phone's case also requires the hello to grant guest-chosen
# set ids (0x100000), completion payloads (0x200000) and silent success (0x800000), and descriptor
# set allocation never to wait for replies (no drain20077);
# every case prints the allocation drains it saw. PORT (default 14660) and DISPLAY_ENV (default
# /run/caboose/display.env) pick the broker port and the display, CASES a subset of the cases; only the Wine processes in
# BENCH_DIR's own triangle is ended, so checks with separate BENCH_DIRs can share a computer.
# SOCKETS puts the GPU sockets elsewhere when BENCH_DIR's path is too long for one.
set -eu
[ $# -ge 4 ] && [ $# -le 5 ] || { sed -n '4,24p' "$0" >&2; exit 2; }
computer=$1
work=$(cd "$2" && pwd)
driver=$(realpath "$3")
bench=$4
out=${5:-./linux-executor-dxvk}
mkdir -p "$out"; out=$(cd "$out" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../../../.." && pwd)
proton=${PROTON:-/opt/caboose-games/GE-Proton11-11/proton}
# Steam inside its Flatpak (STEAM_ROOT), beside BENCH_DIR in the Flatpak data by default.
steam=${STEAM_ROOT:-$(dirname "$bench")/.local/share/Steam}
seconds=${SECONDS_RUNNING:-20}
name=caboose-dxvk-check-$$
dir=$bench/.check-$$
# The GPU sockets' directory (SOCKETS, default inside the check's directory): a Unix socket's
# path is at most 107 bytes, which a BENCH_DIR deep in a seat's home exceeds.
sockets=${SOCKETS:-$dir}
port=${PORT:-14660}
# The display the triangle presents on (DISPLAY_ENV, the owner seat's by default).
display=${DISPLAY_ENV:-/run/caboose/display.env}
# This check's own triangle: the one started from BENCH_DIR. Proton's waitforexitandrun keeps
# the Flatpak sandbox until the prefix's wineserver has gone, so once the triangle ends, waiting
# for the sandbox waits for the rest of this check's Wine; nothing else on the computer (other
# checks, the owner's games) is waited for or ended.
ours() {
  docker exec "$computer" pgrep -u caboose -f "$bench/triangle.exe" 2>/dev/null || true
}
cleanup() {
  docker rm -f "$name" > /dev/null 2>&1 || true
  pids=$(ours); [ -z "$pids" ] || docker exec "$computer" kill -KILL $pids > /dev/null 2>&1 || true
  docker exec "$computer" pkill -TERM -f "$dir/" > /dev/null 2>&1 || true
  docker exec "$computer" rm -rf "$dir" "$sockets" > /dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
phone=guest-handles,guest-handle-arrays,completion-feed,ordered-present,guest-images,guest-query-pools,shader-cache,executor-resume,zstd-stream,upload-cache,guest-buffer-views,batched-descriptor-sets-inline,guest-set-ids,completion-payloads,wait-serial,silent-success
setids=${phone%,completion-payloads,wait-serial,silent-success}
poolids=${setids%,guest-set-ids}
unbatched=${poolids%,batched-descriptor-sets-inline}
older=guest-handles,guest-handle-arrays,completion-feed,ordered-present,guest-images,guest-query-pools,executor-resume
docker exec "$computer" sh -c "mkdir -p $dir/repo/apps/ios/GPUStream/gfxstream $dir/repo/guest"
docker cp -q "$repo/guest/gpu" "$computer:$dir/repo/guest/"
docker cp -q "$here" "$computer:$dir/repo/apps/ios/GPUStream/gfxstream/"
docker cp -q "$driver" "$computer:$dir/libvulkan_gfxstream.so"
docker exec "$computer" sh -c "mkdir -p $sockets && chown -R caboose $dir $sockets && printf '%s' '{\"file_format_version\":\"1.0.0\",\"ICD\":{\"library_path\":\"$dir/libvulkan_gfxstream.so\",\"api_version\":\"1.3.0\"}}' > $dir/icd.json"
for case in ${CASES:-phone setids poolids unbatched older}; do
  case $case in phone) features=$phone ;; setids) features=$setids ;; poolids) features=$poolids ;; unbatched) features=$unbatched ;; older) features=$older ;; esac
  docker exec "$computer" pkill -TERM -f "$dir/repo/" > /dev/null 2>&1 || true
  docker rm -f "$name" > /dev/null 2>&1 || true
  docker exec -d -u caboose "$computer" sh -c "env HOME=/tmp python3 -u $dir/repo/apps/ios/GPUStream/gfxstream/linux-executor/broker_host.py \
    --directory $sockets/gpu-$case --listen 127.0.0.1:$port > $dir/broker-$case.log 2>&1"
  i=0; until docker exec "$computer" grep -q 'listening on' "$dir/broker-$case.log" 2>/dev/null; do i=$((i + 1)); [ $i -le 100 ] || fail "$case: broker"; sleep 0.2; done
  token=$(docker exec "$computer" cat "$sockets/gpu-$case/token")
  docker run -d --name "$name" --init --network "container:$computer" --cpus 4 --memory 3g \
    -v "$work/build:/build:ro" -v "$repo/guest/gpu:/repo/guest/gpu:ro" -v "$here:/repo/apps/ios/GPUStream/gfxstream/linux-executor:ro" \
    --entrypoint sh caboose-linux-executor -c "printf %s '$token' > /tmp/token; exec python3 -u \
    /repo/apps/ios/GPUStream/gfxstream/linux-executor/executor.py --connect 127.0.0.1:$port --token-file /tmp/token \
    --library /build/libcaboose_gpu_executor.so --features $features --no-checksums" > /dev/null
  i=0; until docker logs "$name" 2>&1 | grep -q 'session ready'; do i=$((i + 1)); [ $i -le 150 ] || fail "$case: executor readiness"; sleep 0.2; done
  docker exec -u caboose "$computer" sh -c "set -a; . $display; set +a
    CABOOSE_GFXSTREAM_SOCKET=$sockets/gpu-$case/gpu.sock CABOOSE_GFXSTREAM_SURFACE_SOCKET=$sockets/gpu-$case/surface.sock \
    CABOOSE_READ_PROFILE=1 DXVK_LOG_LEVEL=info DXVK_LOG_PATH=none timeout $((seconds + 60)) flatpak run --filesystem=$sockets --filesystem=${proton%/*}:ro --env=VK_DRIVER_FILES=$dir/icd.json \
    --env=VK_ICD_FILENAMES=$dir/icd.json '--env=VK_LOADER_LAYERS_DISABLE=*' --command=sh com.valvesoftware.Steam -c '
    export STEAM_COMPAT_DATA_PATH=$bench/compat/0 STEAM_COMPAT_CLIENT_INSTALL_PATH=$steam
    mkdir -p $bench/compat/0
    exec $proton waitforexitandrun $bench/triangle.exe'" > "$out/$case.log" 2>&1 &
  sleep "$seconds"
  pids=$(ours); [ -z "$pids" ] || docker exec "$computer" kill -TERM $pids > /dev/null 2>&1 || true
  wait || true
  # Wine winds down before the next case starts in the same prefix.
  i=0; while pids=$(ours); [ -n "$pids" ]; do
    i=$((i + 1)); [ $i -le 30 ] || { docker exec "$computer" kill -KILL $pids > /dev/null 2>&1 || true; break; }; sleep 1; done
  docker exec "$computer" cat "$dir/broker-$case.log" > "$out/broker-$case.log" 2>/dev/null || true
  docker logs "$name" > "$out/executor-$case.log" 2>&1 || true
  log=$out/$case.log
  grep -a -q 'Found device: ' "$log" || fail "$case: DXVK found no Vulkan device ($log)"
  ! grep -a -q 'Skipping: ' "$log" || fail "$case: DXVK skipped the device: $(grep -a -m1 'Skipping: ' "$log")"
  ! grep -a -q -E 'No adapters found|D3D11CreateDevice: Failed' "$log" || fail "$case: DXVK found no adapter ($log)"
  grep -a -q 'D3D11InternalCreateDevice: Using feature level' "$log" || fail "$case: no D3D11 device ($log)"
  grep -a -q 'Presenter: Actual swapchain properties' "$log" || fail "$case: no swapchain ($log)"
  ! grep -a -q -E 'CABOOSE_GUEST_HANDLE_FAILED|CABOOSE_GPU_EXECUTOR_LOST' "$log" || fail "$case: $(grep -a -m1 -E 'CABOOSE_GUEST_HANDLE_FAILED|CABOOSE_GPU_EXECUTOR_LOST' "$log")"
  ! grep -a -q -E 'GUEST_FAULT|Segmentation fault' "$out/executor-$case.log" || fail "$case: the executor faulted ($out/executor-$case.log)"
  frames=$(grep -a -o 'presented=[0-9]*' "$out/broker-$case.log" | awk -F= '{n+=$2} END {print n+0}')
  [ "$frames" -gt 0 ] || fail "$case: the triangle never presented ($log)"
  # Descriptor set allocations that waited for earlier replies (the pool's set ids), summed
  # over the read profile's reports, which count since the previous report.
  drains=$(grep -a 'CABOOSE_READ_PROFILE' "$log" | grep -a -o ' drain20077=[0-9]*ms/[0-9]*' | tr '=/' '  ' | \
    awk '{ms+=$2; n+=$3} END {printf "%dms/%d", ms, n}')
  if [ "$case" = phone ]; then
    granted=$(grep -a -m1 -o 'CABOOSE_GPU_HELLO features=0x[0-9a-f]*' "$log" | cut -d= -f2)
    [ -n "$granted" ] && [ $((granted & 0x100000)) -ne 0 ] || fail "$case: guest-chosen set ids not granted (${granted:-no hello})"
    [ $((granted & 0x200000)) -ne 0 ] || fail "$case: completion payloads not granted ($granted)"
    [ $((granted & 0x800000)) -ne 0 ] || fail "$case: silent success not granted ($granted)"
    [ "$drains" = 0ms/0 ] || fail "$case: descriptor set allocation waited for replies ($drains)"
  fi
  echo "PASS DXVK $case: adapter, D3D11 device, swapchain, $frames frames presented, allocation drains $drains, hello $(grep -a -m1 -o 'CABOOSE_GPU_HELLO features=0x[0-9a-f]*' "$log" | cut -d= -f2)"
done
echo 'PASS DXVK found an adapter and presented under every negotiation'
