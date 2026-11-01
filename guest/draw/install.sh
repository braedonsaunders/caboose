#!/bin/sh
# Installs the cairo recorder into the guest image, for every user. Run inside the image build
# (as root), after guest/scroll-reporter/install.sh. Safe to run again. OUT names the directory
# holding build.sh's builds by multiarch triplet (default ./build), each installed into
# /opt/caboose/draw/lib/MULTIARCH. caboose-display preloads
# /opt/caboose/draw/$LIB/libcaboose-draw-cairo.so into the applications it starts, which the
# dynamic loader resolves to the process's own architecture; the recorder records nothing
# until a client that draws draw lists asks (docs/draw.md).
set -eu
src=$(cd "$(dirname "$0")" && pwd)
out=${OUT:-$src/build}
dest=/opt/caboose/draw
install -d -m 0755 /opt/caboose "$dest" "$dest/lib"
installed=0
for built in "$out"/*/libcaboose-draw-cairo.so; do
    [ -f "$built" ] || continue
    arch=$(basename "$(dirname "$built")")
    install -d -m 0755 "$dest/lib/$arch"
    install -m 0644 "$built" "$dest/lib/$arch/libcaboose-draw-cairo.so"
    installed=1
done
[ $installed = 1 ] || { echo "no recorder built in $out" >&2; exit 1; }
recorder='/opt/caboose/draw/$LIB/libcaboose-draw-cairo.so'
# Flatpak applications see neither /opt nor the host's LD_PRELOAD. The system-wide override
# has one LD_PRELOAD, which the scroll reporters set: the recorder is added to it, with its
# directory read-only and the display instances' sockets, where it finds the draw socket from
# WAYLAND_DISPLAY.
if command -v flatpak >/dev/null 2>&1; then
    current=$(flatpak override --system --show 2>/dev/null | sed -n 's/^LD_PRELOAD=//p' | head -n 1)
    case ":$current:" in
        *":$recorder:"*) preload=$current ;;
        "::") preload=$recorder ;;
        *) preload=$current:$recorder ;;
    esac
    flatpak override --system --filesystem="$dest:ro" --filesystem=xdg-run/caboose-display --env=LD_PRELOAD="$preload"
fi
