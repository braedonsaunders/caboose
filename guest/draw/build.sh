#!/bin/sh
# Builds libcaboose-draw-cairo.so (the cairo recorder) and caboose-draw-replay into $1
# (default ./build). The recorder needs only headers (cairo, FreeType, wayland-client) and
# links nothing but libc; the replayer links cairo.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here/build}
mkdir -p "$out"
cc=${CC:-cc}
flags="-O2 -g -Wall -Wextra -Wno-unused-parameter -fvisibility=hidden"
# shellcheck disable=SC2046
$cc $flags -fPIC -shared -o "$out/libcaboose-draw-cairo.so" "$here/src/cairo_recorder.c" \
  $(pkg-config --cflags cairo-ft freetype2 wayland-client) -Wl,--as-needed -Wl,-z,defs -ldl -lpthread
# shellcheck disable=SC2046
$cc $flags -o "$out/caboose-draw-replay" "$here/src/cdl_replay.c" $(pkg-config --cflags --libs cairo) -lm
echo "built $out/libcaboose-draw-cairo.so $out/caboose-draw-replay"
