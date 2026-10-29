#!/usr/bin/env bash
# Linux: qemu-system-{x86,aarch64}, initramfs-tools-core, cpio, coreutils.
# Usage: timeout --kill-after=15s 360s check-compressed-boot.sh IMAGE_DIR amd64|arm64
# TCG only, 2 vCPUs/1536 MiB, 300s boot deadline, no network; inputs stay read-only.
set -euo pipefail
[[ $# == 2 ]] || { echo 'Usage: check-compressed-boot.sh IMAGE_DIRECTORY amd64|arm64' >&2; exit 2; }
image=$(cd "$1" && pwd)
case $2 in
  amd64) qemu="qemu-system-x86_64"; machine=q35; cpu=max; console=ttyS0; block=virtio-blk-pci; rootbus=pcie.0; systembus=pcie.0 ;;
  arm64) qemu="qemu-system-aarch64"; machine=virt; cpu=max; console=ttyAMA0; block=virtio-blk-device; rootbus=virtio-mmio-bus.0; systembus=virtio-mmio-bus.1 ;;
  *) echo 'Architecture must be amd64 or arm64' >&2; exit 2 ;;
esac
# QEMU's key=value drive syntax requires escaped commas; refuse ambiguous paths.
[[ $image != *,* ]] || { echo 'Image directory must not contain commas' >&2; exit 2; }
for tool in "$qemu" cpio timeout unmkinitramfs; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
for file in base.raw vmlinux initrd system.erofs; do test -s "$image/$file"; done
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$work/extra/scripts/local-bottom"
cat > "$work/extra/scripts/local-bottom/zz-caboose-compressed-check" <<'CHECK'
#!/bin/sh
PREREQ="caboose-system"
case "${1:-}" in prereqs) echo "$PREREQ"; exit 0 ;; esac
. /scripts/functions
fail() { echo "CABOOSE_COMPRESSED_BOOT_FAILED: $*" > /dev/console; poweroff -f; exit 1; }
test "$(cat /sys/block/vda/serial)" = caboose-ci-root || fail 'vda is not root'
test "$(cat /sys/block/vdb/serial)" = caboose-ci-system || fail 'vdb is not system'
test "$(cat /sys/block/vdb/ro)" = 1 || fail 'System attachment is writable'
grep -q " $rootmnt btrfs " /proc/mounts || fail 'Root is not Btrfs'
for option in compress-force=zstd:1 discard=async noatime; do
  awk -v target="$rootmnt" -v option="$option" '
    $2 == target { n=split($4,a,","); for(i=1;i<=n;i++) if(a[i]==option) found=1 }
    END { exit !found }' /proc/mounts || fail "Root lacks $option"
done
grep -q " $rootmnt/.caboose-system erofs " /proc/mounts || fail 'EROFS lower not mounted'
for directory in usr opt; do
  grep -q " $rootmnt/$directory overlay " /proc/mounts || fail "$directory overlay not mounted"
done
# Executing the real guest Python reads the compressed /usr lower. Exercise
# copy-up, new-file writes, whiteouts and an immutable lower in this snapshot.
chroot "$rootmnt" /usr/bin/python3 - <<'PY' || fail 'Guest compressed I/O checks failed'
import errno, pathlib
lower = pathlib.Path('/.caboose-system/usr/bin/true')
original = lower.read_bytes()
assert original
upper = pathlib.Path('/usr/bin/true')
assert upper.read_bytes() == original
upper.write_bytes(original + b'copy-up check')
assert upper.read_bytes() == original + b'copy-up check'
assert lower.read_bytes() == original
upper.unlink()
assert not upper.exists() and lower.read_bytes() == original
for directory in ('/usr', '/opt'):
    marker = pathlib.Path(directory) / '.caboose-compressed-boot-check'
    with marker.open('xb') as f:
        f.write(b'overlay write check')
    assert marker.read_bytes() == b'overlay write check'
    assert not (pathlib.Path('/.caboose-system') / marker.relative_to('/')).exists()
    marker.unlink()
try:
    lower.open('ab').close()
except OSError as error:
    assert error.errno == errno.EROFS
else:
    raise AssertionError('EROFS lower accepted a write open')
PY
sync
echo CABOOSE_COMPRESSED_BOOT_PASSED > /dev/console
poweroff -f
CHECK
chmod 755 "$work/extra/scripts/local-bottom/zz-caboose-compressed-check"
unmkinitramfs "$image/initrd" "$work/unpacked"
# Debian may emit either main/ (with an early archive) or a single archive.
order=
for candidate in "$work/unpacked/main/scripts/local-bottom/ORDER" "$work/unpacked/scripts/local-bottom/ORDER"; do
  if [[ -f $candidate ]]; then order=$candidate; break; fi
done
if [[ -n $order ]]; then
  cp "$order" "$work/extra/scripts/local-bottom/ORDER"
  printf '\n/scripts/local-bottom/zz-caboose-compressed-check "$@"\n' >> "$work/extra/scripts/local-bottom/ORDER"
fi
cp "$image/initrd" "$work/initrd"
(
  cd "$work/extra"
  {
    printf '%s\n' scripts scripts/local-bottom scripts/local-bottom/zz-caboose-compressed-check
    if [[ -f scripts/local-bottom/ORDER ]]; then printf '%s\n' scripts/local-bottom/ORDER; fi
  } | cpio --quiet -o -H newc
) >> "$work/initrd"
# QEMU owns and removes its temporary writable overlay; never open base.raw rw.
TMPDIR="$work" timeout --kill-after=10s 300s "$qemu" \
  -machine "$machine" -cpu "$cpu" -accel tcg,thread=multi -smp 2 -m 1536 \
  -display none -monitor none -serial stdio -no-reboot -nic none \
  -kernel "$image/vmlinux" -initrd "$work/initrd" \
  -append "root=LABEL=caboose rw console=$console panic=-1" \
  -drive "if=none,id=root,file=$image/base.raw,format=raw,snapshot=on,discard=unmap" \
  -device "$block,drive=root,bus=$rootbus,serial=caboose-ci-root" \
  -drive "if=none,id=system,file=$image/system.erofs,format=raw,readonly=on" \
  -device "$block,drive=system,bus=$systembus,serial=caboose-ci-system" 2>&1 | tee "$work/boot.log"
tr -d '\r' < "$work/boot.log" | grep -Fx CABOOSE_COMPRESSED_BOOT_PASSED
if grep -q CABOOSE_COMPRESSED_BOOT_FAILED "$work/boot.log"; then exit 1; fi
echo "$2 boot mounted Btrfs, read EROFS and wrote both system overlays."
