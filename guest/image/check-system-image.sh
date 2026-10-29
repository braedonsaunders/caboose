#!/usr/bin/env bash
# Run on Linux with erofs-utils, as an unprivileged user.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/root/usr/bin" "$work/root/opt"
printf 'system image check\n' > "$work/root/usr/bin/example"
# Nonzero repeated content must actually compress, without claiming a ratio
# for arbitrary guest software. A random fixture also checks fallback storage.
python3 - "$work/root/opt" <<'FIXTURE'
import os, pathlib, sys
root = pathlib.Path(sys.argv[1])
(root / 'compressible').write_bytes(b'Caboose EROFS check\n'.ljust(4096, b'x') * 1024)
(root / 'random').write_bytes(os.urandom(1024 * 1024))
FIXTURE
chmod 755 "$work/root/usr/bin/example"
ln -s bin/example "$work/root/usr/example"
"$here/make-system-image.sh" "$work/root" "$work/system.erofs"
test "$(stat -c %s "$work/system.erofs")" -lt "$(stat -c %s "$work/root/opt/compressible")"
fsck.erofs --extract="$work/extracted" "$work/system.erofs"
cmp "$work/root/usr/bin/example" "$work/extracted/usr/bin/example"
cmp "$work/root/opt/compressible" "$work/extracted/opt/compressible"
cmp "$work/root/opt/random" "$work/extracted/opt/random"
test -x "$work/extracted/usr/bin/example"
test "$(readlink "$work/extracted/usr/example")" = bin/example
if "$here/make-system-image.sh" "$work/root" "$work/system.erofs"; then
  echo 'Builder replaced an existing image' >&2; exit 1
fi
cmp "$work/root/usr/bin/example" "$work/extracted/usr/bin/example"
echo 'EROFS system image check passed'
