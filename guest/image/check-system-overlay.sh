#!/usr/bin/env bash
# Linux/root: erofs-utils, btrfs-progs, e2fsprogs, util-linux; two sequential
# 512 MiB sparse scratch disks. Checks both new Btrfs and existing ext4 uppers.
# Run: sudo timeout --kill-after=10s 180s guest/image/check-system-overlay.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
loop=
cleanup() {
  local status=$?
  trap - EXIT
  for target in merged lower writable; do
    if mountpoint -q "$work/$target"; then
      umount "$work/$target" || { echo "Retained mounted scratch: $work" >&2; exit 1; }
    fi
  done
  if [[ -n $loop ]]; then losetup -d "$loop" || exit 1; fi
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$work/root/usr/bin" "$work/root/opt" "$work/lower" "$work/writable" "$work/merged"
printf 'original\n' > "$work/root/usr/bin/example"
"$here/make-system-image.sh" "$work/root" "$work/system.erofs"
mount -t erofs -o loop,ro "$work/system.erofs" "$work/lower"
for filesystem in btrfs ext4; do
  truncate -s 512M "$work/$filesystem.raw"
  loop=$(losetup --find --show "$work/$filesystem.raw")
  if [[ $filesystem == btrfs ]]; then
    mkfs.btrfs -f "$loop"
    mount -t btrfs -o compress-force=zstd:1,discard=async,noatime "$loop" "$work/writable"
  else
    mkfs.ext4 -F "$loop"
    mount -t ext4 -o noatime "$loop" "$work/writable"
  fi
  mkdir "$work/writable/upper" "$work/writable/work"
  options="lowerdir=$work/lower/usr,upperdir=$work/writable/upper,workdir=$work/writable/work"
  mount -t overlay overlay -o "$options" "$work/merged"
  printf 'updated\n' > "$work/merged/bin/example"
  printf 'new\n' > "$work/merged/bin/new"
  sync -f "$work/merged"
  umount "$work/merged"
  umount "$work/writable"
  mount "$loop" "$work/writable"
  mount -t overlay overlay -o "$options" "$work/merged"
  test "$(cat "$work/merged/bin/example")" = updated
  test "$(cat "$work/merged/bin/new")" = new
  test "$(cat "$work/lower/usr/bin/example")" = original
  rm "$work/merged/bin/example"
  umount "$work/merged"
  mount -t overlay overlay -o "$options" "$work/merged"
  test ! -e "$work/merged/bin/example"
  test -f "$work/lower/usr/bin/example"
  if printf 'no\n' > "$work/lower/usr/bin/example" 2>/dev/null; then echo 'EROFS lower is writable' >&2; exit 1; fi
  umount "$work/merged"
  umount "$work/writable"
  losetup -d "$loop"; loop=
  echo "EROFS writable overlay check passed on $filesystem"
done
