#!/bin/sh
# Checks the SPIRV-Cross patch spirv-cross-msl-type-names.patch: a fragment shader whose
# variables, block and member are named like MSL types (sampler, texture, array, float4,
# half), as Zink names them, converts to Metal Shading Language that compiles, with and
# without argument buffers. Needs glslangValidator, spirv-dis and spirv-as (SPIRV-Tools)
# and Xcode.
#   sh check-msl-type-names.sh /path/to/patched/spirv-cross
set -eu
CROSS=$1
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
glslangValidator -V -S frag "$HERE/msl-type-names.frag" -o "$WORK/in.spv" >/dev/null
spirv-dis --raw-id "$WORK/in.spv" -o "$WORK/in.spvasm"
sed -e 's/"NAME_SAMPLER"/"sampler"/; s/"NAME_TEXTURE"/"texture2d"/; s/"NAME_ARRAY"/"array"/' \
    -e 's/"NAME_FLOAT4"/"float4"/; s/"NAME_HALF"/"half"/' "$WORK/in.spvasm" > "$WORK/named.spvasm"
grep -q '"sampler"' "$WORK/named.spvasm"
spirv-as "$WORK/named.spvasm" -o "$WORK/named.spv"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
for mode in plain argument-buffers; do
    flags="--msl --msl-version 30000 --msl-ios"
    [ $mode = argument-buffers ] && flags="$flags --msl-argument-buffers --msl-argument-buffer-tier 1"
    "$CROSS" $flags "$WORK/named.spv" --output "$WORK/$mode.metal"
    xcrun -sdk iphoneos metal -std=metal3.0 -c "$WORK/$mode.metal" -o "$WORK/$mode.air"
    echo "msl type names ($mode): compiles"
done
