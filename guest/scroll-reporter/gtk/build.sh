#!/bin/sh
# Builds the GTK reporters, libcaboose-scroll-gtk4.so and libcaboose-scroll-gtk3.so, into
# OUT (default ./out). With --check it also builds the check's ruler application for both.
# Needs a C compiler and the GTK 3 and 4 headers (Debian: libgtk-3-dev libgtk-4-dev).
set -eu
src=$(cd "$(dirname "$0")" && pwd)
out=${OUT:-$src/out}
mkdir -p "$out"
flags="-O2 -fPIC -shared -Wall -Wextra -Wno-unused-parameter -Wl,-z,lazy"
for v in 4 3; do
  # Headers only: GLib and GTK are resolved at run time, so the library links to neither.
  cc $flags -DCABOOSE_GTK=$v $(pkg-config --cflags gtk$( [ $v = 4 ] && echo 4 || echo +-3.0)) \
    -o "$out/libcaboose-scroll-gtk$v.so" "$src/caboose-scroll-gtk.c" -ldl -lm
done
if [ "${1:-}" = --check ]; then
  cc -O2 -o "$out/scroll-ruler-gtk4" "$src/ruler-app.c" $(pkg-config --cflags --libs gtk4)
  cc -O2 -o "$out/scroll-ruler-gtk3" "$src/ruler-app.c" $(pkg-config --cflags --libs gtk+-3.0)
fi
