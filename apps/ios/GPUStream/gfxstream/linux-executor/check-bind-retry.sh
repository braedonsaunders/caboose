#!/bin/sh
# A swapchain whose first bind the phone fails with EAGAIN must wait for the retry and present
# every frame, on a running computer.
#
#   sh apps/ios/GPUStream/gfxstream/linux-executor/check-bind-retry.sh COMPUTER WORK DRIVER WAYLAND_PRESENT [OUT]
#
# COMPUTER is a running computer container; the real Linux executor (WORK/build) joins its
# network namespace and serves it for the check's duration, replacing any executor it had,
# and answers the first surface bind with EAGAIN as a phone whose layer is not ready does.
# caboose-display-probe is connected as the viewer. WAYLAND_PRESENT
# (guest/gpu/gfxstream/driver/sync-check/wayland_present.c) presents 30 frames through DRIVER,
# loaded for that process only. The check requires the failed bind, a later bound one, and all
# 30 frames accepted and presented. CPUS defaults to 4.
set -eu
[ $# -ge 4 ] && [ $# -le 5 ] || { sed -n '4,13p' "$0" >&2; exit 2; }
computer=$1
work=$(cd "$2" && pwd)
driver=$(realpath "$3")
client=$(realpath "$4")
out=${5:-./linux-executor-bind-retry}
mkdir -p "$out"; out=$(cd "$out" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../../../.." && pwd)
name=caboose-bind-retry-$$
cpus=${CPUS:-4}
dir=/tmp/$name
phone=guest-handles,guest-handle-arrays,completion-feed,ordered-present,guest-images,guest-query-pools,executor-resume,zstd-stream,guest-buffer-views,batched-descriptor-sets-inline
cleanup() {
  docker logs "$name" > "$out/executor.log" 2>&1 || true
  docker rm -f "$name" > /dev/null 2>&1 || true
  docker exec "$computer" sh -c "pkill -TERM -f '^caboose-display-probe --token-file /run/caboose/display-token --duration 61'; rm -rf $dir" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
docker exec "$computer" sh -c "mkdir -m 0755 $dir"
docker cp -q "$driver" "$computer:$dir/libvulkan_gfxstream.so"
docker cp -q "$client" "$computer:$dir/wayland_present"
docker cp -q "$repo/guest/gpu/gfxstream/make_manifest.py" "$computer:$dir/make_manifest.py"
docker exec "$computer" sh -ec "cd $dir; chmod 0644 libvulkan_gfxstream.so; chmod 0755 wayland_present
  python3 make_manifest.py $dir/libvulkan_gfxstream.so \$(sha256sum libvulkan_gfxstream.so | cut -d' ' -f1) icd.json 1.3.0
  chmod 0644 icd.json"
token=$(docker exec "$computer" cat /run/caboose/display-token)
lines=$(docker exec "$computer" sh -c 'wc -l < /home/caboose/.cache/caboose-display.log')
docker run -d --name "$name" --init --network "container:$computer" --cpus "$cpus" --memory 3g \
  -v "$work/build:/build:ro" -v "$repo/guest/gpu:/repo/guest/gpu:ro" -v "$here:/repo/apps/ios/GPUStream/gfxstream/linux-executor:ro" \
  --entrypoint sh caboose-linux-executor -c "printf %s '$token' > /tmp/token; exec python3 -u \
  /repo/apps/ios/GPUStream/gfxstream/linux-executor/executor.py --connect 127.0.0.1:14600 --token-file /tmp/token \
  --library /build/libcaboose_gpu_executor.so --features $phone --fail-binds 1" > /dev/null
i=0; until docker logs "$name" 2>&1 | grep -q 'session ready'; do i=$((i + 1)); [ $i -le 150 ] || fail 'executor readiness'; sleep 0.2; done
docker exec -d -u caboose "$computer" sh -c 'exec caboose-display-probe --token-file /run/caboose/display-token --duration 61 --display 640x480@60x1 > /dev/null 2>&1'
i=0; until docker exec "$computer" sh -c "tail -n +$((lines + 1)) /home/caboose/.cache/caboose-display.log" | grep -q 'session started'; do
  i=$((i + 1)); [ $i -le 150 ] || fail 'viewer readiness'; sleep 0.2; done
# The compositor's own renderer moves to the new executor first; its window binds are not the client's.
i=0; until docker logs "$name" 2>&1 | grep -q "application:'caboose-display'"; do i=$((i + 1)); [ $i -le 150 ] || break; sleep 0.2; done
sleep 2
status=0
docker exec -u caboose "$computer" sh -c "set -a; . /run/caboose/display.env; set +a
  export VK_DRIVER_FILES=$dir/icd.json VK_LOADER_LAYERS_DISABLE='*'
  exec timeout 60 $dir/wayland_present 30" > "$out/client.log" 2>&1 || status=$?
sleep 1
docker logs "$name" > "$out/executor.log" 2>&1
grep -q 'surface bind failed .* (injected)' "$out/executor.log" || fail 'no bind was failed: the first bind was not the client'"'"'s'
grep -q 'CABOOSE_GPU_SURFACE_BIND .* failed errno=11' "$out/client.log" || fail 'the client did not see the failed bind'
grep -q 'CABOOSE_GPU_SURFACE_BIND .* bound errno=0' "$out/client.log" || fail 'the client never bound after the failure'
[ "$status" = 0 ] || fail "wayland_present exited $status: $(tail -n 1 "$out/client.log")"
grep -q 'swapchain retired .* frames=30 ' "$out/executor.log" || fail 'the executor did not present all 30 frames'
echo 'PASS bind retry: a bind failed with EAGAIN was retried and all 30 frames were presented'
