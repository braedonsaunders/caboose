#!/bin/sh
# Chromium draws real pictures through a seat's GPU, and a fresh one still does after the
# seat's executor was lost and replaced, on a running computer.
#
#   sh apps/ios/GPUStream/gfxstream/linux-executor/check-loss-pixels.sh COMPUTER WORK DRIVER [OUT]
#
# COMPUTER is a running computer with Chromium (/usr/bin/chromium). The check makes a seat of
# its own there: a caboose-display on its own port, token, Wayland socket, X display and
# private GPU sockets (none of the computer's own session is used), with DRIVER (the guest
# driver under test) for the compositor and its clients, the real Linux executor (WORK/build)
# serving it with --pictures, and caboose-display-probe as the viewer. Chromium (ANGLE on
# Zink, a Wayland client whose frames are phone-resident dma-bufs) shows a page with a fresh
# profile in a home of the check's own. Then the executor and the viewer are ended mid-run, as
# a phone that leaves ends them, and new ones connect; the compositor and Xwayland live on
# through the loss, as a seat's do. A fresh Chromium must then draw its page too. Each phase
# requires a presented picture that is neither noise nor blank (surfaces.content: a repeat
# fraction from MIN_REPEAT (default 0.3) to 0.999 and at least 3 colours). SECONDS_RUNNING
# (default 25) is each Chromium's time.
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
[ $# -ge 3 ] && [ $# -le 4 ] || { sed -n '4,18p' "$0" >&2; exit 2; }
computer=$1
work=$(cd "$2" && pwd)
driver=$(realpath "$3")
out=${4:-./linux-executor-loss-pixels}
mkdir -p "$out"; out=$(cd "$out" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../../../.." && pwd)
seconds=${SECONDS_RUNNING:-25}
min_repeat=${MIN_REPEAT:-0.3}
port=14690
xdisplay=179
name=caboose-loss-pixels-$$
dir=/tmp/caboose-loss-pixels-$$
phone=guest-handles,guest-handle-arrays,completion-feed,ordered-present,guest-images,guest-query-pools,executor-resume,zstd-stream,guest-buffer-views,batched-descriptor-sets-inline
fail() { echo "FAIL: $*" >&2; exit 1; }
seat() { docker exec "$computer" sh -c "$1"; }
cleanup() {
  for phase in first second; do docker logs "$name-$phase" > "$out/executor-$phase.log" 2>&1 || true; docker rm -f "$name-$phase" > /dev/null 2>&1 || true; done
  # pkill on its own: a shell running it would match the pattern too.
  docker exec "$computer" pkill -TERM -f "$dir/" > /dev/null 2>&1 || true
  sleep 2
  docker exec "$computer" pkill -KILL -f "$dir/" > /dev/null 2>&1 || true
  docker exec "$computer" cat "$dir/display.log" > "$out/display.log" 2>/dev/null || true
  docker exec "$computer" rm -rf "$dir" > /dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
rm -rf "$out/first" "$out/second"; mkdir -p "$out/first" "$out/second"; chmod 777 "$out/first" "$out/second"
seat "mkdir -m 0700 -p $dir/run/gpu $dir/home"
docker cp -q "$driver" "$computer:$dir/libvulkan_gfxstream.so"
seat "printf '%s' '{\"file_format_version\":\"1.0.0\",\"ICD\":{\"library_path\":\"$dir/libvulkan_gfxstream.so\",\"api_version\":\"1.3.0\"}}' > $dir/icd.json
  head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' > $dir/token; chown -R caboose $dir"
# The seat: its own compositor, broker and sockets, under a runtime directory of its own.
seat "cat > $dir/env <<ENV
export PATH=/usr/local/bin:/usr/bin:/bin HOME=$dir/home XDG_RUNTIME_DIR=$dir/run
export VK_DRIVER_FILES=$dir/icd.json:/usr/share/vulkan/icd.d/lvp_icd.json CABOOSE_GPU_ROUTING=1 NODEVICE_SELECT=1
export GALLIUM_DRIVER=zink LIBGL_KOPPER_DRI2=1 MESA_GL_VERSION_OVERRIDE=4.5COMPAT MESA_GLSL_VERSION_OVERRIDE=450 MESA_GLES_VERSION_OVERRIDE=3.2 ZINK_DESCRIPTORS=lazy
export CABOOSE_GAME_SOCKET=$dir/run/game.sock
ENV
chown caboose $dir/env"
docker exec -d -u caboose "$computer" sh -c ". $dir/env; exec caboose-display --listen 127.0.0.1:$port --token-file $dir/token \
  --socket wayland-loss-pixels --x-display $xdisplay --no-audio --no-devices --private-gpu-stream-socket $dir/run/gpu/gpu.sock \
  --private-gpu-surface-socket $dir/run/gpu/surface.sock --private-gpu-indexed --env-file $dir/display.env \
  --display 1280x800@60x1 > $dir/display.log 2>&1"
i=0; until seat "test -s $dir/display.env"; do i=$((i + 1)); [ $i -le 150 ] || fail 'the seat did not start'; sleep 0.2; done
token=$(seat "cat $dir/token")
start_executor() {
  docker run -d --name "$name-$1" --init --network "container:$computer" --cpus 4 --memory 4g \
    -v "$work/build:/build:ro" -v "$repo/guest/gpu:/repo/guest/gpu:ro" -v "$here:/repo/apps/ios/GPUStream/gfxstream/linux-executor:ro" \
    -v "$out/$1:/pictures" --entrypoint sh caboose-linux-executor -c "printf %s '$token' > /tmp/token; exec python3 -u \
    /repo/apps/ios/GPUStream/gfxstream/linux-executor/executor.py --connect 127.0.0.1:$port --token-file /tmp/token \
    --library /build/libcaboose_gpu_executor.so --features $phone --pictures /pictures --display 1280x800" > /dev/null
  i=0; until docker logs "$name-$1" 2>&1 | grep -q 'session ready'; do i=$((i + 1)); [ $i -le 150 ] || fail "$1 executor readiness"; sleep 0.2; done
}
start_executor first
viewer() {
  docker exec -d -u caboose "$computer" sh -c "exec caboose-display-probe --url ws://127.0.0.1:$port/ --token-file $dir/token \
    --duration $((seconds * 3 + 60)) --display 1280x800@60x1 > $dir/probe-$1.log 2>&1"
}
viewer first
sleep 3
page='data:text/html,<body style="margin:0;background:%23e8f0ff;font:48px sans-serif"><h1 style="background:%23204080;color:%23ffd040">Caboose</h1><p>The quick brown fox jumps over the lazy dog.</p></body>'
chromium() {
  docker exec -d -u caboose "$computer" sh -c ". $dir/env; set -a; . $dir/display.env; set +a
    export CABOOSE_GFXSTREAM_SOCKET=$dir/run/gpu/gpu.sock CABOOSE_GFXSTREAM_SURFACE_SOCKET=$dir/run/gpu/surface.sock
    exec timeout $2 /usr/bin/chromium --user-data-dir=$dir/home/chromium-$1 --no-first-run --no-default-browser-check \
      --password-store=basic --ozone-platform=wayland --ignore-gpu-blocklist --use-gl=angle --use-angle=gl \
      --window-size=900,600 '$page' > $dir/chromium-$1.log 2>&1"
}
# The best picture of a phase: the largest repeat fraction below 0.999 with 3 colours or more.
judge() {
  grep -a -o 'picture window=[^ ]* serial=[0-9]* [0-9x]* format=[0-9]* content=[0-9.]* colours=[0-9]*' "$out/executor-$1.log" |
    awk -v min="$min_repeat" '{ split($6, c, "="); split($7, n, "="); if (c[2] >= min && c[2] < 0.999 && n[2] >= 3) good++; else bad++ }
      END { printf "%d %d\n", good + 0, bad + 0 }'
}
chromium first $((seconds * 2))
sleep "$seconds"
docker logs "$name-first" > "$out/executor-first.log" 2>&1
set -- $(judge first)
[ "$1" -gt 0 ] || fail "Chromium drew no real picture before the loss ($2 pictures were noise or blank: $out/first)"
echo "first Chromium: $1 real pictures, $2 noise or blank"
# The executor leaves mid-run, as a phone that drops off does; the phone's display connection
# goes with it, and a new executor and display connection come back.
docker rm -f "$name-first" > /dev/null
seat "pkill -TERM -f 'caboose-display-probe --url ws://127.0.0.1:$port/'" > /dev/null 2>&1 || true
sleep 3
start_executor second
viewer second
sleep 5
seat "pkill -TERM -f '$dir/home/chromium-first'" > /dev/null 2>&1 || true
sleep 2
chromium second "$seconds"
sleep "$seconds"
docker logs "$name-second" > "$out/executor-second.log" 2>&1
set -- $(judge second)
[ "$1" -gt 0 ] || fail "a fresh Chromium drew no real picture after the executor was replaced ($2 pictures were noise or blank: $out/second)"
echo "PASS loss pixels: Chromium drew real pictures before the loss and a fresh one after it ($1 real, $2 noise or blank)"
