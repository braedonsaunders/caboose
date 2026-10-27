#!/usr/bin/env bash
# Prepare a Caboose host's disk root on a reflink-capable filesystem.
#
# Every computer boots from one golden base.raw plus a per-computer copy-on-write
# overlay made with `cp --reflink`. On XFS (reflink=1) or Btrfs that clone is instant
# and shares blocks; on ext4 it silently becomes a full copy of the whole base image
# on every first boot — minutes of I/O per computer and the disk filling up.
#
# If the target directory already lives on XFS/Btrfs this only creates the layout.
# Otherwise it creates a sparse XFS image file next to it, loop-mounts it there, and
# adds an fstab entry so the mount survives reboots.
#
#   sudo apps/host/scripts/setup-disks.sh /data/caboose-disks 600G
set -euo pipefail

root=${1:?usage: setup-disks.sh <disk-root> [size, default 400G]}
size=${2:-400G}
owner=${SUDO_USER:-$(id -un)}

fs_type() { findmnt -no FSTYPE --target "$1" 2>/dev/null || stat -f -c %T "$1"; }

mkdir -p "$root"
type=$(fs_type "$root")
if [[ $type == xfs || $type == btrfs ]]; then
    echo "$root is on $type; reflink clones are available."
else
    image="${root%/}.xfs.img"
    if [[ ! -e $image ]]; then
        echo "Creating a sparse $size XFS image at $image ($root is on $type)."
        truncate -s "$size" "$image"
        mkfs.xfs -q -m reflink=1 "$image"
    fi
    if ! mountpoint -q "$root"; then
        mount -o loop,noatime "$image" "$root"
    fi
    if ! grep -qs " $root xfs " /etc/fstab; then
        echo "$image $root xfs loop,noatime,nofail 0 0" >> /etc/fstab
    fi
    type=$(fs_type "$root")
fi

mkdir -p "$root/overlays"
chown "$owner": "$root" "$root/overlays"

# Prove it: a reflink clone of a 64 MiB file must succeed.
probe="$root/.reflink-probe"
dd if=/dev/zero of="$probe" bs=1M count=64 status=none
if cp --reflink=always "$probe" "$probe.clone" 2>/dev/null; then
    echo "OK: $root ($type) supports reflink clones."
else
    echo "FAIL: $root ($type) cannot reflink; overlays will be full copies." >&2
    rm -f "$probe" "$probe.clone"
    exit 1
fi
rm -f "$probe" "$probe.clone"
