#!/bin/sh
# A GL client whose executor leaves mid-frame must unwind and exit.
#
#   sh apps/ios/GPUStream/gfxstream/linux-executor/check-gl-loss.sh IMAGE WORK DRIVER GL_LOSS_EXIT [OUT]
#
# Runs GL_LOSS_EXIT (guest/gpu/gfxstream/driver/sync-check/gl_loss_exit.c) on the guest driver
# through Zink, rendering and flushing every frame, ends the real Linux executor while it
# renders, and requires the program to tear its context down and exit within 30 s of its run.
# A client stuck after the loss (Zink spinning in context teardown) fails. CPUS defaults to 4.
# COMPUTER=NAME runs in that running computer instead of a disposable one made from IMAGE:
# the broker is hosted there on a port of its own, so the computer's own executor is untouched.
set -eu
# Nothing a check starts leaves a core dump, and nothing it starts crowds out the rest of the
# host: crashes are expected while the checks end programs (the host turns each into a capture of
# several gigabytes), and the host is shared. Every container this script runs gets a core
# limit of 0 and, unless it sets its own, at most 4 CPUs and 6 GB of memory; every command it
# runs in a computer runs at the lowest priority with a core limit of 0 (prlimit and nice,
# before the command).
ulimit -c 0
renice -n 19 $$ > /dev/null 2>&1 || :
docker() {
  if [ "${1:-}" = run ]; then
    shift
    case " $* " in *" --cpus "*) set -- --ulimit core=0 "$@" ;; *) set -- --ulimit core=0 --cpus 4 "$@" ;; esac
    case " $* " in *" --memory "*) ;; *) set -- --memory 6g "$@" ;; esac
    command docker run "$@"; return
  fi
  if [ "${1:-}" != exec ]; then command docker "$@"; return; fi
  shift
  _count=$# _seen=0 _state=option
  while [ "$_seen" -lt "$_count" ]; do
    _arg=$1; shift; _seen=$((_seen + 1))
    case $_state in
      option) case $_arg in
        -u|-e|-w|--user|--env|--workdir) set -- "$@" "$_arg" "$1"; shift; _seen=$((_seen + 1)) ;;
        -*) set -- "$@" "$_arg" ;;
        *) set -- "$@" "$_arg" prlimit --core=0:0 -- nice -n 19; _state=command ;;
      esac ;;
      command) set -- "$@" "$_arg" ;;
    esac
  done
  command docker exec "$@"
}
[ $# -ge 4 ] && [ $# -le 5 ] || { sed -n '4,12p' "$0" >&2; exit 2; }
image=$1
work=$(cd "$2" && pwd)
driver=$(realpath "$3")
probe=$(realpath "$4")
out=${5:-./linux-executor-gl-loss}
mkdir -p "$out"; out=$(cd "$out" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../../../.." && pwd)
name=caboose-gl-loss-$$
cpus=${CPUS:-4}
port=14650
phone=guest-handles,guest-handle-arrays,completion-feed,ordered-present,guest-images,guest-query-pools,executor-resume,zstd-stream,guest-buffer-views,batched-descriptor-sets-inline
fail() { echo "FAIL: $*" >&2; exit 1; }
if [ -n "${COMPUTER:-}" ]; then
  computer=$COMPUTER; dir=/tmp/$name
  cleanup() {
    docker rm -f "$name-executor" > /dev/null 2>&1 || true
    # pkill on its own: a shell running it would match the pattern too.
    docker exec "$computer" pkill -TERM -f "$dir/" > /dev/null 2>&1 || true
    sleep 1
    docker exec "$computer" pkill -KILL -f "$dir/" > /dev/null 2>&1 || true
    docker exec "$computer" rm -rf "$dir" > /dev/null 2>&1 || true
  }
  trap cleanup EXIT INT TERM
  docker exec "$computer" sh -c "mkdir -m 0755 -p $dir/repo/apps/ios/GPUStream/gfxstream $dir/repo/guest $dir/shared && chown caboose $dir/shared"
  docker cp -q "$repo/guest/gpu" "$computer:$dir/repo/guest/"
  docker cp -q "$here" "$computer:$dir/repo/apps/ios/GPUStream/gfxstream/"
  docker cp -q "$driver" "$computer:$dir/shared/libvulkan_gfxstream.so"
  docker cp -q "$probe" "$computer:$dir/shared/gl_loss_exit"
  docker exec "$computer" sh -c "chmod -R a+rX $dir; chown -R caboose $dir/shared"
  shared=$dir/shared; tree=$dir/repo
  docker exec -d -u caboose "$computer" sh -c "env HOME=/tmp python3 -u $tree/apps/ios/GPUStream/gfxstream/linux-executor/broker_host.py \
    --directory $shared/gpu --listen 127.0.0.1:$port > $shared/broker.log 2>&1"
  computer_log() { docker exec "$computer" cat "$shared/broker.log" 2>/dev/null; }
else
  computer=$name-computer; host_shared=$(mktemp -d); chmod 1777 "$host_shared"
  cleanup() { docker rm -f "$name-executor" "$name-computer" > /dev/null 2>&1 || true; rm -rf "$host_shared"; }
  trap cleanup EXIT INT TERM
  cp "$driver" "$host_shared/libvulkan_gfxstream.so"; cp "$probe" "$host_shared/gl_loss_exit"
  shared=/shared; tree=/repo
  docker run -d --name "$computer" --init --network none --cpus "$cpus" --memory 6g --device /dev/dri/renderD128 \
    --entrypoint "" -v "$repo/guest/gpu:/repo/guest/gpu:ro" -v "$here:/repo/apps/ios/GPUStream/gfxstream/linux-executor:ro" \
    -v "$host_shared:/shared" "$image" runuser -u caboose -- env HOME=/tmp python3 -u \
    /repo/apps/ios/GPUStream/gfxstream/linux-executor/broker_host.py --directory /shared/gpu --listen 127.0.0.1:$port > /dev/null
  computer_log() { docker logs "$computer" 2>&1; }
fi
wait_for() { i=0; while ! "$1" | grep -q "$2"; do i=$((i + 1)); [ $i -le $(($3 * 5)) ] || return 1; sleep 0.2; done; }
executor_log() { docker logs "$name-executor" 2>&1; }
wait_for computer_log 'listening on' 30 || fail 'the broker did not start'
docker exec -u caboose "$computer" sh -c "python3 $tree/guest/gpu/gfxstream/make_manifest.py \
  $shared/libvulkan_gfxstream.so \"\$(sha256sum $shared/libvulkan_gfxstream.so | cut -d' ' -f1)\" $shared/icd.json 1.3.0"
token=$(docker exec "$computer" cat "$shared/gpu/token")
docker run -d --name "$name-executor" --init --network "container:$computer" --cpus "$cpus" --memory 6g \
  -v "$work/build:/build:ro" -v "$repo/guest/gpu:/repo/guest/gpu:ro" -v "$here:/repo/apps/ios/GPUStream/gfxstream/linux-executor:ro" \
  --entrypoint sh caboose-linux-executor -c "printf %s '$token' > /tmp/token; exec python3 -u \
  /repo/apps/ios/GPUStream/gfxstream/linux-executor/executor.py --connect 127.0.0.1:$port \
  --token-file /tmp/token --library /build/libcaboose_gpu_executor.so --features $phone" > /dev/null
wait_for executor_log 'session ready' 60 || fail 'the executor session did not start'
seconds=${SECONDS_RENDERING:-12}
docker exec -d -u caboose "$computer" sh -c "env HOME=/tmp VK_DRIVER_FILES=$shared/icd.json VK_LOADER_LAYERS_DISABLE='*' GALLIUM_DRIVER=zink \
  CABOOSE_GFXSTREAM_SOCKET=$shared/gpu/gpu.sock $shared/gl_loss_exit $seconds > $shared/gl.log 2>&1; \
  echo exit=\$? >> $shared/gl.log"
sleep 4
docker exec "$computer" grep -q CABOOSE_GPU_HELLO "$shared/gl.log" || fail 'the GL client did not reach the executor'
# The executor leaves mid-frame, as a phone that drops off the network does (KEEP_EXECUTOR=1
# keeps it, for the same client's teardown with its executor present).
[ -n "${KEEP_EXECUTOR:-}" ] || docker rm -f "$name-executor" > /dev/null
i=0
until docker exec "$computer" grep -q '^exit=' "$shared/gl.log"; do
  i=$((i + 1)); [ $i -le $(((seconds + 30) * 2)) ] || { docker exec "$computer" cat "$shared/gl.log" > "$out/gl.log" 2>&1; fail "the GL client did not exit after its executor left ($out/gl.log)"; }
  sleep 0.5
done
docker exec "$computer" cat "$shared/gl.log" > "$out/gl.log"
grep -q '^exit=0' "$out/gl.log" && grep -q 'CABOOSE_GL_LOSS' "$out/gl.log" || fail "the GL client failed ($out/gl.log)"
echo "PASS GL client unwound after its executor left: $(grep -o 'frames=[0-9]* teardown_ms=[0-9.]*' "$out/gl.log")"
