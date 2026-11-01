#!/bin/sh
# Installs the cairo recorder into the guest image, for every user. Run inside the image build
# (as root), after guest/scroll-reporter/install.sh. Safe to run again. OUT names the directory
# build.sh built into (default ./build). caboose-display preloads
# /opt/caboose/draw/lib/libcaboose-draw-cairo.so into the applications it starts; the recorder
# records nothing until a client that draws draw lists asks (docs/draw.md).
set -eu
src=$(cd "$(dirname "$0")" && pwd)
out=${OUT:-$src/build}
dest=/opt/caboose/draw
install -d -m 0755 /opt/caboose "$dest" "$dest/lib"
install -m 0644 "$out/libcaboose-draw-cairo.so" "$dest/lib/libcaboose-draw-cairo.so"
# Flatpak applications see neither /opt nor the host's LD_PRELOAD. The system-wide override
# has one LD_PRELOAD, which the scroll reporters set: the recorder is added to it, with its
# directory read-only and the display instances' sockets, where it finds the draw socket from
# WAYLAND_DISPLAY.
if command -v flatpak >/dev/null 2>&1; then
    current=$(flatpak override --system --show 2>/dev/null | sed -n 's/^LD_PRELOAD=//p' | head -n 1)
    case ":$current:" in
        *":$dest/lib/libcaboose-draw-cairo.so:"*) preload=$current ;;
        "::") preload=$dest/lib/libcaboose-draw-cairo.so ;;
        *) preload=$current:$dest/lib/libcaboose-draw-cairo.so ;;
    esac
    flatpak override --system --filesystem="$dest:ro" --filesystem=xdg-run/caboose-display --env=LD_PRELOAD="$preload"
fi
