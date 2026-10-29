#!/bin/bash
# Build what caboose-gpu-run loads, from pinned sources, into OUT (default ./out):
#   OUT/icd.json, OUT/libVkICD_mock_icd.so          the driver that renders nothing
#   OUT/layers/VkLayer_gfxreconstruct.{json,so}     the capture layer that writes the stream
#   OUT/layers/VkLayer_khronos_profiles.{json,so}   the layer that shows the client's GPU
# Needs git, cmake, ninja, a C++17 compiler, python3, and the X11/XCB/Wayland development
# headers; downloads the sources and their pinned dependencies.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=$(mkdir -p "${1:-$here/out}" && cd "${1:-$here/out}" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
jobs=${CABOOSE_GPU_JOBS:-4}

# One Vulkan SDK release: the capture format the client's player reads is GFXReconstruct's.
fetch() { # name repository commit
  git -C "$work" init -q "$1"
  git -C "$work/$1" fetch -q --depth 1 "$2" "$3"
  git -C "$work/$1" checkout -q FETCH_HEAD
}
fetch tools https://github.com/KhronosGroup/Vulkan-Tools.git 6fe2055cf2fa921d52a4c6a31528cfc279a6977f
fetch gfxr https://github.com/LunarG/gfxreconstruct.git 4401228c791b11fb7ea15b93795cbd1e938307c0
fetch profiles https://github.com/KhronosGroup/Vulkan-Profiles.git fce885d30ebafed32e03c0b199bc67d6a758887f
git -C "$work/gfxr" submodule update -q --init --depth 1

cmake -S "$work/tools" -B "$work/tools/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DUPDATE_DEPS=ON \
  -DBUILD_ICD=ON -DBUILD_CUBE=OFF -DBUILD_VULKANINFO=OFF >/dev/null
ninja -C "$work/tools/build" -j "$jobs" VkICD_mock_icd
cmake -S "$work/gfxr" -B "$work/gfxr/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_LAUNCHER_AND_INTERCEPTOR=OFF -DGFXRECON_ENABLE_OPENXR=OFF -DLZ4_OPTIONAL=ON -DZSTD_OPTIONAL=ON -DZLIB_OPTIONAL=ON >/dev/null
ninja -C "$work/gfxr/build" -j "$jobs" VkLayer_gfxreconstruct
cmake -S "$work/profiles" -B "$work/profiles/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DUPDATE_DEPS=ON \
  -DBUILD_TESTS=OFF >/dev/null
ninja -C "$work/profiles/build" -j "$jobs" ProfilesLayer

mkdir -p "$out/layers"
install -m 755 "$(find "$work/tools/build" -name libVkICD_mock_icd.so | head -1)" "$out/"
printf '{\n  "file_format_version": "1.0.1",\n  "ICD": { "library_path": "./libVkICD_mock_icd.so", "api_version": "1.4.363" }\n}\n' > "$out/icd.json"
layer() { # library layer-name description
  install -m 755 "$(find "$work" -name "libVkLayer_$1.so" -path '*build*' | head -1)" "$out/layers/"
  printf '{\n  "file_format_version": "1.2.0",\n  "layer": {\n    "name": "%s",\n    "type": "GLOBAL",\n    "library_path": "./libVkLayer_%s.so",\n    "api_version": "1.4.363",\n    "implementation_version": "1",\n    "description": "%s"\n  }\n}\n' \
    "$2" "$1" "$3" > "$out/layers/VkLayer_$1.json"
}
layer gfxreconstruct VK_LAYER_LUNARG_gfxreconstruct 'GFXReconstruct capture layer'
layer khronos_profiles VK_LAYER_KHRONOS_profiles 'Khronos profiles layer'
strip --strip-unneeded "$out"/*.so "$out"/layers/*.so
install -m 644 "$here/profile.json" "$out/profile.json"
echo "built into $out"
