#!/usr/bin/env bash
# Linux: qemu-system-{x86,aarch64}, initramfs-tools-core, cpio, coreutils.
# Usage: timeout --kill-after=15s 360s check-compressed-boot.sh IMAGE_DIR amd64|arm64
# TCG only, 2 vCPUs/1536 MiB, 300s boot deadline, no network; inputs stay read-only.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
[[ $# == 2 ]] || { echo 'Usage: check-compressed-boot.sh IMAGE_DIRECTORY amd64|arm64' >&2; exit 2; }
image=$(cd "$1" && pwd)
case $2 in
  amd64) qemu="qemu-system-x86_64"; machine=q35; cpu=max; console=ttyS0; block=virtio-blk-pci; rootbus=pcie.0; systembus=pcie.0 ;;
  arm64) qemu="qemu-system-aarch64"; machine=virt; cpu=max; console=ttyAMA0; block=virtio-blk-device; rootbus=virtio-mmio-bus.0; systembus=virtio-mmio-bus.1 ;;
  *) echo 'Architecture must be amd64 or arm64' >&2; exit 2 ;;
esac
# QEMU's key=value drive syntax requires escaped commas; refuse ambiguous paths.
[[ $image != *,* ]] || { echo 'Image directory must not contain commas' >&2; exit 2; }
for tool in "$qemu" cpio timeout unmkinitramfs lsinitramfs python3 gzip; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
for file in base.raw vmlinux initrd system.erofs; do test -s "$image/$file"; done
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$work/extra/scripts/local-bottom"
cat > "$work/extra/scripts/local-bottom/00-caboose-device-check" <<'CHECK'
#!/bin/sh
case "${1:-}" in prereqs) exit 0 ;; esac
fail() { echo "CABOOSE_COMPRESSED_BOOT_FAILED: $*" > /dev/console; poweroff -f; exit 1; }
test "$(cat /sys/block/vda/serial)" = caboose-ci-root || fail 'vda is not root'
test "$(cat /sys/block/vdb/serial)" = caboose-ci-system || fail 'vdb is not system'
test "$(cat /sys/block/vdb/ro)" = 1 || fail 'System attachment is writable'
echo CABOOSE_COMPRESSED_DEVICE_MAPPING_PASSED > /dev/console
CHECK
cat > "$work/extra/scripts/local-bottom/zz-caboose-boot-check" <<'CHECK'
#!/bin/sh
PREREQ="caboose-system"
case "${1:-}" in prereqs) echo "$PREREQ"; exit 0 ;; esac
. /scripts/functions
fail() { echo "CABOOSE_COMPRESSED_BOOT_FAILED: $*" > /dev/console; poweroff -f; exit 1; }
root_options=
lower=no
usr_overlay=no
opt_overlay=no
while read -r _device target filesystem options _rest; do
  case "$target:$filesystem" in
    "$rootmnt:btrfs") root_options=$options ;;
    "$rootmnt/.caboose-system:erofs") lower=yes ;;
    "$rootmnt/usr:overlay") usr_overlay=yes ;;
    "$rootmnt/opt:overlay") opt_overlay=yes ;;
  esac
done < /proc/mounts
[ -n "$root_options" ] || fail 'Root is not Btrfs'
for option in compress-force=zstd:1 discard=async noatime; do
  case ",$root_options," in *,"$option",*) ;; *) fail "Root lacks $option" ;; esac
done
[ "$lower" = yes ] || fail 'EROFS lower not mounted'
[ "$usr_overlay" = yes ] && [ "$opt_overlay" = yes ] || fail 'System overlays not mounted'
# Executing the real guest Python reads the compressed /usr lower. Exercise
# copy-up, new-file writes, whiteouts and an immutable lower in this snapshot.
chroot "$rootmnt" /usr/bin/python3 - <<'PY' || fail 'Guest compressed I/O checks failed'
import errno, pathlib, subprocess
excludes = pathlib.Path('/etc/dpkg/dpkg.cfg.d/caboose-excludes').read_text()
for rule in ('path-exclude=/usr/share/doc/*', 'path-include=/usr/share/doc/*/copyright',
             'path-exclude=/usr/share/info/*', 'path-exclude=/usr/share/lintian/*'):
    assert rule in excludes
assert pathlib.Path('/usr/share/doc/base-files/copyright').is_file()
assert not subprocess.check_output(['dpkg', '--audit'], text=True).strip()
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
# Rebuild the extracted archive so the hook cannot be silently skipped after
# a compressed stream. Preserve early archives and the original hook order.
unmkinitramfs "$image/initrd" "$work/unpacked"
main=$(python3 "$here/boot_check.py" "$work/unpacked" "$work/extra/scripts/local-bottom")
: > "$work/initrd"
if [[ $main == "$work/unpacked/main" ]]; then
  for early in "$work/unpacked"/early*; do
    [[ -d $early ]] || continue
    (cd "$early" && find . -print0 | cpio --quiet --null -o -H newc --owner=0:0) >> "$work/initrd"
  done
fi
(cd "$main" && find . -print0 | cpio --quiet --null -o -H newc --owner=0:0 | gzip -1) >> "$work/initrd"
lsinitramfs "$work/initrd" | sed 's@^\./@@' > "$work/files"
for name in 00-caboose-device-check zz-caboose-boot-check; do
  grep -Fx "scripts/local-bottom/$name" "$work/files"
done
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
