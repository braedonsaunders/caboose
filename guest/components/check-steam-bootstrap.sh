#!/bin/bash
# Check the installed native Steam bootstrap without starting Steam or a game.
set -euo pipefail
if [[ $(dpkg --print-architecture) != amd64 ]]; then
  echo 'SKIP: native x86 Steam bootstrap check requires an amd64 guest'
  exit 77
fi
if (($# != 1)); then
  echo "Usage: $0 /path/to/installed/Steam" >&2
  exit 2
fi
steam=$(cd -- "$1" && pwd)
loader32=/lib/ld-linux.so.2
loader64=/lib64/ld-linux-x86-64.so.2
reaper="$steam/steamrt64/reaper"
wrapper="$steam/steamrt64/steam-launch-wrapper"
overlay32="$steam/steamrt32/gameoverlayrenderer.so"
overlay64="$steam/steamrt64/gameoverlayrenderer.so"
for file in "$loader32" "$loader64" "$reaper" "$wrapper"; do
  [[ -x $file ]] || { echo "Missing executable bootstrap dependency: $file" >&2; exit 1; }
done
for file in "$overlay32" "$overlay64"; do
  [[ -r $file ]] || { echo "Missing bootstrap overlay: $file" >&2; exit 1; }
done
# Resolve the actual installed binaries' dependency closures using their loaders.
# Do not inherit a game's or an image builder's preload/library overrides.
unset LD_PRELOAD LD_LIBRARY_PATH
timeout 10 "$loader32" --list "$reaper"
timeout 10 "$loader32" --list "$overlay32"
timeout 10 "$loader64" --list "$wrapper"
timeout 10 "$loader64" --list "$overlay64"
# Exercise both normal overlays and the wrapper/reaper process chain. Each
# loader ignores the overlay of the other ELF class, as in Steam's normal launch.
# No app id, account, prefix, display or graphics device is used by /usr/bin/true.
timeout 10 env LD_PRELOAD="$overlay32:$overlay64" \
  "$wrapper" -- "$reaper" SteamLaunch -- /usr/bin/true
echo 'PASS: native Steam wrapper/reaper and both overlay dependency closures'
