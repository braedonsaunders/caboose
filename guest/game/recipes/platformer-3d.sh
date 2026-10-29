#!/usr/bin/env bash
# Makes platformer-3d-4.7.2-6ad6167.tar, the web build of Godot's official 3D platformer demo
# for the games/platformer-3d bundle (guest/game/README.md). Pins Godot 4.7.2-stable (the
# official Linux editor and export templates, checked against the release's SHA512-SUMS.txt)
# and godot-demo-projects at tag 4.7-6ad6167. Runs on x86_64 Linux with curl, unzip and tar;
# WORK is where it downloads and builds.
set -euo pipefail
GODOT_VERSION=4.7.2
GODOT_TAG=${GODOT_VERSION}-stable
DEMO_COMMIT=6ad6167e0577fe3622c18546138f456b107ce93c
WORK=${WORK:-$HOME/caboose-game-build/platformer}
RELEASE=https://github.com/godotengine/godot/releases/download/$GODOT_TAG
mkdir -p "$WORK/dl" && cd "$WORK"

fetch() {
  [ -s "dl/$1" ] && return 0
  curl -fsSL --retry 3 -o "dl/$1.part" "$2"
  mv "dl/$1.part" "dl/$1"
}
fetch SHA512-SUMS.txt "$RELEASE/SHA512-SUMS.txt"
for asset in Godot_v${GODOT_TAG}_linux.x86_64.zip Godot_v${GODOT_TAG}_export_templates.tpz; do
  fetch "$asset" "$RELEASE/$asset"
  (cd dl && grep " $asset\$" SHA512-SUMS.txt | sha512sum -c -)
done
fetch demo.tar.gz "https://codeload.github.com/godotengine/godot-demo-projects/tar.gz/$DEMO_COMMIT"
sha256sum dl/demo.tar.gz > dl/demo.tar.gz.sha256

# Editor and the web templates only.
rm -rf godot templates && mkdir -p godot templates
unzip -q -o dl/Godot_v${GODOT_TAG}_linux.x86_64.zip -d godot
GODOT=$(ls godot/Godot_v${GODOT_TAG}_linux.x86_64)
unzip -q -o dl/Godot_v${GODOT_TAG}_export_templates.tpz 'templates/web_*' 'templates/version.txt' -d .
TEMPLATES=$HOME/.local/share/godot/export_templates/${GODOT_VERSION}.stable
mkdir -p "$TEMPLATES" && cp templates/* "$TEMPLATES/"

rm -rf project build && mkdir -p project build
tar -xzf dl/demo.tar.gz --strip-components=3 -C project "godot-demo-projects-$DEMO_COMMIT/3d/platformer"
cat > project/export_presets.cfg <<'PRESET'
[preset.0]

name="Web"
platform="Web"
runnable=true
dedicated_server=false
custom_features=""
export_filter="all_resources"
include_filter=""
exclude_filter=""
export_path="../build/index.html"

[preset.0.options]

custom_template/debug=""
custom_template/release=""
variant/extensions_support=false
variant/thread_support=false
vram_texture_compression/for_desktop=true
vram_texture_compression/for_mobile=true
html/export_icon=true
html/custom_html_shell=""
html/head_include=""
html/canvas_resize_policy=2
html/focus_canvas_on_start=true
html/experimental_virtual_keyboard=false
progressive_web_app/enabled=false
PRESET

run() { nice -n 19 taskset -c 0,1 timeout 1200 "$GODOT" --headless --path project "$@"; }
run --import
run --export-release Web ../build/index.html
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='2026-10-08 09:25:44Z' \
  -C build -cf platformer-3d-${GODOT_VERSION}-${DEMO_COMMIT:0:7}.tar .
sha256sum platformer-3d-${GODOT_VERSION}-${DEMO_COMMIT:0:7}.tar
