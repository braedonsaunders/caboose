#!/usr/bin/env bash
# Builds a self-contained caboose-host for a native install: the host, its production
# dependencies, the web console, the guest assets it installs, a pinned Node 22 and, on
# Linux, a pinned Cloud Hypervisor and caboose-disk (built with cargo and rustup). Nothing
# on the target machine is needed but a shell.
#
#   apps/host/scripts/bundle.sh <linux|darwin> <amd64|arm64> <outdir>
#
# Writes a .tar.zst bundle on Linux or .tar.gz on macOS, plus SHA256SUMS.
# CABOOSE_VERSION names the release (default: git describe). CABOOSE_BASE_IMAGE and
# CABOOSE_CONTAINER_IMAGE, when set, become the bundle's pinned image defaults.
# Downloads are cached in CABOOSE_BUNDLE_CACHE (default ~/.cache/caboose-bundle).
set -euo pipefail

os=${1:?usage: bundle.sh <linux|darwin> <amd64|arm64> <outdir>}
arch=${2:?usage: bundle.sh <linux|darwin> <amd64|arm64> <outdir>}
out=${3:?usage: bundle.sh <linux|darwin> <amd64|arm64> <outdir>}

NODE_VERSION=v22.23.4
# SHA-256 of each Node tarball, from https://nodejs.org/dist/v22.23.4/SHASUMS256.txt
node_sha() {
  case "$1" in
    linux-x64) echo 1805bcd35e6815559bd2eb97db438d3fdb0eb3a5e6a977b7c1badca76337e9ce ;;
    linux-arm64) echo 6287aa46b6c375d816e63ae66d024fbbfd70404825aabdfdf898a970871d2f4b ;;
    darwin-x64) echo f42abca7aaac61efc57d49fb42ea84fc53bbeba9a749cb03a291ce6e4e7a69c1 ;;
    darwin-arm64) echo 037650d0839f457747396f052073fb48333d31bf5abd3c98b74da20d89ebb1ad ;;
    *) return 1 ;;
  esac
}
CH_VERSION=desk-vmm-v54.0-incremental.1
# Pinned AppKit native VMM archives; these match apps/host/Dockerfile.
ch_asset() {
  case "$1" in
    amd64) echo "desk-vmm-amd64.tar.gz f93fd7128779b57ac6fecb4e42e7d9a2e6ae5a3e88caea84a6c86879b08e6818" ;;
    arm64) echo "desk-vmm-arm64.tar.gz 9fdce8ded9dff25c8c35183995fd979ca509878862d421adc60232b5f7cfd1f7" ;;
  esac
}

case "$os" in linux|darwin) ;; *) echo "Unknown OS $os (linux or darwin)" >&2; exit 2 ;; esac
case "$arch" in amd64) node_arch=x64 ;; arm64) node_arch=arm64 ;; *) echo "Unknown architecture $arch (amd64 or arm64)" >&2; exit 2 ;; esac

