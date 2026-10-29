#!/bin/bash
# Disposable capability check. Never opens an existing computer disk.
set -euo pipefail
parent=${1:?usage: check-parked-appliance.sh REFLINK_DIRECTORY}
case "$parent" in *[[:space:]\"\']*) echo 'Directory must not contain whitespace or quotes' >&2; exit 2;; esac
work=$(mktemp -d "$parent/.caboose-appliance-check.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/tmp" "$work/cache"
# Some Linux distributions restrict their kernel image to root. Copy it into
# this disposable stage without changing global permissions.
kernel=$(readlink -f /boot/vmlinuz)
version=${kernel##*/vmlinuz-}
test -d "/lib/modules/$version"
if test -r "$kernel"; then cat "$kernel" > "$work/kernel"; else sudo -n cat "$kernel" > "$work/kernel"; fi
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export SUPERMIN_KERNEL="$work/kernel" SUPERMIN_MODULES="/lib/modules/$version" SUPERMIN_KERNEL_VERSION="$version"
export LIBGUESTFS_CACHEDIR="$work/cache" TMPDIR="$work/tmp" LIBGUESTFS_BACKEND=direct
mkdir "$work/files"
printf 'parked-reader-check\n' > "$work/files/check"
for filesystem in ext4 btrfs; do
  # Filesystem construction is userspace only. No guest filesystem is mounted
  # by the host kernel, and all images are disposable.
  truncate -s 256M "$work/$filesystem.raw"
  case "$filesystem" in
    ext4) mkfs.ext4 -q -F -d "$work/files" "$work/$filesystem.raw" ;;
    btrfs) mkfs.btrfs -q -f --rootdir "$work/files" "$work/$filesystem.raw" ;;
  esac
  cp --reflink=always "$work/$filesystem.raw" "$work/$filesystem.clone.raw"
  before=$(sha256sum "$work/$filesystem.raw")
  # Exercise the production RPC reader, including filesystem detection and
  # explicit no-replay mount options, rather than guestfish's default mount.
  printf '%s\n' '{"id":1,"command":"pread","args":["/check","0","20"]}' |
    timeout --kill-after=10s 180s python3 "$here/../src/parked-files-appliance.py" \
      "$work/$filesystem.clone.raw" > "$work/$filesystem.result"
  python3 - "$work/$filesystem.result" "$work/files/check" <<'CHECK'
import base64
import json
from pathlib import Path
import sys
frames = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
assert frames[0] == {'ready': True}, frames
assert len(frames) == 2 and frames[1]['id'] == 1, frames
assert base64.b64decode(frames[1]['result'], validate=True) == Path(sys.argv[2]).read_bytes()
CHECK
  test "$(sha256sum "$work/$filesystem.raw")" = "$before"
  cmp -- "$work/$filesystem.raw" "$work/$filesystem.clone.raw"
  printf 'Disposable %s reflink and byte-equivalent read-only appliance check passed\n' "$filesystem"
done
