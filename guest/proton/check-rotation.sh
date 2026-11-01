#!/bin/bash
# Turns the display under a running Wine program: caboose-display at 1338x911, a DPI-aware
# program on GE-Proton's Wine, then 932x1356. Usage on a Docker host:
#   check-rotation.sh COMPUTER-IMAGE GE-RELEASE-DIR [MODULES-DIR [CABOOSE-DISPLAY]]
# COMPUTER-IMAGE is a Caboose computer image (its caboose-display and Xwayland run the
# display); MODULES-DIR, when given, is build.sh's out/ directory, whose modules replace
# the release's for the run; CABOOSE-DISPLAY, a caboose-display binary to run instead of the
# image's.
# Prints PASS when the program outlives the turn and sees the rotated raw DPI, FAIL otherwise.
set -euo pipefail
image=$1 ge=$(cd "$2" && pwd) here=$(cd "$(dirname "$0")" && pwd)
mounts=(-v "$ge":/ge:ro -v "$here":/src:ro)
if [ $# -ge 3 ] && [ -n "$3" ]; then
  out=$(cd "$3" && pwd)
  for mod in win32u.so ntdll.so; do
    if [ -f "$out/x86_64-unix/$mod" ]; then
      mounts+=(-v "$out/x86_64-unix/$mod":/ge/files/lib/wine/x86_64-unix/$mod:ro
               -v "$out/i386-unix/$mod":/ge/files/lib/wine/i386-unix/$mod:ro)
    fi
  done
fi
if [ $# -ge 4 ]; then mounts+=(-v "$(cd "$(dirname "$4")" && pwd)/$(basename "$4")":/usr/local/bin/caboose-display:ro); fi
nice -n 19 docker run --rm --cpus 4 -u 0 --entrypoint /bin/bash "${mounts[@]}" "$image" /src/check-rotation-inside.sh
