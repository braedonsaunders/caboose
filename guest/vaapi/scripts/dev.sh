#!/bin/sh
# Runs a command in the caboose-vaapi dev container (guest/vaapi/Dockerfile) with
# this directory at /src, as the calling user.
#
#   guest/vaapi/scripts/dev.sh make check
#   CABOOSE_VAAPI_DRI=1 guest/vaapi/scripts/dev.sh ...   # pass /dev/dri through (reference decoder)
#
# CPU and memory are capped (CABOOSE_VAAPI_CPUS, default 4; CABOOSE_VAAPI_MEMORY,
# default 4g) so a test run does not starve the rest of the machine.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
image=${CABOOSE_VAAPI_IMAGE:-caboose-vaapi-dev}
set -- --rm -i --init \
  --user "$(id -u):$(id -g)" -e HOME=/tmp \
  --cpus "${CABOOSE_VAAPI_CPUS:-4}" --memory "${CABOOSE_VAAPI_MEMORY:-4g}" --shm-size 512m \
  -v "$here:/src" -w /src \
  ${CABOOSE_VAAPI_DOCKER_ARGS:-} "$image" "$@"
if [ -e /dev/udmabuf ]; then set -- --device /dev/udmabuf --group-add "$(stat -c %g /dev/udmabuf)" "$@"; fi
if [ "${CABOOSE_VAAPI_DRI:-0}" = 1 ] && [ -d /dev/dri ]; then
  for node in /dev/dri/renderD*; do set -- --device "$node" --group-add "$(stat -c %g "$node")" "$@"; done
fi
for var in CBVA_BUILD CBVA_WORK CBVA_SANDBOX; do
  if eval "[ -n \"\${$var:-}\" ]"; then set -- -e "$var" "$@"; fi
done
if [ -t 0 ] && [ -t 1 ]; then set -- -t "$@"; fi
exec docker run "$@"
