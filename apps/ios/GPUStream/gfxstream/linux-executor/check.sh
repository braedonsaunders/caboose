#!/bin/sh
# End-to-end check of a guest driver release against the Linux executor, without a phone.
#
#   sh apps/ios/GPUStream/gfxstream/linux-executor/check.sh IMAGE WORK DRIVER SYNC_CHECK [OUT]
#
# IMAGE is the computer image (for example caboose-computer:flathub-79f46a1), WORK the
# directory build.sh built in, DRIVER the guest driver (libvulkan_gfxstream.so), SYNC_CHECK
# the probe binary (guest/gpu/gfxstream/driver/sync-check). A disposable computer container
# runs broker_host.py (the broker from this checkout) and an Xvfb display; an executor
# container from build.sh's image shares its network namespace and connects to the broker.
# The probe runs against the executor with the phone's capabilities; then vkcube (from the
# executor image) presents 300 frames through another with the same capabilities. Logs go to
# OUT (default ./linux-executor-check). CPUS (default 4) bounds each container. BIND_DELAY
# (seconds, default 0.4) answers each window bind that much later, as a phone waiting for
# its window's layer does, so what an application asks before its window is bound is
# exercised; EXTRA_FORMATS (FORMAT:SPACE,..., default 37:0,43:0, the R8G8B8A8 formats) has
# surfaces report formats beyond lavapipe's two, as the phone does, so the answers before
# and after a bind differ. Exit status 0 when every step passed.
set -eu
[ $# -ge 4 ] && [ $# -le 5 ] || { sed -n '4,15p' "$0" >&2; exit 2; }
image=$1
work=$(cd "$2" && pwd)
driver=$(realpath "$3")
probe=$(realpath "$4")
out=${5:-./linux-executor-check}
mkdir -p "$out"
out=$(cd "$out" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../../../.." && pwd)
name=caboose-lexec-$$
shared=$(mktemp -d)
chmod 0777 "$shared"
cpus=${CPUS:-4}
phone=guest-handles,guest-handle-arrays,completion-feed,ordered-present,guest-images,guest-query-pools,shader-cache,executor-resume,zstd-stream,upload-cache,guest-buffer-views,batched-descriptor-sets-inline
cleanup() {
  docker rm -f "$name-executor" "$name-computer" > /dev/null 2>&1 || true
  rm -rf "$shared"
}
trap cleanup EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
wait_log() { # container pattern seconds
  i=0
  while ! docker logs "$1" 2>&1 | grep -q "$2"; do
    i=$((i + 1)); [ $i -le $(($3 * 5)) ] || return 1; sleep 0.2
  done
}

docker run --rm caboose-linux-executor cat /usr/bin/vkcube > "$shared/vkcube"
chmod 0755 "$shared/vkcube"
cp "$driver" "$shared/libvulkan_gfxstream.so"
cp "$probe" "$shared/sync_check"
docker run -d --name "$name-computer" --init --network none --cpus "$cpus" --memory 6g --entrypoint "" \
  -v "$repo/guest/gpu:/repo/guest/gpu:ro" -v "$here:/repo/apps/ios/GPUStream/gfxstream/linux-executor:ro" \
  -v "$shared:/shared" "$image" runuser -u caboose -- env HOME=/tmp python3 -u \
  /repo/apps/ios/GPUStream/gfxstream/linux-executor/broker_host.py --directory /shared/gpu --listen 127.0.0.1:14650 --bind-delay "${BIND_DELAY:-0.4}" --refuse-missing-x11 :99 \
  > /dev/null
wait_log "$name-computer" 'listening on' 30 || fail 'the broker did not start'
docker exec -d -u caboose "$name-computer" Xvfb :99 -screen 0 1920x1080x24 -nolisten tcp
docker exec -u caboose "$name-computer" sh -c 'python3 /repo/guest/gpu/gfxstream/make_manifest.py \
  /shared/libvulkan_gfxstream.so "$(sha256sum /shared/libvulkan_gfxstream.so | cut -d" " -f1)" /tmp/icd.json 1.3.0'
app() { # as the seat user, on the guest driver, with the broker's sockets and the display
  docker exec -u caboose "$name-computer" env DISPLAY=:99 HOME=/tmp VK_DRIVER_FILES=/tmp/icd.json \
    VK_LOADER_LAYERS_DISABLE='*' CABOOSE_GFXSTREAM_SOCKET=/shared/gpu/gpu.sock \
    CABOOSE_GFXSTREAM_SURFACE_SOCKET=/shared/gpu/surface.sock sh -c 'cd /tmp && exec "$@"' sh "$@"
}
executor() { # features
  docker rm -f "$name-executor" > /dev/null 2>&1 || true
  docker run -d --name "$name-executor" --init --network "container:$name-computer" --cpus "$cpus" --memory 6g \
    -v "$work/build:/build:ro" -v "$repo/guest/gpu:/repo/guest/gpu:ro" \
    -v "$here:/repo/apps/ios/GPUStream/gfxstream/linux-executor:ro" -v "$shared:/shared:ro" caboose-linux-executor \
    python3 -u /repo/apps/ios/GPUStream/gfxstream/linux-executor/executor.py --connect 127.0.0.1:14650 \
    --token-file /shared/gpu/token --library /build/libcaboose_gpu_executor.so --features "$1" --extra-formats "${EXTRA_FORMATS-37:0,43:0}" > /dev/null
  wait_log "$name-executor" 'session ready' 60 || fail 'the executor session did not start'
}
drain() { # log
  # An executor that already exited keeps its logs for the verdict below.
  docker kill -s TERM "$name-executor" > /dev/null 2>&1 || true
  code=$(docker wait "$name-executor")
  docker logs "$name-executor" > "$1" 2>&1
  [ "$code" = 0 ] && grep -q 'normal close after REVOKED' "$1" || fail "the executor did not drain cleanly ($1)"
}

status=0
executor "$phone"
if app timeout 600 /shared/sync_check > "$out/sync-check.log" 2>&1; then
  echo "PASS sync-check: $(grep -c 'case=.* PASS' "$out/sync-check.log") cases"
else
  status=1; echo "FAIL sync-check: $(grep 'FAIL\|failures=' "$out/sync-check.log" | tr '\n' ' ')"
fi
grep 'note=surface_enumeration' "$out/sync-check.log" || true
if app env CABOOSE_GFXSTREAM_RETIREMENT_DIAGNOSTICS=1 timeout 120 /shared/sync_check --lifetime-child > "$out/allocator-lifetime.log" 2>&1; then
  retired=$(grep -c 'CABOOSE_GPU_PRESENTATION_RETIRED leases=0 records=0' "$out/allocator-lifetime.log" || true)
  if [ "$retired" = 32 ]; then
    echo 'PASS allocator lifetime: 32 cycles, zero guest allocations and remote retirement records'
  else
    status=1; echo "FAIL remote retirement accounting: $retired/32 empty ledgers"
  fi
else
  status=1; echo 'FAIL allocator lifetime (allocator-lifetime.log)'
fi
drain "$out/executor-sync-check.log"
# The abandoned_work case's process left a batch waiting for a timeline value nothing signals:
# the executor releases that wait and finishes the process within 5 s.
if grep -q 'case=abandoned_work' "$out/sync-check.log"; then
  released=$(grep -c 'CABOOSE_GPU_RELEASED' "$out/executor-sync-check.log" || true)
  slow=$(awk -F'seconds=' '/process finished/ { if ($2 + 0 >= 5) n++ } END { print n + 0 }' "$out/executor-sync-check.log")
  if [ "$released" -ge 1 ] && [ "$slow" = 0 ]; then echo "PASS abandoned work: its wait released, every process finished within 5 s"
  else status=1; echo "FAIL abandoned work: released=$released slow_finishes=$slow"; fi
fi
# The probe's child windows (a covering and an inset child of one top-level, an inset child
# of another) each bind a surface of their own and present every frame on the executor.
children=$(grep 'case=child_windows' "$out/sync-check.log" | sed -n 's/.* windows=\([^ ]*\).*/\1/p')
if [ -n "$children" ]; then
  shown=0
  for window in $(echo "$children" | tr ',' ' '); do
    grep -q "swapchain retired window=$window swapchain=[0-9]* frames=30 " "$out/executor-sync-check.log" && shown=$((shown + 1))
  done
  if [ "$shown" = 3 ]; then echo "PASS child windows: 3 surfaces presented 30 frames each"
  else status=1; echo "FAIL child windows: $shown of 3 surfaces presented 30 frames ($children)"; fi
fi


one_shot=$(sed -n 's/.*case=one_shot .*window=\([^ ]*\).*/\1/p' "$out/sync-check.log")
if [ -n "$one_shot" ]; then
  if grep -q "swapchain retired window=$one_shot swapchain=[0-9]* frames=1 " "$out/executor-sync-check.log"; then
    echo 'PASS one shot: delayed bind presented its single frame'
  else
    status=1; echo 'FAIL one shot: executor did not retire exactly one frame'
  fi
fi

executor "$phone"
if app timeout 600 /shared/vkcube --c 300 > "$out/vkcube.log" 2>&1; then :; else status=1; echo 'FAIL vkcube did not finish'; fi
drain "$out/executor-vkcube.log"
retired=$(grep 'swapchain retired' "$out/executor-vkcube.log" | tail -1)
case $retired in
  *' frames=300 '*) echo "PASS vkcube: ${retired#*swapchain retired }" ;;
  *) status=1; echo "FAIL vkcube: ${retired:-no swapchain retired}" ;;
esac
docker logs "$name-computer" > "$out/broker.log" 2>&1
exit $status
