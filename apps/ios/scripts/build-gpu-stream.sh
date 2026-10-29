#!/bin/sh
# Build CabooseKit/Frameworks/CabooseGPUStream.xcframework, the GPU stream player that
# CabooseKit's GPUStreamPlayer links: GFXReconstruct's Vulkan replay (MIT) at the release
# of Vulkan SDK 1.4.363 (capture format 1.0.5) with the patches in GPUStream/patches, the
# C API in GPUStream, and MoltenVK (Apache-2.0) 1.4.2, the MoltenVK of that SDK. Slices:
# macos-arm64 (for swift test), ios-arm64 and ios-arm64-simulator.
#
#   sh scripts/build-gpu-stream.sh                 # every slice
#   sh scripts/build-gpu-stream.sh macos ios       # only those slices
#
# Needs Xcode (set DEVELOPER_DIR if xcode-select points at the Command Line Tools), CMake
# 3.24 or later and Ninja. JOBS (default 4) caps parallel compiles; GFXReconstruct's
# generated decoders need about 2 GB each. Sources, MoltenVK and each slice's library are
# kept in build/gpu-stream, and the xcframework holds every slice built there, so building
# one slice again keeps the others. The per-slice build trees are removed unless
# KEEP_BUILD=1.
set -eu

GFXRECON_REPOSITORY=https://github.com/LunarG/gfxreconstruct.git
GFXRECON_TAG=vulkan-sdk-1.4.363.0
GFXRECON_COMMIT=4401228c791b11fb7ea15b93795cbd1e938307c0
MOLTENVK_URL=https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.2/MoltenVK-all.tar
MOLTENVK_SHA256=562a15a29bc358446a56a4091c5f7e08f604184187c1d34f712148b61ef17276
IOS_DEPLOYMENT_TARGET=26.0
MACOS_DEPLOYMENT_TARGET=15.0
JOBS=${JOBS:-4}

ios=$(cd "$(dirname "$0")/.." && pwd)
work=$ios/build/gpu-stream
frameworks=$ios/CabooseKit/Frameworks
output=$frameworks/CabooseGPUStream.xcframework
slices=${*:-macos ios ios-simulator}

for tool in cmake ninja git xcodebuild libtool lipo shasum; do
  command -v "$tool" >/dev/null || { echo "build-gpu-stream: $tool is required" >&2; exit 1; }
done
xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 ||
  { echo "build-gpu-stream: no iOS SDK; install Xcode or set DEVELOPER_DIR" >&2; exit 1; }
mkdir -p "$work"

# GFXReconstruct at the pinned commit, with only the submodules replay needs, at the
# commits GFXReconstruct pins.
source=$work/gfxreconstruct
if [ "$(git -C "$source" rev-parse HEAD 2>/dev/null || true)" != "$GFXRECON_COMMIT" ]; then
  rm -rf "$source"
  git init -q "$source"
  git -C "$source" remote add origin "$GFXRECON_REPOSITORY"
  git -C "$source" fetch -q --depth 1 origin "$GFXRECON_COMMIT"
  git -C "$source" -c advice.detachedHead=false checkout -q FETCH_HEAD
fi
git -C "$source" reset -q --hard "$GFXRECON_COMMIT"
git -C "$source" clean -qfdx
git -C "$source" submodule update -q --init --depth 1 \
  external/Vulkan-Headers external/SPIRV-Headers external/SPIRV-Reflect
