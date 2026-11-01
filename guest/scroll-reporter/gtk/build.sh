#!/bin/sh
# Builds the GTK reporters, libcaboose-scroll-gtk4.so and libcaboose-scroll-gtk3.so, into
# OUT (default ./out/MULTIARCH, the compiler's multiarch triplet). With --check it also builds
# the check's ruler application for both. Needs a C compiler and the GTK 3 and 4 headers
# (Debian: libgtk-3-dev libgtk-4-dev). CC and PKG_CONFIG select another architecture's
# compiler and headers (../README.md, "32-bit applications").
set -eu
src=$(cd "$(dirname "$0")" && pwd)
cc=${CC:-cc}
pkg_config=${PKG_CONFIG:-pkg-config}
out=${OUT:-$src/out/$($cc -print-multiarch)}
mkdir -p "$out"
flags="-O2 -fPIC -shared -Wall -Wextra -Wno-unused-parameter -Wl,-z,lazy"
for v in 4 3; do
  # Headers only: GLib and GTK are resolved at run time, so the library links to neither.
  $cc $flags -DCABOOSE_GTK=$v $($pkg_config --cflags gtk$( [ $v = 4 ] && echo 4 || echo +-3.0)) \
    -o "$out/libcaboose-scroll-gtk$v.so" "$src/caboose-scroll-gtk.c" -ldl -lm
done
if [ "${1:-}" = --check ]; then
  $cc -O2 -o "$out/scroll-ruler-gtk4" "$src/ruler-app.c" $($pkg_config --cflags --libs gtk4)
  $cc -O2 -o "$out/scroll-ruler-gtk3" "$src/ruler-app.c" $($pkg_config --cflags --libs gtk+-3.0)
fi
