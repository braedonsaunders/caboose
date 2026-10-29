#!/usr/bin/env bash
# Package the release's self-installing app with the Applications shortcut.
set -euo pipefail
bundle=${1:?usage: package-dmg.sh bundle.tar.gz output.dmg}
out=${2:?usage: package-dmg.sh bundle.tar.gz output.dmg}
work=$(mktemp -d "${TMPDIR:-/tmp}/caboose-dmg.XXXXXX")
trap 'rm -rf "$work"' EXIT
tar -xzf "$bundle" -C "$work"
app=$work/caboose-host/Caboose.app
[[ -f $app/Contents/Resources/runtime.tar.gz ]] || { echo 'App lacks embedded runtime' >&2; exit 1; }
codesign --verify --strict --deep "$app"
mkdir "$work/volume"
mv "$app" "$work/volume/"
ln -s /Applications "$work/volume/Applications"
mkdir -p "$(dirname "$out")"
hdiutil create -ov -format UDZO -volname Caboose -srcfolder "$work/volume" "$out"
name=$(basename "$out")
parent=$(cd "$(dirname "$out")" && pwd -P)
(cd "$parent" && shasum -a 256 "$name" > "$name.sha256")
if [[ -f $parent/SHA256SUMS ]]; then
  awk -v name="$name" '$2 != name' "$parent/SHA256SUMS" > "$work/sums"
else touch "$work/sums"; fi
cat "$parent/$name.sha256" >> "$work/sums"
mv "$work/sums" "$parent/SHA256SUMS"
