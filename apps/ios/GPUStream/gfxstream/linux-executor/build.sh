#!/bin/sh
# Builds the Linux executor's native runtime, WORK/build/libcaboose_gpu_executor.so, in a
# Debian container (Dockerfile) from the gfxstream fork at the commit fork.env pins.
#
#   sh apps/ios/GPUStream/gfxstream/linux-executor/build.sh WORK [GFXSTREAM_CHECKOUT]
#
# Without GFXSTREAM_CHECKOUT the fork is cloned into WORK/gfxstream (read access needed).
# A given checkout must be at the pinned commit; the v4 profile check verifies its decoder
# inputs either way. CPUS (default 4) bounds the container.
set -eu
[ $# -ge 1 ] && [ $# -le 2 ] || { echo "usage: $0 WORK [GFXSTREAM_CHECKOUT]" >&2; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
ADAPTER=$(dirname "$HERE")
mkdir -p "$1"
WORK=$(cd "$1" && pwd)
. "$ADAPTER/fork.env"
if [ $# -eq 2 ]; then
  SOURCE=$(cd "$2" && pwd)
else
  SOURCE=$WORK/gfxstream
  if [ ! -d "$SOURCE/.git" ]; then
    git clone -q --filter=blob:none --no-checkout "$GFXSTREAM_REPOSITORY" "$SOURCE"
  fi
  git -C "$SOURCE" fetch -q origin "$GFXSTREAM_BRANCH"
  git -C "$SOURCE" checkout -q --detach "$GFXSTREAM_COMMIT"
fi
if [ -d "$SOURCE/.git" ] && [ "$(git -C "$SOURCE" rev-parse HEAD)" != "$GFXSTREAM_COMMIT" ]; then
  echo "$SOURCE is not at the pinned $GFXSTREAM_COMMIT" >&2; exit 1
fi
python3 "$ADAPTER/generate-v4-profile.py" "$SOURCE" --check --patched
docker build -q -t caboose-linux-executor "$HERE" > /dev/null
run() {
  docker run --rm --network none --cpus "${CPUS:-4}" --memory 6g -v "$ADAPTER:/adapter:ro" \
    -v "$SOURCE:/gfxstream:ro" -v "$WORK:/work" caboose-linux-executor "$@"
}
run cmake -S /adapter/linux-executor -B /work/build -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DDEPENDENCY_RESOLUTION=SYSTEM -DCABOOSE_GFXSTREAM_SOURCE=/gfxstream > /dev/null
run cmake --build /work/build --target caboose_gpu_executor -- -j"${CPUS:-4}"
echo "gfxstream $GFXSTREAM_COMMIT: $WORK/build/libcaboose_gpu_executor.so"
