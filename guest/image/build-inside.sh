#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
work=$(mktemp -d /output/.build.XXXXXX)
loop=
cleanup() {
  status=$?
  set +e
  for p in dev/pts dev proc sys; do umount -l "$work/root/$p" 2>/dev/null; done
  umount "$work/root" 2>/dev/null
  [[ -z $loop ]] || losetup -d "$loop"
  if [[ $status -eq 0 ]]; then
    rm -rf "$work"
  else
    echo "Build failed; retained work directory: $work" >&2
  fi
}
trap cleanup EXIT
truncate -s 16G "$work/base.raw"
sfdisk "$work/base.raw" <<'PARTS'
label: gpt
start=2048, size=2048, type=linux
size=2048, type=linux
type=linux
PARTS
# Containers often have loop-control but lack device nodes for unused loops.
for n in $(seq 0 255); do [[ -b /dev/loop$n ]] || mknod -m 0660 /dev/loop$n b 7 "$n"; done
# Partition 3 starts at sector 6144; attach its contents directly. This avoids
# relying on udev to create loop partition nodes in the container.
loop=$(losetup --find --show --offset $((6144 * 512)) --sizelimit $((33546240 * 512)) "$work/base.raw")
mkfs.ext4 -F -L caboose "$loop"
mkdir "$work/root"
mount "$loop" "$work/root"
# The disposable image is synced before publication; avoid per-file fsyncs
# during the initial package install, which are costly on loop-backed storage.
mkdir -p "$work/root/etc/dpkg/dpkg.cfg.d"
printf 'force-unsafe-io\n' > "$work/root/etc/dpkg/dpkg.cfg.d/99-caboose-build"
mkdir -p "$work/root/usr/local/lib"
cp /usr/lib/x86_64-linux-gnu/libeatmydata.so.1 "$work/root/usr/local/lib/libeatmydata.so.1"
# The same path exists inside and outside the chroot for inherited LD_PRELOAD.
mkdir -p /usr/local/lib
cp /usr/lib/x86_64-linux-gnu/libeatmydata.so.1 /usr/local/lib/libeatmydata.so.1
LD_PRELOAD=/usr/local/lib/libeatmydata.so.1 debootstrap --variant=minbase --arch=amd64 trixie "$work/root" https://deb.debian.org/debian
for p in proc sys dev; do mount --rbind "/$p" "$work/root/$p"; mount --make-rslave "$work/root/$p"; done
cp /builder/configure-guest.sh /builder/apps.sh "$work/root/tmp/"
cp -r /builder/components "$work/root/tmp/components"
cp -r /builder/files "$work/root/tmp/files"
cp -r /builder/terminal "$work/root/tmp/terminal"
cp -r /builder/desktop-mcp "$work/root/tmp/desktop-mcp"
cp -r /builder/display "$work/root/tmp/caboose-display"
cp -r /builder/agentd "$work/root/tmp/agentd"
cp -r /builder/notifications "$work/root/tmp/notifications"
cp -r /builder/phone "$work/root/tmp/phone"
cp /etc/resolv.conf "$work/root/etc/resolv.conf"
chroot "$work/root" /usr/bin/env LD_PRELOAD=/usr/local/lib/libeatmydata.so.1 /bin/bash /tmp/configure-guest.sh
cp "$(ls "$work/root"/boot/vmlinuz-* | sort -V | tail -1)" "$work/vmlinux"
cp "$(ls "$work/root"/boot/initrd.img-* | sort -V | tail -1)" "$work/initrd"
rm -f "$work/root/usr/local/lib/libeatmydata.so.1" "$work/root/etc/dpkg/dpkg.cfg.d/99-caboose-build" "$work/root/etc/dpkg/dpkg.cfg.d/99-build-speed"
rm -rf "$work/root/tmp/components" "$work/root/tmp/notifications" "$work/root/tmp/desktop-mcp" "$work/root/tmp/caboose-display" "$work/root/tmp/agentd" "$work/root/tmp/files" "$work/root/tmp/terminal" "$work/root/tmp/phone"
rm "$work/root/tmp/configure-guest.sh" "$work/root/tmp/apps.sh"
# Complete update work after the final /usr changes to avoid a slow first boot.
chroot "$work/root" /sbin/ldconfig
chroot "$work/root" /usr/lib/systemd/systemd-update-done
sync
for p in dev/pts dev proc sys; do umount -l "$work/root/$p" 2>/dev/null || true; done
umount "$work/root"
losetup -d "$loop"; loop=
mv "$work/initrd" /output/initrd
mv "$work/vmlinux" /output/vmlinux
mv "$work/base.raw" /output/base.raw
