#!/usr/bin/env bash
# Pack a prepared guest's /usr and /opt without modifying the source tree.
set -euo pipefail
if [[ $# != 2 ]]; then echo 'Usage: make-system-image.sh ROOT OUTPUT' >&2; exit 2; fi
root=$(realpath "$1")
out=$2
[[ -d "$root/usr" && -d "$root/opt" ]] || { echo 'ROOT must contain usr and opt' >&2; exit 1; }
[[ ! -e "$out" ]] || { echo 'Output already exists' >&2; exit 1; }
command -v mkfs.erofs >/dev/null
command -v fsck.erofs >/dev/null
stage=$(mktemp -d)
part="${out}.part.$$"
cleanup() { rm -rf "$stage"; rm -f "$part"; }
trap cleanup EXIT
cp -a "$root/usr" "$root/opt" "$stage/"
# No compression or inline file data: eligible files can use filesystem DAX
# when the device and guest kernel support it.
mkfs.erofs -E noinline_data "$part" "$stage"
fsck.erofs "$part"
# Refuse to overwrite even if another writer published during the build.
ln "$part" "$out"
