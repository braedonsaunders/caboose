#!/bin/sh
# Builds the layer and runs its test on lavapipe with the layer enabled explicitly.
# Needs a C++17 compiler, the Vulkan headers and loader, and mesa-vulkan-drivers.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
make -s -C "$here" O= >/dev/null
cp "$here/libVkLayer_caboose_executor_switch.so" "$here/test_executor_switch" "$work/"
sed -e "s#/usr/local/lib/caboose-gpu-live/#$work/#" -e 's/"enable_environment".*//' -e 's/"disable_environment".*/"disable_environment": { "CABOOSE_GPU_EXECUTOR_SWITCH_DISABLE": "1" }/' \
    "$here/implicit_layer.json" > "$work/layer.json"
lvp=/usr/share/vulkan/icd.d/lvp_icd.json
[ -f "$lvp" ] || lvp=$(ls /usr/share/vulkan/icd.d/lvp_icd*.json | head -1)
VK_DRIVER_FILES="$lvp" VK_ICD_FILENAMES="$lvp" VK_LAYER_PATH="$work" \
    VK_INSTANCE_LAYERS=VK_LAYER_CABOOSE_executor_switch CABOOSE_GFXSTREAM_SOCKET="$work/gpu.sock" \
    "$work/test_executor_switch"
make -s -C "$here" clean
