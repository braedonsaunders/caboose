#!/bin/sh
# Cold and fresh-process warmed capability queries on a real Linux executor.
#
#   sh apps/ios/GPUStream/gfxstream/linux-executor/check-capabilities.sh IMAGE WORK DRIVER CAPABILITY_PROBE [OUT] [RELEASE]
#
# Runs three independent processes against one real executor. A new private broker
# directory makes the first process cold; later processes reuse its seat cache.
# Reports setup, format/image-format, device and descriptor-query time separately,
# checks identical answers, and requires a clean executor drain. CPUS defaults to 4.
set -eu
[ $# -ge 4 ] && [ $# -le 6 ] || { sed -n '4,15p' "$0" >&2; exit 2; }
image=$1
work=$(cd "$2" && pwd)
driver=$(realpath "$3")
probe=$(realpath "$4")
out=${5:-./linux-executor-check}
release=${6:-}
[ -z "$release" ] || release=$(realpath "$release")
port=14650
sockets=/shared/gpu
token=/shared/gpu/token
mkdir -p "$out"
out=$(cd "$out" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../../../.." && pwd)
name=caboose-capabilities-$$
shared=$(mktemp -d)
chmod 1777 "$shared"
cpus=${CPUS:-4}
phone=guest-handles,guest-handle-arrays,completion-feed,ordered-present,guest-images,guest-query-pools,shader-cache,executor-resume,zstd-stream,upload-cache,guest-buffer-views,batched-descriptor-sets-inline,guest-set-ids
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

cp "$driver" "$shared/libvulkan_gfxstream.so"
cp "$probe" "$shared/sync_check"
if [ -z "$release" ]; then
docker run -d --name "$name-computer" --init --network none --cpus "$cpus" --memory 6g --entrypoint "" \
  -v "$repo/guest/gpu:/repo/guest/gpu:ro" -v "$here:/repo/apps/ios/GPUStream/gfxstream/linux-executor:ro" \
  -v "$shared:/shared" "$image" runuser -u caboose -- env HOME=/tmp python3 -u \
  /repo/apps/ios/GPUStream/gfxstream/linux-executor/broker_host.py --directory /shared/gpu --listen 127.0.0.1:14650 --bind-delay "${BIND_DELAY:-0.4}" --refuse-missing-x11 :99 \
  > /dev/null
wait_log "$name-computer" 'listening on' 30 || fail 'the broker did not start'
docker exec -d -u caboose "$name-computer" Xvfb :99 -screen 0 1920x1080x24 -nolisten tcp
docker exec -u caboose "$name-computer" sh -c 'python3 /repo/guest/gpu/gfxstream/make_manifest.py \
  /shared/libvulkan_gfxstream.so "$(sha256sum /shared/libvulkan_gfxstream.so | cut -d" " -f1)" /tmp/icd.json 1.3.0'
else
  port=14600
  token=/shared/token
  printf 'capability-check-token' > "$shared/token"
  docker run -d --name "$name-computer" --init --network none --cpus "$cpus" --memory 6g --shm-size 256m \
    -v "$release:/release:ro" -v "$shared:/shared" -v "$repo/guest/gpu:/repo/guest/gpu:ro" \
    --entrypoint /bin/sh "$image" -c 'exec sleep infinity' >/dev/null
  docker exec "$name-computer" sh -ec '
    cp -a /release/files/. /
    for deb in /release/debs/*.deb; do [ ! -f "$deb" ] || dpkg -i "$deb" >/dev/null; done
    mkdir -p /run/caboose
    cp /shared/token /run/caboose/display-token
    chmod 0644 /run/caboose/display-token
    python3 /repo/guest/gpu/gfxstream/make_manifest.py /usr/local/lib/caboose-gpu-live/libvulkan_gfxstream.so "$(sha256sum /usr/local/lib/caboose-gpu-live/libvulkan_gfxstream.so | cut -d" " -f1)" /tmp/icd.json 1.3.0
    chmod 0644 /tmp/icd.json
    cp /tmp/icd.json /usr/local/lib/caboose-gpu-live/icd.json
    caboose-session start >/dev/null
    install -d -m700 -o caboose -g caboose /shared/gpu
    ln -s /run/user/1000/caboose-gpu/gpu.sock /shared/gpu/gpu.sock
    ln -s /run/user/1000/caboose-gpu/surface.sock /shared/gpu/surface.sock
  '
fi
app() { # as the seat user, on the guest driver, with the broker's sockets and the display
  docker exec -u caboose "$name-computer" env DISPLAY=:99 HOME=/tmp VK_DRIVER_FILES=/tmp/icd.json \
    VK_LOADER_LAYERS_DISABLE='*' CABOOSE_CAPABILITY_CACHE_DIAGNOSTICS=1 CABOOSE_GFXSTREAM_SOCKET="$sockets/gpu.sock" \
    CABOOSE_GFXSTREAM_SURFACE_SOCKET="$sockets/surface.sock" sh -c 'cd /tmp && exec "$@"' sh "$@"
}
executor() { # features
  docker rm -f "$name-executor" > /dev/null 2>&1 || true
  docker run -d --name "$name-executor" --init --network "container:$name-computer" --cpus "$cpus" --memory 6g \
    -v "$work/build:/build:ro" -v "$repo/guest/gpu:/repo/guest/gpu:ro" \
    -v "$here:/repo/apps/ios/GPUStream/gfxstream/linux-executor:ro" -v "$shared:/shared:ro" caboose-linux-executor \
    python3 -u /repo/apps/ios/GPUStream/gfxstream/linux-executor/executor.py --connect "127.0.0.1:$port" \
    --token-file "$token" --library /build/libcaboose_gpu_executor.so --features "$1" --extra-formats "${EXTRA_FORMATS-37:0,43:0}" > /dev/null
  wait_log "$name-executor" 'session ready' 60 || fail 'the executor session did not start'
  # The broker makes its device socket after the executor's session is ready: an application
  # that started before it would fail its instance (VK_ERROR_INCOMPATIBLE_DRIVER).
  i=0; until docker exec "$name-computer" test -S "$sockets/gpu.sock"; do
    i=$((i + 1)); [ $i -le 150 ] || fail 'the broker never made its device socket'; sleep 0.2; done
}
drain() { # log
  # An executor that already exited keeps its logs for the verdict below.
  docker kill -s TERM "$name-executor" > /dev/null 2>&1 || true
  code=$(docker wait "$name-executor")
  docker logs "$name-executor" > "$1" 2>&1
  [ "$code" = 0 ] && grep -q 'normal close after REVOKED' "$1" || fail "the executor did not drain cleanly ($1)"
}

executor "$phone"
for phase in disabled cold warm fresh; do
  disabled=0; [ "$phase" != disabled ] || disabled=1
  app env CABOOSE_CAPABILITY_CACHE_DISABLE="$disabled" python3 -c 'import subprocess,time; started=time.monotonic(); result=subprocess.run(["/shared/sync_check"],timeout=120); print("CABOOSE_CAPABILITY_PROCESS elapsed_s=%.6f"%(time.monotonic()-started),flush=True); raise SystemExit(result.returncode)' > "$out/$phase.log" 2>&1
  cat "$out/$phase.log"
done
drain "$out/executor.log"
python3 - "$out" <<'PYCHECK'
import pathlib,re,sys
root=pathlib.Path(sys.argv[1])
rows=[]
seconds={}
for name in ('disabled','cold','warm','fresh'):
    text=(root/(name+'.log')).read_text()
    found=re.search(r'CABOOSE_CAPABILITY_QUERIES .*hash=([0-9a-f]+)',text)
    if not found: raise SystemExit('FAIL missing capability report: '+name)
    rows.append(found.group(1))
    counters=re.search(r'CABOOSE_CAPABILITY_CACHE hits=(\d+) misses=(\d+) scopes=(\d+)',text)
    if not counters: raise SystemExit('FAIL missing cache diagnostics: '+name)
    hits,misses,scopes=map(int,counters.groups())
    # The uncached baseline never hits; the cold process asks every question (a repeat of
    # its own earlier answer may hit); the later processes take them from the seat cache.
    if not scopes or (name=='disabled' and (hits or misses<368)) or (name=='cold' and misses<368) or \
            (name in ('warm','fresh') and hits<368):
        raise SystemExit('FAIL incorrect cold/warm cache use: '+name+' '+counters.group(0))
    writes=re.search(r'writes=(\d+) write_bytes=(\d+) write_us=(\d+)',text)
    elapsed=re.search(r'CABOOSE_CAPABILITY_PROCESS elapsed_s=([0-9.]+)',text)
    if not writes or not elapsed: raise SystemExit('FAIL missing write or process timing: '+name)
    count,size,micros=map(int,writes.groups())
    if name=='cold' and not count:
        raise SystemExit('FAIL the cold process kept no answers: '+writes.group(0))
    # Each new answer is one appended record: never a rewrite of earlier records. A record is
    # at most a key of 2*4096+16 bytes and a 64 KiB value (static_query_cache.h kMaxKeyBytes,
    # kMaxValueBytes); a process's device answers (properties chains) reach several KiB.
    if count>misses or size>count*(2*4096+16+65536):
        raise SystemExit('FAIL capability cache rewrote records: '+name+' '+writes.group(0))
    seconds[name]=float(elapsed.group(1))
    print('%-8s process %.3f s, %d records appended, %d bytes, %.3f ms appending'%(name,seconds[name],count,size,micros/1000))
if len(set(rows))!=1: raise SystemExit('FAIL cold/warm capabilities differ')
# An empty cache may cost no more than the uncached baseline beyond run-to-run noise.
if seconds['cold']>seconds['disabled']*1.10+0.05:
    raise SystemExit('FAIL empty-cache process %.3f s is slower than the uncached %.3f s'%(seconds['cold'],seconds['disabled']))
print('PASS identical cold/warm/fresh process capability answers')
PYCHECK
