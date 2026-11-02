#!/bin/sh
# Checks the MoltenVK residency patch moltenvk-residency-set.patch: every descriptor-pool
# argument buffer (_gpuBufferObject), device-memory MTLHeap (_mtlHeap), pixel-format
# reinterpretation view (_mtlTextureViews) and image-view texture (MVKImageViewPlane) must
# be added to and removed from the device MTLResidencySet, and heap-placed aliasable base
# and view textures must call [tex makeAliasable] rather than nil [_mtlTexture makeAliasable].
#   sh check-residency-set.sh [/path/to/moltenvk]
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
PATCH="$HERE/../moltenvk-residency-set.patch"
[ -f "$PATCH" ]
if [ "${1:-}" != "" ] && [ -d "$1/MoltenVK/MoltenVK/GPUObjects" ]; then
    MVK="$1/MoltenVK/MoltenVK/GPUObjects"
    grep -q 'device->makeResident(ret->_gpuBufferObject);' "$MVK/MVKDescriptorSet.mm"
    grep -q 'if (_gpuBufferObject) { _device->removeResidency(_gpuBufferObject); }' "$MVK/MVKDescriptorSet.mm"
    grep -q '_device->makeResident(_mtlHeap);' "$MVK/MVKDeviceMemory.mm"
    grep -q 'if (_mtlHeap) { _device->removeResidency(_mtlHeap); }' "$MVK/MVKDeviceMemory.mm"
    grep -q 'if (_image->_isAliasable || _image->_is2DViewOn3DImageCompatible || _image->_isBlockTexelViewCompatible) { \[tex makeAliasable\]; }' "$MVK/MVKImage.mm"
    grep -q '_image->_device->makeResident(mtlTex);' "$MVK/MVKImage.mm"
    grep -q 'getDevice()->makeResident(mtlTexture);' "$MVK/MVKImage.mm"
    grep -q 'getDevice()->removeResidency(tex);' "$MVK/MVKImage.mm"
    grep -q '\[aliasTex makeAliasable\];' "$MVK/MVKImage.mm"
    echo "moltenvk residency set (checkout): verified"
else
    grep -q '+.*device->makeResident(ret->_gpuBufferObject);' "$PATCH"
    grep -q '+.*if (_gpuBufferObject) { _device->removeResidency(_gpuBufferObject); }' "$PATCH"
    grep -q '+.*_device->makeResident(_mtlHeap);' "$PATCH"
    grep -q '+.*if (_mtlHeap) { _device->removeResidency(_mtlHeap); }' "$PATCH"
    grep -q '+.*\[tex makeAliasable\];' "$PATCH"
    grep -q '+.*_image->_device->makeResident(mtlTex);' "$PATCH"
    grep -q '+.*getDevice()->makeResident(mtlTexture);' "$PATCH"
    grep -q '+.*getDevice()->removeResidency(tex);' "$PATCH"
    grep -q '+.*\[aliasTex makeAliasable\];' "$PATCH"
    echo "moltenvk residency set (patch): verified"
fi
