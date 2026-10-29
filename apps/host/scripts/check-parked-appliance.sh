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
truncate -s 64M "$work/source.raw"
mkfs.ext4 -q -F "$work/source.raw"
printf 'parked-reader-check\n' > "$work/input"
debugfs -w -R "write $work/input /check" "$work/source.raw" >/dev/null 2>&1
cp --reflink=always "$work/source.raw" "$work/clone.raw"
# guestfish boots a separate libguestfs appliance; ext4 is never mounted by the host kernel.
actual=$(SUPERMIN_KERNEL="$work/kernel" SUPERMIN_MODULES="/lib/modules/$version" SUPERMIN_KERNEL_VERSION="$version" LIBGUESTFS_CACHEDIR="$work/cache" TMPDIR="$work/tmp" LIBGUESTFS_BACKEND=direct LIBGUESTFS_MEMSIZE=256 timeout --kill-after=10s 180s guestfish --ro --format=raw -a "$work/clone.raw" -m /dev/sda cat /check)
test "$actual" = 'parked-reader-check'
printf 'Disposable reflink and read-only guestfs appliance check passed\n'
