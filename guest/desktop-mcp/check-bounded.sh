#!/usr/bin/env bash
# Linux-only isolated gate. Optional CABOOSE_CHECK_IMAGE=sha256:... reuses a tested image.
# Requires an admitted build slot when no immutable cached image is supplied.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(git -C "$here" rev-parse --show-toplevel)
commit=$(git -C "$root" rev-parse HEAD)
scratch=$(mktemp -d)
git -C "$root" archive "$commit" guest | tar -x -C "$scratch"
here="$scratch/guest/desktop-mcp"
name="caboose-apm-${commit:0:12}-$$"
builder="$name-builder"
container="$name-test"
image=${CABOOSE_CHECK_IMAGE:-}
cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker buildx rm -f "$builder" >/dev/null 2>&1 || true
  rm -rf -- "$scratch"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ -z "$image" ]]; then
  docker buildx create --name "$builder" --driver docker-container \
    --driver-opt image=moby/buildkit@sha256:cec9f139f45e93c5c69c60f8b07cfad9f43f4ef6b6a6cd917527fea5ff2e3dea >/dev/null
  timeout --kill-after=10s 120s docker buildx inspect "$builder" --bootstrap >/dev/null
  builder_container=$(docker ps -aq --filter "name=buildx_buildkit_${builder}0")
  test -n "$builder_container"
  docker update --cpus 2 --memory 4g --memory-swap 4g --pids-limit 512 "$builder_container" >/dev/null
  timeout --kill-after=10s 1800s docker buildx build --builder "$builder" --load \
    -t "$name" -f "$here/check/Dockerfile" "$scratch/guest"
  image=$(docker image inspect "$name" --format '{{.Id}}')
else
  [[ "$image" =~ ^sha256:[a-f0-9]{64}$ ]] || { echo 'CABOOSE_CHECK_IMAGE must be an immutable local image id' >&2; exit 2; }
fi
printf 'commit=%s image=%s\n' "$commit" "$image"
docker run -d --name "$container" --cpus 2 --memory 1500m --memory-swap 1500m \
  --pids-limit 256 --shm-size 256m -v "$here:/src:ro" "$image" >/dev/null
# On timeout, EXIT removes the container, terminating exec and all descendant processes.
timeout --kill-after=10s 180s docker exec "$container" bash /src/check/run.sh
printf 'PASS commit=%s image=%s (retained)\n' "$commit" "$image"
