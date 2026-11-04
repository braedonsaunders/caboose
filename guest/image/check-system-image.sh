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
# Both formats: dax (the default, uncompressed and block-aligned for FS_DAX) and lz4hc.
for format in dax lz4hc; do
  image="$work/system-$format.erofs"
  CABOOSE_SYSTEM_IMAGE_FORMAT=$format "$here/make-system-image.sh" "$work/root" "$image"
  test $(( $(stat -c %s "$image") % 2097152 )) -eq 0
  if [[ $format == lz4hc ]]; then
    test "$(stat -c %s "$image")" -lt "$(stat -c %s "$work/root/opt/compressible")"
  fi
  rm -rf "$work/extracted"
  fsck.erofs --extract="$work/extracted" "$image"
  cmp "$work/root/usr/bin/example" "$work/extracted/usr/bin/example"
  cmp "$work/root/opt/compressible" "$work/extracted/opt/compressible"
  cmp "$work/root/opt/random" "$work/extracted/opt/random"
  test -x "$work/extracted/usr/bin/example"
  test "$(readlink "$work/extracted/usr/example")" = bin/example
  if CABOOSE_SYSTEM_IMAGE_FORMAT=$format "$here/make-system-image.sh" "$work/root" "$image"; then
    echo 'Builder replaced an existing image' >&2; exit 1
  fi
  cmp "$work/root/usr/bin/example" "$work/extracted/usr/bin/example"
done
echo 'EROFS system image check passed'