repo=$(cd "$(dirname "$0")/../../.." && pwd -P)
cache=${CABOOSE_BUNDLE_CACHE:-$HOME/.cache/caboose-bundle}
version=${CABOOSE_VERSION:-$(git -C "$repo" describe --tags --always --dirty 2>/dev/null || echo dev)}
mkdir -p "$out" "$cache"
out=$(cd "$out" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/caboose-bundle.XXXXXX")
trap 'rm -rf "$work"' EXIT
root=$work/caboose-host

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

# Fetch a URL into the cache once, and refuse it unless it matches the pinned digest.
fetch() {
  local url=$1 digest=$2 file
  file=$cache/$(basename "$url")
  if [[ ! -f $file || $(sha256 "$file") != "$digest" ]]; then
    curl -fsSL --retry 3 -o "$file.part" "$url"
    mv "$file.part" "$file"
  fi
  if [[ $(sha256 "$file") != "$digest" ]]; then
    rm -f "$file"
    echo "$url does not match its pinned SHA-256" >&2
    exit 1
  fi
  printf '%s\n' "$file"
}

echo "Building the host and the console ($version)"
( cd "$repo" && pnpm --filter caboose-web build >/dev/null )
rm -rf "$repo/apps/host/dist"
( cd "$repo/apps/host" && pnpm exec tsc --outDir dist )
cp "$repo"/apps/host/src/*.py "$repo/apps/host/dist/"
find "$repo/apps/host/dist" -name '*.test.js' -delete

echo "Collecting production dependencies"
( cd "$repo" && pnpm --filter caboose-host deploy --prod "$work/host" )
mkdir -p "$root/app/apps/host" "$root/app/apps/web" "$root/app/guest/catalog" "$root/app/guest/container" "$root/bin"
cp -R "$work/host/node_modules" "$work/host/package.json" "$root/app/apps/host/"
cp -R "$repo/apps/host/dist" "$root/app/apps/host/dist"
cp -R "$repo/apps/host/migrations" "$root/app/apps/host/migrations"
mkdir -p "$root/app/apps/host/scripts" "$root/app/apps/host/src" "$root/app/guest/image/initramfs"
cp "$repo/apps/host/scripts/migrate-disk.py" "$root/app/apps/host/scripts/"
cp "$repo/apps/host/src/migration_transaction.py" "$repo/apps/host/src/migration_appliance.py" "$repo/apps/host/src/migration_appliance_guard.py" "$root/app/apps/host/src/"
cp "$repo/guest/image/initramfs/caboose-system" "$root/app/guest/image/initramfs/"
cp -R "$repo/apps/web/dist" "$root/app/apps/web/dist"
# The guest components the host installs: exactly the files their manifest lists.
( cd "$repo/guest" && node -e '
  const { cpSync } = require("fs"), { join } = require("path")
  const out = process.argv[1]
  for (const name of [...JSON.parse(require("fs").readFileSync("components/manifest.json", "utf8")), "components/manifest.json"]) {
    cpSync(name, join(out, name), { recursive: true })
  }' "$root/app/guest" )
cp "$repo/guest/catalog/catalog.json" "$root/app/guest/catalog/"
cp -R "$repo/guest/catalog/icons" "$root/app/guest/catalog/icons"
# The seccomp profile the host gives containers (guest/container/README.md).
cp "$repo/guest/container/caboose-seccomp.json" "$root/app/guest/container/"
cp "$repo/apps/host/scripts/setup-disks.sh" "$root/bin/caboose-setup-disks"
cp "$repo/apps/host/scripts/recover-template-source.sh" "$root/bin/caboose-recover-template-source"

echo "Adding Node $NODE_VERSION ($os-$node_arch)"
node_tar=$(fetch "https://nodejs.org/dist/$NODE_VERSION/node-$NODE_VERSION-$os-$node_arch.tar.xz" "$(node_sha "$os-$node_arch")")
mkdir -p "$root/node/bin"
tar -xJf "$node_tar" -C "$work" "node-$NODE_VERSION-$os-$node_arch/bin/node" "node-$NODE_VERSION-$os-$node_arch/LICENSE"
mv "$work/node-$NODE_VERSION-$os-$node_arch/bin/node" "$root/node/bin/node"
mv "$work/node-$NODE_VERSION-$os-$node_arch/LICENSE" "$root/node/LICENSE"

if [[ $os == linux ]]; then
  read -r ch_name ch_digest <<<"$(ch_asset "$arch")"
  echo "Adding Cloud Hypervisor $CH_VERSION"
  mkdir -p "$root/lib/desk-vmm"
  tar -xzf "$(fetch "https://github.com/braedonsaunders/appkit/releases/download/$CH_VERSION/$ch_name" "$ch_digest")" -C "$root/lib/desk-vmm"
  (cd "$root/lib/desk-vmm" && while read -r digest name; do [[ $(sha256 "$name") == "$digest" ]] || exit 1; done < SHA256SUMS)
  chmod 0755 "$root/lib/desk-vmm/cloud-hypervisor" "$root/lib/desk-vmm/ch-remote"
  ln -s ../lib/desk-vmm/cloud-hypervisor "$root/bin/cloud-hypervisor"
fi

if [[ $os == linux ]]; then
  # A static build, so the bundle runs on any glibc.
  target=$([[ $arch == amd64 ]] && echo x86_64-unknown-linux-musl || echo aarch64-unknown-linux-musl)
  echo "Building caboose-disk ($target)"
  rustup target add "$target" >/dev/null
  cargo build --quiet --release --locked --manifest-path "$repo/apps/host/disk/Cargo.toml" --target "$target" --target-dir "$work/disk"
  cp "$work/disk/$target/release/caboose-disk" "$root/bin/caboose-disk"
fi

if [[ $os == darwin ]]; then
  [[ $(uname -s) == Darwin && $arch == arm64 ]] || { echo 'Build the macOS bundle on Apple Silicon' >&2; exit 1; }
  helper=$(bash "$repo/apps/host/node_modules/@braedonsaunders/appkit-desk/vz/build.sh")
  cp "$helper" "$root/bin/appkit-desk-vz"
  bash "$repo/apps/macos/scripts/build.sh" "$root" >/dev/null
fi

cat >"$root/bin/caboose-host" <<'EOF'
#!/bin/sh
# caboose-host from a bundle: the bundled Node, the bundled Cloud Hypervisor where there is
# one, and the release's pinned images. Variables already in the environment win.
set -eu
self=$0
while [ -L "$self" ]; do
  link=$(readlink "$self")
  case $link in /*) self=$link ;; *) self=$(dirname "$self")/$link ;; esac
done
here=$(CDPATH='' cd -- "$(dirname -- "$self")/.." && pwd -P)
if [ -f "$here/defaults.env" ]; then
  while IFS='=' read -r name value; do
    case $name in '' | '#'* | *[!A-Z0-9_]*) continue ;; esac
    eval "present=\${$name+x}"
    [ "$present" = x ] || export "$name=$value"
  done <"$here/defaults.env"
fi
if [ -f "$here/VERSION" ] && [ -z "${CABOOSE_VERSION-}" ]; then
  CABOOSE_VERSION=$(cat "$here/VERSION")
  export CABOOSE_VERSION
fi
if [ -x "$here/bin/cloud-hypervisor" ] && [ -z "${CABOOSE_VMM_PATH-}" ]; then
  export CABOOSE_VMM_PATH="$here/bin/cloud-hypervisor"
fi
if [ -x "$here/bin/caboose-disk" ] && [ -z "${CABOOSE_DISK_HELPER-}" ]; then
  export CABOOSE_DISK_HELPER="$here/bin/caboose-disk"
fi
if [ -x "$here/bin/appkit-desk-vz" ] && [ -z "${CABOOSE_VMM_PATH-}" ]; then
  export CABOOSE_VMM_PATH="$here/bin/appkit-desk-vz"
fi
exec "$here/node/bin/node" "$here/app/apps/host/dist/index.js" "$@"
EOF
chmod 0755 "$root/bin/caboose-host" "$root/bin/caboose-setup-disks"

{
  echo "# The images this release was built with; the environment overrides them."
  [[ -z ${CABOOSE_BASE_IMAGE:-} ]] || echo "CABOOSE_BASE_IMAGE=$CABOOSE_BASE_IMAGE"
  [[ -z ${CABOOSE_CONTAINER_IMAGE:-} ]] || echo "CABOOSE_CONTAINER_IMAGE=$CABOOSE_CONTAINER_IMAGE"
} >"$root/defaults.env"
printf '%s\n' "$version" >"$root/VERSION"
cp "$repo/LICENSE" "$root/LICENSE"

# Embed a complete, non-recursive install archive. The archive contains the bare menu
# app; only the outer app carries the archive, so installed login apps need no duplicate.
if [[ $os == darwin ]]; then
  resources=$root/Caboose.app/Contents/Resources
  payload=$work/runtime.tar.gz
  COPYFILE_DISABLE=1 tar -C "$work" -czf "$payload" caboose-host
  mkdir -p "$resources"
  mv "$payload" "$resources/runtime.tar.gz"
  cp "$repo/deploy/macos/install.sh" "$resources/install.sh"
  cp "$root/VERSION" "$resources/VERSION"
  codesign --force --sign "${CABOOSE_CODESIGN_IDENTITY:--}" "$root/Caboose.app"
  codesign --verify --strict --deep "$root/Caboose.app"
fi

extension=tar.zst
[[ $os != darwin ]] || extension=tar.gz
name=caboose-host-$os-$arch.$extension
echo "Packing $name"
# No macOS metadata or extended attributes: they mean nothing on the target and GNU tar warns.
tar_flags=()
if tar --version 2>/dev/null | grep -q bsdtar; then tar_flags=(--no-mac-metadata --no-xattrs); fi
if [[ $os == darwin ]]; then
  COPYFILE_DISABLE=1 tar "${tar_flags[@]}" -C "$work" -czf "$out/$name" caboose-host
else
  COPYFILE_DISABLE=1 tar "${tar_flags[@]}" -C "$work" -cf - caboose-host | zstd -q -T2 -19 -o "$out/$name" -f
fi
touch "$out/SHA256SUMS"
grep -v "  $name\$" "$out/SHA256SUMS" >"$out/SHA256SUMS.new" || true
printf '%s  %s\n' "$(sha256 "$out/$name")" "$name" >>"$out/SHA256SUMS.new"
mv "$out/SHA256SUMS.new" "$out/SHA256SUMS"
echo "$out/$name"
