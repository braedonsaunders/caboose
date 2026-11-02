#!/usr/bin/env bash
# Pack a prepared guest's /usr and /opt without modifying the source tree.
set -euo pipefail
format=${CABOOSE_SYSTEM_IMAGE_FORMAT:-dax}
while [[ $# -gt 0 ]]; do
  case $1 in
    --dax) format=dax; shift ;;
    --lz4hc) format=lz4hc; shift ;;
    --) shift; break ;;
    -*) echo 'Usage: make-system-image.sh [--dax|--lz4hc] ROOT OUTPUT' >&2; exit 2 ;;
    *) break ;;
  esac
done
if [[ $# != 2 ]]; then echo 'Usage: make-system-image.sh [--dax|--lz4hc] ROOT OUTPUT' >&2; exit 2; fi
case $format in
  dax|lz4hc) ;;
  *) echo "Unsupported CABOOSE_SYSTEM_IMAGE_FORMAT: $format (expected dax or lz4hc)" >&2; exit 2 ;;
esac
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
if [[ $format == dax ]]; then
  # Uncompressed 4096-byte block-aligned EROFS without inline tail data for FS_DAX.
  if ! mkfs.erofs -b 4096 -E noinline_data "$part" "$stage" 2>/dev/null; then
    rm -f "$part"
    mkfs.erofs -E noinline_data "$part" "$stage"
  fi
else
  # LZ4HC level 12, with a maximum physical cluster size of 64 KiB.
  mkfs.erofs -zlz4hc,12 -C65536 "$part" "$stage"
fi
# Pad to a 2 MiB multiple so virtio-pmem and PMD DAX alignment (CONFIG_FS_DAX_PMD=y) are satisfied.
truncate -s %2097152 "$part"
fsck.erofs "$part"
# Refuse to overwrite even if another writer published during the build.
ln "$part" "$out"
