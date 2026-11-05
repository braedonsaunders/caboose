#!/bin/sh
# Checks the MoltenVK patch moltenvk-compile-lifetime.patch: a Metal pipeline compiler is deleted
# only once its compile is done and every submission of it has returned (Metal may run the
# completion before its submitting call returns), and render and compute compiles work on their
# own copy of the descriptor, released with the compiler, never on the caller's.
#   sh check-compile-lifetime.sh [/path/to/moltenvk]
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
PATCH="$HERE/../moltenvk-compile-lifetime.patch"
[ -f "$PATCH" ]
if [ "${1:-}" != "" ] && [ -d "$1/MoltenVK/MoltenVK/GPUObjects" ]; then
    MVK="$1/MoltenVK/MoltenVK/GPUObjects"
    grep -q 'uint32_t _cabooseSubmitting = 0;' "$MVK/MVKSync.h"
    grep -q 'return _isDestroyed && !_cabooseSubmitting;' "$MVK/MVKSync.mm"
    grep -q 'return _isCompileDone && !_cabooseSubmitting;' "$MVK/MVKSync.mm"
    grep -q 'remove = _isDestroyed && _isCompileDone && !_cabooseSubmitting;' "$MVK/MVKSync.mm"
    [ "$(grep -c 'cabooseSubmitting();' "$MVK/MVKPipeline.mm")" -eq 2 ]
    [ "$(grep -c 'cabooseSubmitted();' "$MVK/MVKPipeline.mm")" -eq 2 ]
    grep -q '_cabooseDescriptor = \[mtlRPLDesc copy\];' "$MVK/MVKPipeline.mm"
    grep -q '_cabooseDescriptor = \[plDesc copy\];' "$MVK/MVKPipeline.mm"
    [ "$(grep -c '\[_cabooseDescriptor release\];' "$MVK/MVKPipeline.mm")" -eq 2 ]
    # No compile may touch the caller's descriptor once it is dispatched.
    ! grep -q 'mtlRPLDesc.binaryArchives' "$MVK/MVKPipeline.mm"
    ! grep -q 'plDesc.binaryArchives' "$MVK/MVKPipeline.mm"
    echo "moltenvk compile lifetime (checkout): verified"
else
    grep -q '+.*uint32_t _cabooseSubmitting = 0;' "$PATCH"
    grep -q '+.*return _isDestroyed && !_cabooseSubmitting;' "$PATCH"
    grep -q '+.*return _isCompileDone && !_cabooseSubmitting;' "$PATCH"
    grep -q '+.*_cabooseDescriptor = \[mtlRPLDesc copy\];' "$PATCH"
    grep -q '+.*_cabooseDescriptor = \[plDesc copy\];' "$PATCH"
    grep -q '+.*desc.binaryArchives = @\[archive\];' "$PATCH"
    echo "moltenvk compile lifetime (patch): verified"
fi
