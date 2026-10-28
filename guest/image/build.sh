#!/usr/bin/env bash
set -euo pipefail

# Build a disposable image first; publish only a completely customized image.
DIR=$(cd "$(dirname "$0")" && pwd)
OUT_DIR=${OUT_DIR:-$DIR/out}
BUNKHOUSE_REV=307f2eee512f27459843a588b38200f57abb6bcf
DESK_VERSION=0.6.0
export LIBGUESTFS_BACKEND=direct
for cmd in curl git npm qemu-img virt-resize virt-customize virt-get-kernel; do
  command -v "$cmd" >/dev/null || { echo "Missing $cmd" >&2; exit 1; }
done
mkdir -p "$OUT_DIR"
OUT_DIR=$(cd "$OUT_DIR" && pwd)
exec 9>"$OUT_DIR/.build.lock"
flock -n 9 || { echo 'Another build is running' >&2; exit 1; }
if [[ -e "$OUT_DIR/base.raw" || -e "$OUT_DIR/vmlinux" || -e "$OUT_DIR/initrd" ]]; then
  if [[ -f "$OUT_DIR/.complete" && -f "$OUT_DIR/base.raw" && -f "$OUT_DIR/vmlinux" && -f "$OUT_DIR/initrd" ]]; then
    echo "Image already built at $OUT_DIR; use a new OUT_DIR to rebuild."
    exit 0
  fi
  echo "Incomplete output in $OUT_DIR; move it aside before rebuilding" >&2; exit 1
fi
work=$(mktemp -d "$OUT_DIR/.build.XXXXXX")
trap 'rm -rf "$work"' EXIT
curl -fL --retry 3 https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2 -o "$work/debian.qcow2"
qemu-img create -f raw "$work/base.raw" 24G
virt-resize --expand /dev/sda1 "$work/debian.qcow2" "$work/base.raw"
git init -q "$work/bunkhouse"
git -C "$work/bunkhouse" fetch -q --depth 1 https://github.com/braedonsaunders/bunkhouse.git "$BUNKHOUSE_REV"
git -C "$work/bunkhouse" checkout -q --detach FETCH_HEAD
mkdir -p "$work/stage/desk-agent/appkit-desk" "$work/npm"
npm pack "@braedonsaunders/appkit-desk@$DESK_VERSION" --pack-destination "$work/npm" >/dev/null
tar -xzf "$work/npm/"*.tgz -C "$work/npm"
for file in events.js guest-agent.js protocol.js; do cp "$work/npm/package/$file" "$work/stage/desk-agent/appkit-desk/"; done
cp "$work/bunkhouse/deploy/desk-image/agent/"{desk-guest-agent.mjs,atspi-dump.py,package.json} "$work/stage/desk-agent/"
cp "$work/bunkhouse/deploy/desk-image/agent/"{desk-guest-agent.service,desk-vsock-bridge.service} "$work/stage/"
sed -i 's@HOME=/home/agent@HOME=/home/caboose@' "$work/stage/desk-guest-agent.service"
virt-customize -a "$work/base.raw" \
  --copy-in "$work/stage/desk-agent:/opt" \
  --copy-in "$work/stage/desk-guest-agent.service:/etc/systemd/system" \
  --copy-in "$work/stage/desk-vsock-bridge.service:/etc/systemd/system" \
  --copy-in "$DIR/caboose-xpra.service:/etc/systemd/system" \
  --copy-in "$DIR/caboose-xpra-agent.service:/etc/systemd/system" \
  --run "$DIR/customize.sh"
mkdir "$work/kernel"
virt-get-kernel -a "$work/base.raw" -o "$work/kernel"
kernel=$(compgen -G "$work/kernel/vmlinuz-*" | sort -V | tail -1)
initrd=$(compgen -G "$work/kernel/initrd.img-*" | sort -V | tail -1)
[[ -n "$kernel" && -n "$initrd" ]]
mv "$kernel" "$OUT_DIR/vmlinux"
mv "$initrd" "$OUT_DIR/initrd"
mv "$work/base.raw" "$OUT_DIR/base.raw"
printf '%s\n' "$BUNKHOUSE_REV appkit-desk@$DESK_VERSION" > "$OUT_DIR/.complete"
echo "Image built at $OUT_DIR"
