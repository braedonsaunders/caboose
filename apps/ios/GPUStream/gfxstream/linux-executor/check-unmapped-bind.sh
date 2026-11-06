#!/bin/sh
# A swapchain bound to an override-redirect X11 window before the window is mapped must
# get the window's picture once it maps, on a running computer.
#
#   sh apps/ios/GPUStream/gfxstream/linux-executor/check-unmapped-bind.sh COMPUTER WORK DRIVER SYNC_CHECK [OUT]
#
# COMPUTER is a running computer container; the real Linux executor (WORK/build) joins its
# network namespace with --pictures and serves it for the check's duration, replacing any
# executor it had. caboose-display-probe is connected as the viewer. SYNC_CHECK
# (guest/gpu/gfxstream/driver/sync-check/sync_check.c) runs its unmapped_popup case through
# DRIVER, loaded for that process only: an override-redirect window gets its swapchain and
# first frame while unmapped, another process maps it half a second later, and 30 frames
# follow. The check requires the compositor to hold the bind and attach it when the window
# maps, the client's 31 presents accepted, the executor to present the frames in the
# compositor's window for it, and that window's picture to be the client's colour, not black.
# CPUS defaults to 4.
set -eu
# Nothing a check starts leaves a core dump: crashes are expected while the checks end
# programs, and the host turns each one into a capture of several gigabytes. Every container
# this script runs gets a core limit of 0, and so does every command it runs in a computer
# (prlimit, before the command).
ulimit -c 0
docker() {
  if [ "${1:-}" = run ]; then shift; command docker run --ulimit core=0 "$@"; return; fi
  if [ "${1:-}" != exec ]; then command docker "$@"; return; fi
  shift
  _count=$# _seen=0 _state=option
  while [ "$_seen" -lt "$_count" ]; do
    _arg=$1; shift; _seen=$((_seen + 1))
    case $_state in
      option) case $_arg in
        -u|-e|-w|--user|--env|--workdir) set -- "$@" "$_arg" "$1"; shift; _seen=$((_seen + 1)) ;;
        -*) set -- "$@" "$_arg" ;;
        *) set -- "$@" "$_arg" prlimit --core=0:0 --; _state=command ;;
      esac ;;
      command) set -- "$@" "$_arg" ;;
    esac
  done
  command docker exec "$@"
}
[ $# -ge 4 ] && [ $# -le 5 ] || { sed -n '4,16p' "$0" >&2; exit 2; }
computer=$1
work=$(cd "$2" && pwd)
driver=$(realpath "$3")
client=$(realpath "$4")
out=${5:-./linux-executor-unmapped-bind}
mkdir -p "$out/pictures"; out=$(cd "$out" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../../../.." && pwd)
name=caboose-unmapped-bind-$$
cpus=${CPUS:-4}
dir=/tmp/$name
phone=guest-handles,guest-handle-arrays,completion-feed,ordered-present,guest-images,guest-query-pools,executor-resume,zstd-stream,guest-buffer-views,batched-descriptor-sets
cleanup() {
  docker logs "$name" > "$out/executor.log" 2>&1 || true
  docker rm -f "$name" > /dev/null 2>&1 || true
  docker exec "$computer" sh -c "pkill -TERM -f '^caboose-display-probe --token-file /run/caboose/display-token --duration 61'; rm -rf $dir" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
docker exec "$computer" sh -c "mkdir -m 0755 $dir"
docker cp -q "$driver" "$computer:$dir/libvulkan_gfxstream.so"
docker cp -q "$client" "$computer:$dir/sync_check"
docker cp -q "$repo/guest/gpu/gfxstream/make_manifest.py" "$computer:$dir/make_manifest.py"
docker exec "$computer" sh -ec "cd $dir; chmod 0644 libvulkan_gfxstream.so; chmod 0755 sync_check
  python3 make_manifest.py $dir/libvulkan_gfxstream.so \$(sha256sum libvulkan_gfxstream.so | cut -d' ' -f1) icd.json 1.3.0
  chmod 0644 icd.json"
token=$(docker exec "$computer" cat /run/caboose/display-token)
lines=$(docker exec "$computer" sh -c 'wc -l < /home/caboose/.cache/caboose-display.log')
docker run -d --name "$name" --init --network "container:$computer" --cpus "$cpus" --memory 3g \
  -v "$work/build:/build:ro" -v "$repo/guest/gpu:/repo/guest/gpu:ro" -v "$here:/repo/apps/ios/GPUStream/gfxstream/linux-executor:ro" \
  -v "$out/pictures:/pictures" \
  --entrypoint sh caboose-linux-executor -c "printf %s '$token' > /tmp/token; exec python3 -u \
  /repo/apps/ios/GPUStream/gfxstream/linux-executor/executor.py --connect 127.0.0.1:14600 --token-file /tmp/token \
  --library /build/libcaboose_gpu_executor.so --features $phone --pictures /pictures" > /dev/null
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
  exec timeout 60 $dir/sync_check unmapped_popup" > "$out/client.log" 2>&1 || status=$?
sleep 1
docker logs "$name" > "$out/executor.log" 2>&1
docker exec "$computer" sh -c "tail -n +$((lines + 1)) /home/caboose/.cache/caboose-display.log" > "$out/display.log"
[ "$status" = 0 ] || fail "sync_check exited $status: $(tail -n 1 "$out/client.log")"
grep -q 'CABOOSE_SYNC_CHECK case=unmapped_popup PASS' "$out/client.log" || fail 'the client did not have its 31 presents accepted'
popup=$(sed -n 's/.*case=unmapped_popup .*window=\(0x[0-9a-f]*\).*/\1/p' "$out/client.log")
[ -n "$popup" ] || fail 'the client did not name its window'
grep -q "GPU X11 bind of $popup by process [0-9]* held until the window is bindable" "$out/display.log" ||
  fail "the compositor did not hold the bind of the unmapped window $popup"
window=$(sed -n "s/.*held GPU X11 bind of $popup by process [0-9]* attached to window \([0-9]*\).*/\1/p" "$out/display.log" | tail -n 1)
[ -n "$window" ] || fail "the compositor did not attach the held bind when $popup mapped"
hex=$(printf '%x' "$window")
grep -q "swapchain retired window=0x$hex swapchain=[0-9]* frames=[1-9]" "$out/executor.log" ||
  fail "the executor presented no frame in window $window"
picture="$out/pictures/window-$hex.ppm"
[ -f "$picture" ] || fail "no picture of window $window arrived"
# The client clears to (shade, 0.5, 1 - shade): green is half on in every frame.
python3 -I - "$picture" <<'EOF' || fail "the picture of window $window is black or empty: $picture"
import sys
data = open(sys.argv[1], 'rb').read()
fields, start = [], 0
while len(fields) < 4:
    while data[start:start + 1].isspace(): start += 1
    end = start
    while not data[end:end + 1].isspace(): end += 1
    fields.append(data[start:end]); start = end
magic, width, height = fields[0], int(fields[1]), int(fields[2])
pixels = data[start + 1:]
if magic != b'P6' or not width or not height or len(pixels) < width * height * 3: sys.exit(1)
lit = sum(1 for i in range(0, width * height * 3, 3) if pixels[i + 1] >= 64)
print(f'picture {width}x{height}: {lit} of {width * height} pixels lit')
sys.exit(0 if lit * 2 >= width * height else 1)
EOF
echo "PASS unmapped bind: the bind of unmapped override-redirect window $popup was held, attached to window $window when it mapped, and its picture arrived"
