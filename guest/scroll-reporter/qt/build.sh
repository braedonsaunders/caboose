#!/bin/sh
# Builds the Qt reporter into OUT (default ./out/MULTIARCH, the compiler's multiarch
# triplet): the preload library libcaboose-scroll-qt6.so and the reporter it loads,
# libcaboose-scroll-qt6-quick.so. With --check it also builds the check's ruler application.
# Needs a C++ compiler and the Qt 6 Quick headers (Debian: qt6-declarative-dev). CC, CXX and
# PKG_CONFIG select another architecture's compilers and headers (../README.md, "32-bit
# applications").
set -eu
src=$(cd "$(dirname "$0")" && pwd)
cc=${CC:-cc}
cxx=${CXX:-c++}
pkg_config=${PKG_CONFIG:-pkg-config}
out=${OUT:-$src/out/$($cc -print-multiarch)}
mkdir -p "$out"
$cc -O2 -fPIC -shared -Wall -o "$out/libcaboose-scroll-qt6.so" "$src/loader.c" -ldl
$cxx -std=c++17 -O2 -fPIC -shared -Wall -o "$out/libcaboose-scroll-qt6-quick.so" "$src/caboose-scroll-qt.cpp" \
  $($pkg_config --cflags --libs Qt6Quick)
if [ "${1:-}" = --check ]; then
  $cxx -std=c++17 -O2 -fPIC -o "$out/scroll-ruler-qt6" "$src/ruler-app.cpp" $($pkg_config --cflags --libs Qt6Qml Qt6Gui)
fi
