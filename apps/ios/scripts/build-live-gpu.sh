#!/bin/sh
# Builds and packages CabooseGPULive.xcframework from source: MoltenVK 1.4.2 with the
# MoltenVK and SPIRV-Cross patches in GPUStream/gfxstream/provider-patches, and the gfxstream fork at
# the commit pinned in GPUStream/gfxstream/fork.env, verified against the v4 profile.
#
#   sh apps/ios/scripts/build-live-gpu.sh OUTPUT_DIR
#
# CABOOSE_NATIVE_ROOT (default ~/Library/Caches/caboose-native) keeps sources and the
# MoltenVK archive between builds; GFXSTREAM_COMMIT overrides the pinned commit, for
# trying a fork topic branch. Needs Xcode, CMake, Ninja and read access to the fork.
set -eu
[ $# -eq 1 ] || { echo "usage: $0 OUTPUT_DIR" >&2; exit 2; }
OUT=$1
[ ! -e "$OUT/CabooseGPULive.xcframework" ] || { echo "$OUT/CabooseGPULive.xcframework exists" >&2; exit 1; }
IOS=$(cd "$(dirname "$0")/.." && pwd)
A=$IOS/GPUStream/gfxstream
pinned_commit=${GFXSTREAM_COMMIT:-}
. "$A/fork.env"
GFXSTREAM_COMMIT=${pinned_commit:-$GFXSTREAM_COMMIT}
N=${CABOOSE_NATIVE_ROOT:-$HOME/Library/Caches/caboose-native}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}  # the CLT linker rejects the iPhoneOS SDK
mkdir -p "$N/src" "$OUT"

# 1. MoltenVK 1.4.2 with persistent Metal pipeline binaries, event-set-at-execution,
# encoder status, and MTLResidencySet registration, plus its pinned SPIRV-Cross with
# the multi-plane padding and MSL reserved type-name patches.
PROVIDER_PATCHES=$(cat \
  "$A/provider-patches/spirv-cross-multiplane-padding.patch" \
  "$A/provider-patches/spirv-cross-msl-type-names.patch" \
  "$A/provider-patches/moltenvk-pipeline-binary-archive.patch" \
  "$A/provider-patches/moltenvk-event-set-at-execution.patch" \
  "$A/provider-patches/moltenvk-command-buffer-encoder-status.patch" \
  "$A/provider-patches/moltenvk-residency-set.patch" | shasum -a 256 | cut -d' ' -f1)
if [ "$(cat "$N/moltenvk/provider-patches.sha256" 2>/dev/null)" != "$PROVIDER_PATCHES" ]; then
  rm -rf "$N/moltenvk" "$N/src/moltenvk" "$N/src/spirv-cross"
fi
if [ ! -f "$N/moltenvk/libMoltenVK-ios-arm64.a" ]; then
  if [ ! -d "$N/src/moltenvk" ]; then
    git clone -q --depth 1 --branch v1.4.2 https://github.com/KhronosGroup/MoltenVK.git "$N/src/moltenvk"
    git -C "$N/src/moltenvk" apply "$A/provider-patches/moltenvk-pipeline-binary-archive.patch"
    git -C "$N/src/moltenvk" apply "$A/provider-patches/moltenvk-event-set-at-execution.patch"
    git -C "$N/src/moltenvk" apply "$A/provider-patches/moltenvk-command-buffer-encoder-status.patch"
    git -C "$N/src/moltenvk" apply "$A/provider-patches/moltenvk-residency-set.patch"
  fi
  if [ ! -d "$N/src/spirv-cross" ]; then
    git clone -q --filter=blob:none --no-checkout https://github.com/KhronosGroup/SPIRV-Cross.git "$N/src/spirv-cross"
    git -C "$N/src/spirv-cross" checkout -q "$(cat "$N/src/moltenvk/ExternalRevisions/SPIRV-Cross_repo_revision")"
    git -C "$N/src/spirv-cross" apply "$A/provider-patches/spirv-cross-multiplane-padding.patch"
    git -C "$N/src/spirv-cross" apply "$A/provider-patches/spirv-cross-msl-type-names.patch"
  fi
  (cd "$N/src/moltenvk" &&
    ./fetchDependencies --ios --no-parallel-build --spirv-cross-root "$N/src/spirv-cross" &&
    xcodebuild -project MoltenVKPackaging.xcodeproj -scheme "MoltenVK Package (iOS only)" \
      -destination generic/platform=iOS -configuration Release -derivedDataPath "$PWD/Derived/iOS" \
      build CODE_SIGNING_ALLOWED=NO)
  mkdir -p "$N/moltenvk"
  cp "$N/src/moltenvk/Package/Release/MoltenVK/static/MoltenVK.xcframework/ios-arm64/libMoltenVK.a" \
    "$N/moltenvk/libMoltenVK-ios-arm64.a"
  echo "$PROVIDER_PATCHES" > "$N/moltenvk/provider-patches.sha256"
