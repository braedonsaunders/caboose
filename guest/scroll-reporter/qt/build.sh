#!/bin/sh
# Builds the Qt reporter into OUT (default ./out): the preload library
# libcaboose-scroll-qt6.so and the reporter it loads, libcaboose-scroll-qt6-quick.so. With
# --check it also builds the check's ruler application. Needs a C++ compiler and the Qt 6
# Quick headers (Debian: qt6-declarative-dev).
set -eu
src=$(cd "$(dirname "$0")" && pwd)
out=${OUT:-$src/out}
mkdir -p "$out"
cc -O2 -fPIC -shared -Wall -o "$out/libcaboose-scroll-qt6.so" "$src/loader.c" -ldl
c++ -std=c++17 -O2 -fPIC -shared -Wall -o "$out/libcaboose-scroll-qt6-quick.so" "$src/caboose-scroll-qt.cpp" \
  $(pkg-config --cflags --libs Qt6Quick)
if [ "${1:-}" = --check ]; then
  c++ -std=c++17 -O2 -fPIC -o "$out/scroll-ruler-qt6" "$src/ruler-app.cpp" $(pkg-config --cflags --libs Qt6Qml Qt6Gui)
fi
