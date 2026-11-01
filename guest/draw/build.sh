#!/bin/sh
# Builds libcaboose-draw-cairo.so (the cairo recorder) and caboose-draw-replay into $1
# (default ./build). The recorder needs only headers (cairo, FreeType, wayland-client), links
# nothing but libc and uses nothing newer than glibc 2.34; the replayer links cairo.
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
# The recorder loads into Flatpak runtimes too: nothing newer than glibc 2.34.
if command -v objdump >/dev/null && objdump -T "$out/libcaboose-draw-cairo.so" | grep -Eq 'GLIBC_2\.(3[5-9]|[4-9][0-9])'; then
  echo "libcaboose-draw-cairo.so needs a glibc newer than 2.34:" >&2
  objdump -T "$out/libcaboose-draw-cairo.so" | grep -E 'GLIBC_2\.(3[5-9]|[4-9][0-9])' >&2
  exit 1
fi
echo "built $out/libcaboose-draw-cairo.so $out/caboose-draw-replay"
