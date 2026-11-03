#!/bin/sh
# A GL client whose executor leaves mid-frame must unwind and exit.
#
#   sh apps/ios/GPUStream/gfxstream/linux-executor/check-gl-loss.sh IMAGE WORK DRIVER GL_LOSS_EXIT [OUT]
#
# Runs GL_LOSS_EXIT (guest/gpu/gfxstream/driver/sync-check/gl_loss_exit.c) on the guest driver
# through Zink, rendering and flushing every frame, ends the real Linux executor while it
# renders, and requires the program to tear its context down and exit within 30 s of its run.
# A client stuck after the loss (Zink spinning in context teardown) fails. CPUS defaults to 4.
set -eu
[ $# -ge 4 ] && [ $# -le 5 ] || { sed -n '4,10p' "$0" >&2; exit 2; }
image=$1
work=$(cd "$2" && pwd)
driver=$(realpath "$3")
probe=$(realpath "$4")
out=${5:-./linux-executor-gl-loss}
mkdir -p "$out"; out=$(cd "$out" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../../../.." && pwd)
name=caboose-gl-loss-$$
shared=$(mktemp -d); chmod 1777 "$shared"
cpus=${CPUS:-4}
phone=guest-handles,guest-handle-arrays,completion-feed,ordered-present,guest-images,guest-query-pools,executor-resume,zstd-stream,guest-buffer-views
cleanup() { docker rm -f "$name-executor" "$name-computer" > /dev/null 2>&1 || true; rm -rf "$shared"; }
trap cleanup EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
wait_log() { i=0; while ! docker logs "$1" 2>&1 | grep -q "$2"; do i=$((i + 1)); [ $i -le $(($3 * 5)) ] || return 1; sleep 0.2; done; }
cp "$driver" "$shared/libvulkan_gfxstream.so"; cp "$probe" "$shared/gl_loss_exit"
docker run -d --name "$name-computer" --init --network none --cpus "$cpus" --memory 6g --device /dev/dri/renderD128 \
  --entrypoint "" -v "$repo/guest/gpu:/repo/guest/gpu:ro" -v "$here:/repo/apps/ios/GPUStream/gfxstream/linux-executor:ro" \
  -v "$shared:/shared" "$image" runuser -u caboose -- env HOME=/tmp python3 -u \
  /repo/apps/ios/GPUStream/gfxstream/linux-executor/broker_host.py --directory /shared/gpu --listen 127.0.0.1:14650 > /dev/null
wait_log "$name-computer" 'listening on' 30 || fail 'the broker did not start'
docker exec -u caboose "$name-computer" sh -c 'python3 /repo/guest/gpu/gfxstream/make_manifest.py \
  /shared/libvulkan_gfxstream.so "$(sha256sum /shared/libvulkan_gfxstream.so | cut -d" " -f1)" /tmp/icd.json 1.3.0'
docker run -d --name "$name-executor" --init --network "container:$name-computer" --cpus "$cpus" --memory 6g \
  -v "$work/build:/build:ro" -v "$repo/guest/gpu:/repo/guest/gpu:ro" \
  -v "$here:/repo/apps/ios/GPUStream/gfxstream/linux-executor:ro" -v "$shared:/shared:ro" caboose-linux-executor \
  python3 -u /repo/apps/ios/GPUStream/gfxstream/linux-executor/executor.py --connect 127.0.0.1:14650 \
  --token-file /shared/gpu/token --library /build/libcaboose_gpu_executor.so --features "$phone" > /dev/null
wait_log "$name-executor" 'session ready' 60 || fail 'the executor session did not start'
seconds=${SECONDS_RENDERING:-12}
docker exec -d -u caboose "$name-computer" sh -c "env HOME=/tmp VK_DRIVER_FILES=/tmp/icd.json VK_LOADER_LAYERS_DISABLE='*' GALLIUM_DRIVER=zink \
  CABOOSE_GFXSTREAM_SOCKET=/shared/gpu/gpu.sock /shared/gl_loss_exit $seconds > /tmp/gl.log 2>&1; echo exit=\$? >> /tmp/gl.log"
sleep 4
docker exec "$name-computer" grep -q CABOOSE_GPU_HELLO /tmp/gl.log || fail 'the GL client did not reach the executor'
# The executor leaves mid-frame, as a phone that drops off the network does (KEEP_EXECUTOR=1
# keeps it, for the same client's teardown with its executor present).
[ -n "${KEEP_EXECUTOR:-}" ] || docker rm -f "$name-executor" > /dev/null
i=0
until docker exec "$name-computer" grep -q '^exit=' /tmp/gl.log; do
  i=$((i + 1)); [ $i -le $(((seconds + 30) * 2)) ] || { docker exec "$name-computer" cat /tmp/gl.log > "$out/gl.log" 2>&1; fail "the GL client did not exit after its executor left ($out/gl.log)"; }
  sleep 0.5
done
docker exec "$name-computer" cat /tmp/gl.log > "$out/gl.log"
grep -q '^exit=0' "$out/gl.log" && grep -q 'CABOOSE_GL_LOSS' "$out/gl.log" || fail "the GL client failed ($out/gl.log)"
echo "PASS GL client unwound after its executor left: $(grep -o 'frames=[0-9]* teardown_ms=[0-9.]*' "$out/gl.log")"
