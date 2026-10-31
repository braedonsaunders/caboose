#!/bin/sh
# Fetch only when a bounded source-download plan has been approved.
set -eu
if [ "$#" -ne 1 ]; then
    echo "usage: $0 NEW_CHECKOUT_DIRECTORY" >&2
    exit 2
fi
target=$1
revision=541c56aa3fd24027ed46ae350287d21dcd56c901
if [ -e "$target" ] || [ -L "$target" ]; then
    echo "refusing to overwrite $target" >&2
    exit 1
fi
git init "$target"
git -C "$target" fetch --depth=1 https://android.googlesource.com/platform/external/mesa3d "$revision"
git -C "$target" checkout --detach FETCH_HEAD
actual=$(git -C "$target" rev-parse HEAD)
if [ "$actual" != "$revision" ]; then
    echo "unexpected Mesa revision: $actual" >&2
    exit 1
fi
