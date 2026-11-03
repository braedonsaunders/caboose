#!/bin/sh
# Real packaged compositor + real Linux executor, with one-shot and continuous Wayland Vulkan.
# IMAGE WORK RELEASE DRIVER WAYLAND_PROBE OUT
set -eu
[ $# = 6 ] || exit 2
image=$1; work=$(realpath "$2"); release=$(realpath "$3"); driver=$(realpath "$4"); probe=$(realpath "$5")
mkdir -p "$6"; out=$(realpath "$6")
here=$(cd "$(dirname "$0")" && pwd); repo=$(cd "$here/../../../../.." && pwd)
name=caboose-wayland-check-$$
shared=$(mktemp -d); chmod 0777 "$shared"
cleanup() {
  docker logs "$name-executor" > "$out/executor.log" 2>&1 || true
  docker exec "$name-computer" cat /home/caboose/.cache/caboose-display.log > "$out/display.log" 2>&1 || true
  docker rm -f "$name-executor" "$name-computer" >/dev/null 2>&1 || true
  rm -rf "$shared"
}
trap cleanup EXIT INT TERM
cp "$driver" "$shared/libvulkan_gfxstream.so"; cp "$probe" "$shared/wayland_present"
printf 'wayland-check-token' > "$shared/token"
features=guest-handles,guest-handle-arrays,completion-feed,ordered-present,guest-images,guest-query-pools,shader-cache,executor-resume,zstd-stream,upload-cache,guest-buffer-views,batched-descriptor-sets
docker run -d --name "$name-computer" --init --network none --cpus 4 --memory 6g --shm-size 256m \
 -v "$release:/release:ro" -v "$shared:/shared" -v "$repo/guest/gpu:/repo/guest/gpu:ro" \
 --entrypoint /bin/sh "$image" -c 'exec sleep infinity' >/dev/null
docker exec "$name-computer" sh -ec '
 cp -a /release/files/. /
 for deb in /release/debs/*.deb; do [ ! -f "$deb" ] || dpkg -i "$deb" >/dev/null; done
 mkdir -p /run/caboose
 cp /shared/token /run/caboose/display-token; chmod 0644 /run/caboose/display-token
 python3 /repo/guest/gpu/gfxstream/make_manifest.py /shared/libvulkan_gfxstream.so "$(sha256sum /shared/libvulkan_gfxstream.so | cut -d" " -f1)" /shared/icd.json 1.3.0
 mkdir -p /usr/local/lib/caboose-gpu-live
 chmod 0644 /shared/icd.json
 cp /shared/icd.json /usr/local/lib/caboose-gpu-live/icd.json
 caboose-session start >/dev/null
'
docker run -d --name "$name-executor" --init --network "container:$name-computer" --cpus 4 --memory 6g \
 -v "$work/build:/build:ro" -v "$repo/guest/gpu:/repo/guest/gpu:ro" -v "$here:/repo/apps/ios/GPUStream/gfxstream/linux-executor:ro" -v "$shared:/shared:ro" \
 caboose-linux-executor python3 -u /repo/apps/ios/GPUStream/gfxstream/linux-executor/executor.py --connect 127.0.0.1:14600 --token-file /shared/token \
 --library /build/libcaboose_gpu_executor.so --features "$features" >/dev/null
for attempt in $(seq 1 100); do
 docker logs "$name-executor" 2>&1 | grep -q 'session ready' && break
 [ "$attempt" != 100 ] || { echo 'FAIL executor readiness'; exit 1; }
 sleep .1
done
docker exec -d -u caboose "$name-computer" sh -c 'exec caboose-display-probe --token-file /shared/token --duration 45 --display 320x240@60x1 --json > /shared/owner.log 2>&1'
for attempt in $(seq 1 100); do
 docker exec "$name-computer" grep -q 'session started' /home/caboose/.cache/caboose-display.log && break
 [ "$attempt" != 100 ] || { echo 'FAIL owner readiness'; exit 1; }
 sleep .1
done
for frames in 1 30; do
 docker exec -u caboose "$name-computer" sh -ec '
  set -a; . /run/caboose/display.env
  export VK_DRIVER_FILES=/shared/icd.json VK_LOADER_LAYERS_DISABLE="*" VK_LOADER_DEBUG=error,warn
  export CABOOSE_GFXSTREAM_SOCKET=/run/user/1000/caboose-gpu/gpu.sock CABOOSE_GFXSTREAM_SURFACE_SOCKET=/run/user/1000/caboose-gpu/surface.sock
  exec timeout 30 /shared/wayland_present "$1"
 ' sh "$frames" > "$out/wayland-$frames.log" 2>&1
 sleep 1
done
docker kill -s TERM "$name-executor" >/dev/null
code=$(docker wait "$name-executor")
docker logs "$name-executor" > "$out/executor.log" 2>&1
[ "$code" = 0 ] || { echo 'FAIL executor drain'; exit 1; }
for frames in 1 30; do
 grep -q "swapchain retired .* frames=$frames " "$out/executor.log" || { echo "FAIL Wayland executor frames=$frames"; exit 1; }
 echo "PASS Wayland: executor presented $frames frames"
done
