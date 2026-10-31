#!/bin/sh
# install.sh — Install Caboose Guest Scene Graph Interceptor, Chromium Bridge,
# and Implicit Vulkan/Zink Promotion Layer into the guest rootfs (or $DESTDIR).
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
DESTDIR="${DESTDIR:-}"

sh "$SCRIPT_DIR/build.sh"

install -d "$DESTDIR/usr/lib/caboose"
install -m 0755 "$SCRIPT_DIR/build/libcaboose_scene_cairo.so" "$DESTDIR/usr/lib/caboose/libcaboose_scene_cairo.so"
install -m 0755 "$SCRIPT_DIR/build/libcaboose_wsi_promote.so" "$DESTDIR/usr/lib/caboose/libcaboose_wsi_promote.so"

install -d "$DESTDIR/usr/share/vulkan/implicit_layer.d"
install -m 0644 "$SCRIPT_DIR/wsi/caboose_wsi_promote.json" "$DESTDIR/usr/share/vulkan/implicit_layer.d/caboose_wsi_promote.json"

install -d "$DESTDIR/etc/caboose"
install -m 0644 "$SCRIPT_DIR/chromium/caboose-chromium-scene.conf" "$DESTDIR/etc/caboose/chromium-scene.conf"
