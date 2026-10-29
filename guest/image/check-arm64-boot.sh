#!/usr/bin/env bash
# Boot a built split image with software-emulated virtio MMIO; never writes its inputs.
set -euo pipefail
image=${1:?usage: check-arm64-boot.sh IMAGE_DIRECTORY}
for tool in qemu-system-aarch64 cpio timeout unmkinitramfs lsinitramfs python3 gzip; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
for file in base.raw vmlinux initrd system.erofs; do test -s "$image/$file"; done
image=$(cd "$image" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/extra/scripts/local-bottom"
cat > "$work/extra/scripts/local-bottom/00-caboose-device-check" <<'CHECK'
#!/bin/sh
case "${1:-}" in prereqs) exit 0 ;; esac
fail() { echo "CABOOSE_ARM64_BOOT_FAILED: $*" > /dev/console; poweroff -f; exit 1; }
test "$(cat /sys/block/vda/serial 2>/dev/null)" = caboose-ci-root || fail 'vda is not the root attachment'
test "$(cat /sys/block/vdb/serial 2>/dev/null)" = caboose-ci-system || fail 'vdb is not the system attachment'
test "$(cat /sys/block/vdb/ro 2>/dev/null)" = 1 || fail 'system attachment is writable'
echo 'CABOOSE_ARM64_DEVICE_MAPPING: vda=root vdb=system(readonly)' > /dev/console
CHECK
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
chmod 755 "$work/extra/scripts/local-bottom/00-caboose-device-check" "$work/extra/scripts/local-bottom/zz-caboose-boot-check"
# ARM initrds without an early archive extract directly into the destination;
# those with early archives extract their compressed payload into main/.
# Rebuild the main archive instead of appending raw cpio after a compressed stream.
unmkinitramfs "$image/initrd" "$work/unpacked"
main=$(python3 - "$work/unpacked" "$work/extra/scripts/local-bottom" <<'PYTHON'
from pathlib import Path
import shutil
import sys
root, extra = map(Path, sys.argv[1:])
candidates = [path for path in (root, root / 'main') if (path / 'scripts/local-bottom/ORDER').is_file()]
if len(candidates) != 1:
    raise SystemExit('Expected exactly one extracted initramfs main ORDER file')
main = candidates[0]
directory = main / 'scripts/local-bottom'
order = directory / 'ORDER'
original = order.read_text()
for name in ('00-caboose-device-check', 'zz-caboose-boot-check'):
    shutil.copyfile(extra / name, directory / name)
    (directory / name).chmod(0o755)
order.write_text('/scripts/local-bottom/00-caboose-device-check "$@"\n' + original
                 + '\n/scripts/local-bottom/zz-caboose-boot-check "$@"\n')
print(main)
PYTHON
)
echo "Acceptance hooks installed in $main"
: > "$work/initrd"
if [[ $main == "$work/unpacked/main" ]]; then
  for early in "$work/unpacked"/early*; do
    [[ -d $early ]] || continue
    (cd "$early" && find . -print0 | cpio --quiet --null -o -H newc --owner=0:0) >> "$work/initrd"
  done
fi
(cd "$main" && find . -print0 | cpio --quiet --null -o -H newc --owner=0:0 | gzip -1) >> "$work/initrd"
lsinitramfs "$work/initrd" > "$work/files"
for name in 00-caboose-device-check zz-caboose-boot-check; do
  grep -Fx "scripts/local-bottom/$name" "$work/files"
done
boot_log=${CABOOSE_BOOT_LOG:-$work/boot.log}
# The root device uses QEMU's temporary snapshot; the EROFS attachment is read-only.
# No host filesystem, host service, guest network or hardware accelerator is exposed.
# Explicit MMIO buses preserve the production root=vda/system=vdb contract. QEMU's
# automatic bus selection assigns decreasing addresses, reversing current Linux order.
timeout --kill-after=10s 300s qemu-system-aarch64 \
  -machine virt -cpu max -accel tcg,thread=multi -smp 2 -m 1536 \
  -display none -monitor none -serial stdio -no-reboot -nic none \
  -kernel "$image/vmlinux" -initrd "$work/initrd" \
  -append 'root=LABEL=caboose rw console=ttyAMA0 panic=-1' \
  -drive "if=none,id=root,file=$image/base.raw,format=raw,snapshot=on" \
  -device virtio-blk-device,drive=root,bus=virtio-mmio-bus.0,serial=caboose-ci-root \
  -drive "if=none,id=system,file=$image/system.erofs,format=raw,readonly=on" \
  -device virtio-blk-device,drive=system,bus=virtio-mmio-bus.1,serial=caboose-ci-system 2>&1 | tee "$boot_log"
tr -d '\r' < "$boot_log" | grep -Fx CABOOSE_ARM64_BOOT_PASSED
if grep -q CABOOSE_ARM64_BOOT_FAILED "$boot_log"; then exit 1; fi
echo 'ARM64 cloud kernel mounted the split system and ran Python and dpkg.'
