#!/bin/sh
# Build libvulkan_gfxstream.so, the Caboose guest Vulkan driver, from this repository.
# usage: build.sh OUTPUT_DIRECTORY
# Needs Docker and git. The pinned Mesa checkout is fetched once into $CABOOSE_MESA_CACHE
# (default ~/.cache/caboose/mesa-<revision>); the build itself runs without network.
# CABOOSE_BUILD_JOBS (default 4) bounds its parallelism and CPUs; CABOOSE_BUILD_NICE its
# scheduling priority (default 0).
set -eu
if [ "$#" -ne 1 ]; then
    echo "usage: $0 OUTPUT_DIRECTORY" >&2
    exit 2
fi
driver=$(cd "$(dirname "$0")" && pwd)
gfxstream=$(dirname "$driver")
revision=$(sed -n "s/^MESA_REVISION = '\([0-9a-f]*\)'$/\1/p" "$driver/prepare.py")
mesa=${CABOOSE_MESA_CACHE:-$HOME/.cache/caboose/mesa-$revision}
output=$1
mkdir -p "$output"
output=$(cd "$output" && pwd)
if [ -n "$(ls -A "$output")" ]; then
    echo "refusing to build into non-empty $output" >&2
    exit 1
fi
if [ ! -d "$mesa" ]; then
    mkdir -p "$(dirname "$mesa")"
    "$gfxstream/fetch_mesa.sh" "$mesa.partial"
    mv "$mesa.partial" "$mesa"
fi
if [ "$(git -C "$mesa" rev-parse HEAD)" != "$revision" ]; then
    echo "$mesa is not Mesa $revision" >&2
    exit 1
fi
image=caboose-gfxstream-driver:$(sha256sum "$driver/Dockerfile" | cut -c1-12)
docker image inspect "$image" >/dev/null 2>&1 || docker build -t "$image" "$driver"
jobs=${CABOOSE_BUILD_JOBS:-4}
docker run --rm --network none --cpus "$jobs" --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -e CABOOSE_BUILD_JOBS="$jobs" \
    -v "$gfxstream:/caboose:ro" -v "$mesa:/mesa:ro" -v "$output:/out" \
    "$image" nice -n "${CABOOSE_BUILD_NICE:-0}" /caboose/driver/compile.sh
cat "$output/SHA256SUMS"
