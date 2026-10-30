#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
arch=$(dpkg --print-architecture)
case $arch in amd64) triplet=x86_64-linux-gnu ;; arm64) triplet=aarch64-linux-gnu ;; *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; esac
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
# Shared with the scratch-device validation; never applied to an existing disk.
# shellcheck source=guest/image/storage-layout.sh
source /builder/storage-layout.sh
create_root_disk "$work/base.raw"
# Containers often have loop-control but lack device nodes for unused loops.
for n in $(seq 0 255); do [[ -b /dev/loop$n ]] || mknod -m 0660 /dev/loop$n b 7 "$n"; done
# Attach only partition 3, excluding the backup GPT at the end of the disk.
loop=$(attach_root_disk "$work/base.raw")
mkfs.btrfs -f -L caboose "$loop"
mkdir "$work/root"
mount -t btrfs -o "$CABOOSE_ROOT_OPTIONS" "$loop" "$work/root"
# The disposable image is synced before publication; avoid per-file fsyncs
# during the initial package install, which are costly on loop-backed storage.
mkdir -p "$work/root/etc/dpkg/dpkg.cfg.d"
printf 'force-unsafe-io\n' > "$work/root/etc/dpkg/dpkg.cfg.d/99-caboose-build"
mkdir -p "$work/root/usr/local/lib"
cp /usr/lib/$triplet/libeatmydata.so.1 "$work/root/usr/local/lib/libeatmydata.so.1"
# The same path exists inside and outside the chroot for inherited LD_PRELOAD.
mkdir -p /usr/local/lib
cp /usr/lib/$triplet/libeatmydata.so.1 /usr/local/lib/libeatmydata.so.1
LD_PRELOAD=/usr/local/lib/libeatmydata.so.1 debootstrap --variant=minbase --arch="$arch" trixie "$work/root" https://deb.debian.org/debian
for p in proc sys dev; do mount --rbind "/$p" "$work/root/$p"; mount --make-rslave "$work/root/$p"; done
cp /builder/configure-guest.sh /builder/apps.sh /builder/desktop-apps.sh /builder/desktop-apps.tsv "$work/root/tmp/"
cp -r /builder/components "$work/root/tmp/components"
cp -r /builder/template "$work/root/tmp/template"
cp -r /builder/keyring "$work/root/tmp/keyring"
cp -r /builder/container "$work/root/tmp/container"
cp -r /builder/files "$work/root/tmp/files"
cp -r /builder/terminal "$work/root/tmp/terminal"
cp -r /builder/desktop-mcp "$work/root/tmp/desktop-mcp"
cp -r /builder/display "$work/root/tmp/caboose-display"
cp -r /builder/agentd "$work/root/tmp/agentd"
cp -r /builder/notifications "$work/root/tmp/notifications"
cp -r /builder/phone "$work/root/tmp/phone"
cp -r /builder/bridge "$work/root/tmp/bridge"
cp -r /builder/flatpak "$work/root/tmp/flatpak"
cp -r /builder/game "$work/root/tmp/game"
cp -r /builder/gpu "$work/root/tmp/gpu"
cp -r /builder/apps "$work/root/tmp/apps"
cp -r /builder/media-handoff "$work/root/tmp/media-handoff"
cp /etc/resolv.conf "$work/root/etc/resolv.conf"
install -D -m 0755 /builder/caboose-storage "$work/root/etc/initramfs-tools/scripts/local-bottom/caboose-storage"
chroot "$work/root" /usr/bin/env LD_PRELOAD=/usr/local/lib/libeatmydata.so.1 /bin/bash /tmp/configure-guest.sh
kernel=$(printf '%s\n' "$work/root"/boot/vmlinuz-* | sort -V | tail -1)
# Virtualization.framework takes the uncompressed ARM64 Image; Debian may gzip it.
if [[ $arch == arm64 ]] && gzip -t "$kernel" 2>/dev/null; then gzip -dc "$kernel" > "$work/vmlinux"
else cp "$kernel" "$work/vmlinux"; fi
rm -f "$work/root/usr/local/lib/libeatmydata.so.1" "$work/root/etc/dpkg/dpkg.cfg.d/99-caboose-build" "$work/root/etc/dpkg/dpkg.cfg.d/99-build-speed"
rm -rf "$work/root/tmp/template" "$work/root/tmp/components" "$work/root/tmp/container" "$work/root/tmp/keyring" "$work/root/tmp/notifications" "$work/root/tmp/desktop-mcp" "$work/root/tmp/caboose-display" "$work/root/tmp/agentd" "$work/root/tmp/files" "$work/root/tmp/terminal" "$work/root/tmp/phone" "$work/root/tmp/bridge" "$work/root/tmp/flatpak" "$work/root/tmp/game" "$work/root/tmp/gpu" "$work/root/tmp/apps" "$work/root/tmp/media-handoff"
rm "$work/root/tmp/configure-guest.sh" "$work/root/tmp/apps.sh" "$work/root/tmp/desktop-apps.sh" "$work/root/tmp/desktop-apps.tsv"
# Complete update work after the final /usr changes to avoid a slow first boot.
chroot "$work/root" /sbin/ldconfig
chroot "$work/root" /usr/lib/systemd/systemd-update-done
if [[ ${CABOOSE_SPLIT_SYSTEM:-0} == 1 ]]; then
  install -m 0755 /builder/caboose-system "$work/root/etc/initramfs-tools/scripts/local-bottom/caboose-system"
  printf 'erofs\noverlay\n' >> "$work/root/etc/initramfs-tools/modules"
  chroot "$work/root" update-initramfs -u
  touch "$work/root/etc/caboose-split-system"
  /builder/make-system-image.sh "$work/root" "$work/system.erofs"
fi
cp "$(printf '%s\n' "$work/root"/boot/initrd.img-* | sort -V | tail -1)" "$work/initrd"
if [[ ${CABOOSE_SPLIT_SYSTEM:-0} == 1 ]]; then
  rm -rf "$work/root/usr" "$work/root/opt"
  mkdir "$work/root/usr" "$work/root/opt"
fi
# Flush deleted package and split-system extents, then punch their backing-file
# holes through loop discard. This also trims ordinary (non-split) images.
sync
btrfs filesystem sync "$work/root"
fstrim -v "$work/root"
for p in dev/pts dev proc sys; do umount -l "$work/root/$p" 2>/dev/null || true; done
umount "$work/root"
losetup -d "$loop"; loop=
mv "$work/initrd" /output/initrd
mv "$work/vmlinux" /output/vmlinux
mv "$work/base.raw" /output/base.raw
if [[ ${CABOOSE_SPLIT_SYSTEM:-0} == 1 ]]; then mv "$work/system.erofs" /output/system.erofs; fi
