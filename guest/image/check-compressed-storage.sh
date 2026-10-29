#!/usr/bin/env bash
# Linux/root: btrfs-progs, util-linux, fdisk, python3; scratch path must support
# sparse files and loop discard. 60 GiB logical disk, <512 MiB written payload.
# Run: sudo timeout --kill-after=10s 180s guest/image/check-compressed-storage.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=guest/image/storage-layout.sh
source "$here/storage-layout.sh"
[[ $(id -u) == 0 && $(uname -s) == Linux ]] || { echo 'Requires Linux root' >&2; exit 1; }
work=$(mktemp -d)
loop=
cleanup() {
  local status=$?
  trap - EXIT
  if mountpoint -q "$work/root"; then
    umount "$work/root" || { echo "Retained mounted scratch: $work" >&2; exit 1; }
  fi
  if [[ -n $loop ]]; then losetup -d "$loop" || exit 1; fi
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
create_root_disk "$work/base.raw"
sfdisk --verify "$work/base.raw"
sfdisk --json "$work/base.raw" > "$work/partitions.json"
python3 - "$work" <<'PY'
import json, pathlib, sys
w = pathlib.Path(sys.argv[1])
t = json.loads((w / 'partitions.json').read_text())['partitiontable']
assert t['label'] == 'gpt' and t['sectorsize'] == 512
assert [(p['start'], p['size']) for p in t['partitions']] == [
    (2048, 2048), (4096, 2048), (6144, 60 * 1024**3 // 512 - 6144 - 33)]
s = (w / 'base.raw').stat()
assert s.st_size == 60 * 1024**3 and s.st_blocks * 512 < s.st_size
PY
# Refusal must leave both an existing image and a symlink target unchanged.
sha256sum "$work/partitions.json" > "$work/metadata.sha"
if create_root_disk "$work/partitions.json"; then echo 'Overwrote existing file' >&2; exit 1; fi
ln -s "$work/partitions.json" "$work/link"
if create_root_disk "$work/link"; then echo 'Followed existing symlink' >&2; exit 1; fi
sha256sum -c "$work/metadata.sha"
loop=$(attach_root_disk "$work/base.raw")
[[ $(blockdev --getsize64 "$loop") == "$((CABOOSE_ROOT_SECTORS * 512))" ]]
mkfs.btrfs -f -L caboose "$loop"
mkdir "$work/root"
mount -t btrfs -o "$CABOOSE_ROOT_OPTIONS" "$loop" "$work/root"
options=$(findmnt -n -o OPTIONS --target "$work/root")
for option in compress-force=zstd:1 discard=async noatime; do
  [[ ,$options, == *,$option,* ]] || { echo "Missing mount option: $option" >&2; exit 1; }
done
btrfs filesystem sync "$work/root"
fstrim "$work/root"
compressed_before=$(stat -c %b "$work/base.raw")
python3 - "$work/root/compressible" <<'PY'
import pathlib, sys
with pathlib.Path(sys.argv[1]).open('wb') as f:
    for _ in range(4096):
        f.write(b'Caboose compression check\n'.ljust(4096, b'x'))
PY
btrfs filesystem sync "$work/root"
fstrim "$work/root"
compressed_after=$(stat -c %b "$work/base.raw")
# Btrfs inode st_blocks describes uncompressed extent lengths. Measure actual
# host backing allocation instead, including metadata growth from this write.
python3 - "$work/root/compressible" "$compressed_before" "$compressed_after" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.stat()
allocated = (int(sys.argv[3]) - int(sys.argv[2])) * 512
assert 0 < allocated < s.st_size, f'Fixture did not reduce backing allocation: {allocated}'
assert p.read_bytes() == b'Caboose compression check\n'.ljust(4096, b'x') * 4096
print(f'Fixture: {s.st_size} logical bytes, {allocated} additional backing bytes')
PY
# Random data exercises real allocated extents; fstrim must punch holes in the
# backing file after deletion, not merely report successful ioctl submission.
dd if=/dev/urandom of="$work/root/discard-me" bs=1M count=32 status=none
btrfs filesystem sync "$work/root"
fstrim "$work/root"
before=$(stat -c %b "$work/base.raw")
rm "$work/root/discard-me"
btrfs filesystem sync "$work/root"
fstrim "$work/root"
after=$(stat -c %b "$work/base.raw")
(( after < before )) || { echo "Discard did not free backing blocks: $before -> $after" >&2; exit 1; }
umount "$work/root"
# The backup GPT must still be intact after formatting/writing the limited loop.
sfdisk --verify "$work/base.raw"
btrfs check --readonly "$loop"
if ! mount -t btrfs -o ro,nologreplay "$loop" "$work/root"; then
  dmesg | tail -60 >&2
  exit 1
fi
test -s "$work/root/compressible"
echo "Compressed root check passed; discarded $(((before - after) * 512)) backing bytes"
