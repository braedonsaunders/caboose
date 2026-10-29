#!/usr/bin/env bash
# Run on Linux with erofs-utils, as an unprivileged user.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/root/usr/bin" "$work/root/opt"
printf 'system image check\n' > "$work/root/usr/bin/example"
chmod 755 "$work/root/usr/bin/example"
ln -s bin/example "$work/root/usr/example"
"$here/make-system-image.sh" "$work/root" "$work/system.erofs"
fsck.erofs --extract="$work/extracted" "$work/system.erofs"
cmp "$work/root/usr/bin/example" "$work/extracted/usr/bin/example"
test -x "$work/extracted/usr/bin/example"
test "$(readlink "$work/extracted/usr/example")" = bin/example
if "$here/make-system-image.sh" "$work/root" "$work/system.erofs"; then
  echo 'Builder replaced an existing image' >&2; exit 1
fi
cmp "$work/root/usr/bin/example" "$work/extracted/usr/bin/example"
echo 'EROFS system image check passed'