fi
# 2. Vulkan-Headers at MoltenVK's pin.
if [ ! -f "$N/vulkan-headers/registry/vk.xml" ]; then
  V=$N/src/moltenvk/External/Vulkan-Headers
  mkdir -p "$N/vulkan-headers" && cp -R "$V/include" "$V/registry" "$N/vulkan-headers/"
fi
# 3. The gfxstream fork at the pinned commit.
if [ ! -d "$N/src/gfxstream/.git" ]; then
  git clone -q --filter=blob:none --no-checkout "$GFXSTREAM_REPOSITORY" "$N/src/gfxstream"
fi
git -C "$N/src/gfxstream" fetch -q origin "$GFXSTREAM_BRANCH" "$GFXSTREAM_COMMIT" 2>/dev/null ||
  git -C "$N/src/gfxstream" fetch -q origin "$GFXSTREAM_BRANCH"
git -C "$N/src/gfxstream" checkout -q --detach "$GFXSTREAM_COMMIT"
git -C "$N/src/gfxstream" merge-base --is-ancestor "$GFXSTREAM_UPSTREAM" HEAD ||
  { echo "gfxstream $GFXSTREAM_COMMIT does not contain upstream $GFXSTREAM_UPSTREAM" >&2; exit 1; }
python3 "$A/generate-v4-profile.py" "$N/src/gfxstream" --check --patched
# 4. Configure and build the runtime (presentation leases, indexed WSI, memory audit).
cmake -S "$A/ios-reference" -B "$N/cmake-build" -G Ninja \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DCMAKE_BUILD_TYPE=Release -DDEPENDENCY_RESOLUTION=AOSP \
  -DCABOOSE_GFXSTREAM_SOURCE="$N/src/gfxstream" -DCABOOSE_ADAPTER_DIR="$A" \
  -DCABOOSE_MOLTENVK_ARCHIVE="$N/moltenvk/libMoltenVK-ios-arm64.a" \
  -DCABOOSE_GFXSTREAM_PRESENTATION_LEASE=ON -DCABOOSE_GFXSTREAM_INDEXED_WSI=ON \
  -DCABOOSE_GFXSTREAM_MEMORY_AUDIT=ON
cmake --build "$N/cmake-build" --target caboose_gpu_native_runtime caboose_gfxstream_ios_link_probe
# 5. Package.
MVK=$(shasum -a 256 "$N/moltenvk/libMoltenVK-ios-arm64.a" | cut -d' ' -f1)
python3 "$IOS/scripts/package-live-gpu.py" --build-dir "$N/cmake-build" \
  --provider "$N/moltenvk/libMoltenVK-ios-arm64.a" --provider-sha256 "$MVK" \
  --vulkan-headers "$N/vulkan-headers" --memory-audit --output "$OUT/CabooseGPULive.xcframework"
echo "gfxstream $(git -C "$N/src/gfxstream" rev-parse HEAD): $OUT/CabooseGPULive.xcframework"