for patch in "$ios"/GPUStream/patches/*.patch; do
  git -C "$source" apply "$patch"
done
echo "GFXReconstruct $GFXRECON_TAG ($GFXRECON_COMMIT), patched"

# MoltenVK's release build, checked against its digest; one architecture per slice.
moltenvk=$work/moltenvk
if [ ! -f "$moltenvk/.sha256" ] || [ "$(cat "$moltenvk/.sha256")" != "$MOLTENVK_SHA256" ]; then
  rm -rf "$moltenvk"
  mkdir -p "$moltenvk/download"
  curl -fsSL --retry 3 "$MOLTENVK_URL" -o "$moltenvk/download/MoltenVK-all.tar"
  printf '%s  %s\n' "$MOLTENVK_SHA256" "$moltenvk/download/MoltenVK-all.tar" | shasum -a 256 -c - >/dev/null
  tar -xf "$moltenvk/download/MoltenVK-all.tar" -C "$moltenvk/download" \
    MoltenVK/LICENSE \
    MoltenVK/MoltenVK/static/MoltenVK.xcframework/macos-arm64_x86_64/libMoltenVK.a \
    MoltenVK/MoltenVK/static/MoltenVK.xcframework/ios-arm64/libMoltenVK.a \
    MoltenVK/MoltenVK/static/MoltenVK.xcframework/ios-arm64_x86_64-simulator/libMoltenVK.a
  static=$moltenvk/download/MoltenVK/MoltenVK/static/MoltenVK.xcframework
  mkdir -p "$moltenvk/macos" "$moltenvk/ios" "$moltenvk/ios-simulator"
  lipo -thin arm64 "$static/macos-arm64_x86_64/libMoltenVK.a" -output "$moltenvk/macos/libMoltenVK.a"
  cp "$static/ios-arm64/libMoltenVK.a" "$moltenvk/ios/libMoltenVK.a"
  lipo -thin arm64 "$static/ios-arm64_x86_64-simulator/libMoltenVK.a" -output "$moltenvk/ios-simulator/libMoltenVK.a"
  cp "$moltenvk/download/MoltenVK/LICENSE" "$moltenvk/LICENSE"
  rm -rf "$moltenvk/download"
  echo "$MOLTENVK_SHA256" >"$moltenvk/.sha256"
fi
echo "MoltenVK 1.4.2 ($MOLTENVK_SHA256)"

headers=$work/headers
rm -rf "$headers"
mkdir -p "$headers/CabooseGPUStream"
cp "$ios/GPUStream/include/caboose_gpu_stream.h" "$headers/CabooseGPUStream/"
cat >"$headers/CabooseGPUStream/module.modulemap" <<'MODULE'
module CabooseGPUStream {
    header "caboose_gpu_stream.h"
    export *
}
MODULE

for slice in $slices; do
  case $slice in
    macos) platform="-DCMAKE_OSX_SYSROOT=macosx -DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOS_DEPLOYMENT_TARGET" ;;
    ios) platform="-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_DEPLOYMENT_TARGET=$IOS_DEPLOYMENT_TARGET" ;;
    ios-simulator) platform="-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphonesimulator -DCMAKE_OSX_DEPLOYMENT_TARGET=$IOS_DEPLOYMENT_TARGET" ;;
    *) echo "build-gpu-stream: unknown slice $slice (macos, ios, ios-simulator)" >&2; exit 1 ;;
  esac
  build=$work/build-$slice
  echo "Building $slice"
  # shellcheck disable=SC2086
  cmake -S "$ios/GPUStream" -B "$build" -G Ninja -Wno-dev --log-level=WARNING \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 $platform \
    -DGFXRECON_SOURCE_DIR="$source" -DMOLTENVK_LIBRARY="$moltenvk/$slice/libMoltenVK.a" >/dev/null
  cmake --build "$build" --parallel "$JOBS"
  mkdir -p "$work/lib/$slice"
  cp "$build/libCabooseGPUStream.a" "$work/lib/$slice/libCabooseGPUStream.a"
  [ "${KEEP_BUILD:-0}" = 1 ] || rm -rf "$build"
done

libraries=""
for library in "$work"/lib/*/libCabooseGPUStream.a; do
  libraries="$libraries -library $library -headers $headers"
done

rm -rf "$output"
mkdir -p "$frameworks"
# shellcheck disable=SC2086
xcodebuild -create-xcframework $libraries -output "$output" >/dev/null
mkdir -p "$frameworks/Licenses"
cp "$source/LICENSE.md" "$frameworks/Licenses/GFXReconstruct-LICENSE.md"
cp "$moltenvk/LICENSE" "$frameworks/Licenses/MoltenVK-LICENSE"
rm -rf "$headers"
echo "Built $output"
for library in "$output"/*/libCabooseGPUStream.a; do
  echo "  $(basename "$(dirname "$library")"): $(du -h "$library" | cut -f1)"
done
