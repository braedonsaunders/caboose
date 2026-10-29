#!/usr/bin/env bash
# Boot a built split image with software-emulated virtio MMIO; never writes its inputs.
set -euo pipefail
image=${1:?usage: check-arm64-boot.sh IMAGE_DIRECTORY}
for tool in qemu-system-aarch64 cpio timeout unmkinitramfs; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
for file in base.raw vmlinux initrd system.erofs; do test -s "$image/$file"; done
image=$(cd "$image" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/extra/scripts/local-bottom"
cat > "$work/extra/scripts/local-bottom/zz-caboose-boot-check" <<'CHECK'
#!/bin/sh
PREREQ="caboose-system"
case "${1:-}" in prereqs) echo "$PREREQ"; exit 0 ;; esac
. /scripts/functions
fail() { echo "CABOOSE_ARM64_BOOT_FAILED: $*" > /dev/console; poweroff -f; exit 1; }
grep -q ' /.caboose-system erofs ' "$rootmnt/proc/mounts" 2>/dev/null ||
  grep -q " $rootmnt/.caboose-system erofs " /proc/mounts || fail 'EROFS lower not mounted'
for directory in usr opt; do
  grep -q " $rootmnt/$directory overlay " /proc/mounts || fail "$directory overlay not mounted"
done
chroot "$rootmnt" /usr/bin/python3 --version || fail 'Python cannot execute'
chroot "$rootmnt" /usr/bin/dpkg --audit > /tmp/dpkg-audit 2>&1 || fail 'dpkg audit failed'
test ! -s /tmp/dpkg-audit || { cat /tmp/dpkg-audit > /dev/console; fail 'dpkg audit is not clean'; }
test -s "$rootmnt/etc/dpkg/dpkg.cfg.d/caboose-excludes" || fail 'dpkg excludes absent'
ls "$rootmnt"/boot/config-*-cloud-arm64 >/dev/null 2>&1 || fail 'cloud arm64 kernel absent'
echo CABOOSE_ARM64_BOOT_PASSED > /dev/console
poweroff -f
CHECK
chmod 755 "$work/extra/scripts/local-bottom/zz-caboose-boot-check"
# initramfs-tools may use a generated ORDER file instead of enumerating hooks.
# Preserve its existing order and run our acceptance hook after all original hooks.
unmkinitramfs "$image/initrd" "$work/unpacked"
if [[ -f "$work/unpacked/main/scripts/local-bottom/ORDER" ]]; then
  cp "$work/unpacked/main/scripts/local-bottom/ORDER" "$work/extra/scripts/local-bottom/ORDER"
  printf '\n/scripts/local-bottom/zz-caboose-boot-check "$@"\n' >> "$work/extra/scripts/local-bottom/ORDER"
fi
cp "$image/initrd" "$work/initrd"
(
  cd "$work/extra"
  {
    printf '%s\n' scripts scripts/local-bottom scripts/local-bottom/zz-caboose-boot-check
    if [[ -f scripts/local-bottom/ORDER ]]; then printf '%s\n' scripts/local-bottom/ORDER; fi
  } | cpio --quiet -o -H newc
) >> "$work/initrd"
# The root device uses QEMU's temporary snapshot; the EROFS attachment is read-only.
# No host filesystem, host service, guest network or hardware accelerator is exposed.
timeout --kill-after=10s 300s qemu-system-aarch64 \
  -machine virt -cpu max -accel tcg,thread=multi -smp 2 -m 1536 \
  -display none -monitor none -serial stdio -no-reboot -nic none \
  -kernel "$image/vmlinux" -initrd "$work/initrd" \
  -append 'root=LABEL=caboose rw console=ttyAMA0 panic=-1' \
  -drive "if=none,id=root,file=$image/base.raw,format=raw,snapshot=on" \
  -device virtio-blk-device,drive=root \
  -drive "if=none,id=system,file=$image/system.erofs,format=raw,readonly=on" \
  -device virtio-blk-device,drive=system 2>&1 | tee "$work/boot.log"
tr -d '\r' < "$work/boot.log" | grep -Fx CABOOSE_ARM64_BOOT_PASSED
if grep -q CABOOSE_ARM64_BOOT_FAILED "$work/boot.log"; then exit 1; fi
echo 'ARM64 cloud kernel mounted the split system and ran Python and dpkg.'
