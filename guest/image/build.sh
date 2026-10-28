#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${OUT_DIR:-/data/caboose/disks}
# When the host's XFS mount is private to its container, build on the shared
# bind mount and copy through the container. Never replace an existing desk.
if [[ -n ${CABOOSE_HOST_CONTAINER:-} ]]; then
  [[ "$out" == /data/caboose/disks ]] || { echo 'Container deployment requires OUT_DIR=/data/caboose/disks' >&2; exit 1; }
  docker exec "$CABOOSE_HOST_CONTAINER" sh -c 'test ! -e /data/caboose/disks/base.raw && test ! -e /data/caboose/disks/vmlinux && test ! -e /data/caboose/disks/initrd && test -z "$(ls -A /data/caboose/disks/overlays)"' || { echo 'Image or overlays already exist; refusing to replace them' >&2; exit 1; }
  out=/data/caboose/build
fi
mkdir -p "$out"
for f in base.raw vmlinux initrd; do
  [[ ! -e "$out/$f" ]] || { echo "$out/$f already exists; choose an empty OUT_DIR" >&2; exit 1; }
done
docker build -t caboose-guest-builder -f "$here/Dockerfile" "$here/.."
docker run --rm --privileged -v "$out:/output" caboose-guest-builder
if [[ -n ${CABOOSE_HOST_CONTAINER:-} ]]; then
  docker exec "$CABOOSE_HOST_CONTAINER" sh -c 'test ! -e /data/caboose/disks/base.raw && test ! -e /data/caboose/disks/vmlinux && test ! -e /data/caboose/disks/initrd && test -z "$(ls -A /data/caboose/disks/overlays)" && for file in initrd vmlinux base.raw; do test ! -e "/data/caboose/disks/$file.new" && cp --sparse=always "/data/caboose/build/$file" "/data/caboose/disks/$file.new" || exit; done && for file in initrd vmlinux base.raw; do mv "/data/caboose/disks/$file.new" "/data/caboose/disks/$file" || exit; done'
fi
