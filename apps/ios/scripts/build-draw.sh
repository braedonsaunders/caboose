#!/bin/sh
# Builds CabooseDraw.xcframework from source: Skia at the commit pinned below (Ganesh on Metal,
# nothing else) and the draw-list renderer in apps/ios/Draw, for iOS, the iOS simulator and
# macOS (CabooseKit's tests).
#
#   sh apps/ios/scripts/build-draw.sh OUTPUT_DIR      # usually apps/ios/CabooseKit/Frameworks
#
# CABOOSE_SKIA_ROOT (default ~/Library/Caches/caboose-skia) keeps the Skia checkout and its
# builds between runs; CABOOSE_SKIA_JOBS (default 3) caps ninja's parallelism. Needs Xcode,
# Python 3, Ninja and git.
set -eu
[ $# -eq 1 ] || { echo "usage: $0 OUTPUT_DIR" >&2; exit 2; }
OUT=$1
[ ! -e "$OUT/CabooseDraw.xcframework" ] || { echo "$OUT/CabooseDraw.xcframework exists" >&2; exit 1; }
IOS=$(cd "$(dirname "$0")/.." && pwd)
DRAW=$IOS/Draw
# Skia milestone 157 (refs/heads/chrome/m157).
SKIA_COMMIT=ca84ce0a6f1659748188469a89361ccea71e3a64
ROOT=${CABOOSE_SKIA_ROOT:-$HOME/Library/Caches/caboose-skia}
JOBS=${CABOOSE_SKIA_JOBS:-3}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
SKIA=$ROOT/src
mkdir -p "$SKIA" "$OUT"

# 1. Skia at the pinned commit, and its gn.
if [ "$(git -C "$SKIA" rev-parse HEAD 2>/dev/null)" != "$SKIA_COMMIT" ]; then
  git -C "$SKIA" init -q
  git -C "$SKIA" remote add origin https://skia.googlesource.com/skia 2>/dev/null || true
  git -C "$SKIA" fetch -q --depth 1 origin "$SKIA_COMMIT"
  git -C "$SKIA" checkout -q FETCH_HEAD
fi
[ -x "$SKIA/bin/gn" ] || (cd "$SKIA" && python3 bin/fetch-gn)

# Ganesh on Metal and nothing that needs a third-party library: no codecs, no fonts (draw
# lists carry glyph outlines), no shaping, no PDF or SVG.
COMMON='is_official_build=true is_debug=false skia_use_metal=true skia_use_gl=false skia_enable_graphite=false
  skia_enable_ganesh=true skia_use_expat=false skia_use_zlib=false skia_use_icu=false skia_use_harfbuzz=false
  skia_use_freetype=false skia_use_fontconfig=false skia_enable_fontmgr_empty=true skia_use_fonthost_mac=false
  skia_use_libjpeg_turbo_decode=false skia_use_libjpeg_turbo_encode=false skia_use_libpng_decode=false
  skia_use_libpng_encode=false skia_use_libwebp_decode=false skia_use_libwebp_encode=false skia_use_wuffs=false
  skia_use_dng_sdk=false skia_use_piex=false skia_use_xps=false skia_enable_pdf=false skia_enable_svg=false
  skia_enable_skottie=false skia_enable_skshaper=false skia_enable_skparagraph=false skia_enable_tools=false
  skia_use_partition_alloc=false'

# build NAME GN_ARGS CLANG_TARGET SDK
build() {
  name=$1 args=$2 triple=$3 sdk=$4
  dir=$ROOT/out/$name
  (cd "$SKIA" && bin/gn gen "$dir" --args="$COMMON $args" >/dev/null)
  ninja -C "$dir" -j "$JOBS" skia >/dev/null
  defines=$(cd "$SKIA" && bin/gn desc "$dir" //:skia defines --format=json 2>/dev/null |
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join("-D"+x for v in d.values() for x in v.get("defines", [])))' || true)
  # shellcheck disable=SC2086
  xcrun --sdk "$sdk" clang++ -std=c++20 -fobjc-arc -O2 -fvisibility=hidden -target "$triple" \
    $defines -DSK_GANESH -DSK_METAL -I"$SKIA" -I"$DRAW/include" -c "$DRAW/src/renderer.mm" -o "$dir/renderer.o"
  libtool -static -o "$dir/libCabooseDraw.a" "$dir/renderer.o" "$dir/libskia.a" "$dir/libskcms.a" 2>/dev/null
}

build mac 'target_os="mac" target_cpu="arm64"' arm64-apple-macos15.0 macosx
build ios 'target_os="ios" target_cpu="arm64" ios_min_target="17.0"' arm64-apple-ios17.0 iphoneos
build ios-sim 'target_os="ios" target_cpu="arm64" ios_use_simulator=true ios_min_target="17.0"' \
  arm64-apple-ios17.0-simulator iphonesimulator

headers=$(mktemp -d)
cp "$DRAW/include/CabooseDraw.h" "$headers/"
printf 'module CabooseDraw {\n    header "CabooseDraw.h"\n    export *\n}\n' > "$headers/module.modulemap"
xcodebuild -create-xcframework \
  -library "$ROOT/out/mac/libCabooseDraw.a" -headers "$headers" \
  -library "$ROOT/out/ios/libCabooseDraw.a" -headers "$headers" \
  -library "$ROOT/out/ios-sim/libCabooseDraw.a" -headers "$headers" \
  -output "$OUT/CabooseDraw.xcframework" >/dev/null
rm -rf "$headers"
echo "$OUT/CabooseDraw.xcframework (Skia $SKIA_COMMIT)"
