#!/bin/sh
# Native SDL Wayland only. Caller supplies a real compositor and Vulkan driver.
set -eu
: "${XDG_RUNTIME_DIR:?Set the private Wayland runtime directory}"
: "${WAYLAND_DISPLAY:?Set the Wayland display socket name}"
: "${CABOOSE_GAME_BUNDLE:?Set the absolute path to the verified bundle}"
case "$CABOOSE_GAME_BUNDLE" in /*) ;; *) echo 'Bundle must be absolute' >&2; exit 2;; esac
if [ -n "${CABOOSE_GAME_LIBRARY_DIR:-}" ]; then
  case "$CABOOSE_GAME_LIBRARY_DIR" in /*) ;; *) echo 'Library directory must be absolute' >&2; exit 2;; esac
  export LD_LIBRARY_PATH="$CABOOSE_GAME_LIBRARY_DIR:$CABOOSE_GAME_LIBRARY_DIR/pulseaudio${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
export SDL_VIDEODRIVER=wayland
exec "$CABOOSE_GAME_BUNDLE/vkquake" -basedir "$CABOOSE_GAME_BUNDLE" -window -width 640 -height 480 "$@"
