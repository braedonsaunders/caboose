#!/usr/bin/env bash
# Requires Linux, root, loop devices, erofs-utils, and mount permissions.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
cleanup() {
  set +e
  umount "$work/merged" 2>/dev/null
  umount "$work/lower" 2>/dev/null
  umount "$work" 2>/dev/null
  rmdir "$work" 2>/dev/null
}
trap cleanup EXIT
mount -t tmpfs tmpfs "$work"
mkdir -p "$work/root/usr/bin" "$work/root/opt" "$work/lower" "$work/upper" "$work/work" "$work/merged"
printf 'original\n' > "$work/root/usr/bin/example"
"$here/make-system-image.sh" "$work/root" "$work/system.erofs"
mount -t erofs -o loop,ro "$work/system.erofs" "$work/lower"
options="lowerdir=$work/lower/usr,upperdir=$work/upper,workdir=$work/work"
mount -t overlay overlay -o "$options" "$work/merged"
printf 'updated\n' > "$work/merged/bin/example"
umount "$work/merged"
mount -t overlay overlay -o "$options" "$work/merged"
test "$(cat "$work/merged/bin/example")" = updated
test "$(cat "$work/lower/usr/bin/example")" = original
if printf 'no\n' > "$work/lower/usr/bin/example" 2>/dev/null; then echo 'EROFS lower is writable' >&2; exit 1; fi
echo 'EROFS writable overlay check passed'
