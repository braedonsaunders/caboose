#!/bin/bash
# check-rotation.sh's container side.
set -u
dpkg --add-architecture i386
apt-get -qq update >/dev/null
apt-get -qq install -y --no-install-recommends libc6:i386 libx11-6:i386 libfreetype6:i386 libgnutls30:i386 \
  gcc-mingw-w64-x86-64 >/dev/null 2>&1
x86_64-w64-mingw32-gcc -O2 -o /tmp/dpi.exe /src/check-rotation-dpi.c -lshcore
export XDG_RUNTIME_DIR=/tmp/rt HOME=/tmp/home; mkdir -p -m 700 $XDG_RUNTIME_DIR /run/caboose $HOME
od -An -N16 -tx1 /dev/urandom | tr -d " \n" > /tmp/token
caboose-display --listen 127.0.0.1:14690 --token-file /tmp/token --socket wayland-d --x-display 150 \
  --no-audio --env-file /run/caboose/display.env > /tmp/display.log 2>&1 &
for _ in $(seq 100); do grep -q '^DISPLAY=' /run/caboose/display.env 2>/dev/null && break; sleep 0.2; done
caboose-display-probe --url ws://127.0.0.1:14690/ --token-file /tmp/token --display 1338x911@60x2 --duration 400 >/dev/null 2>&1 &
landscape=$!; sleep 3
set -a; . /run/caboose/display.env; set +a
export PATH=/ge/files/bin:$PATH WINEDLLPATH=/ge/files/lib/vkd3d:/ge/files/lib/wine WINEPREFIX=/tmp/pfx WINEDEBUG=-all
timeout 180 wine wineboot -u >/dev/null 2>&1
wine /tmp/dpi.exe > /tmp/dpi.out 2> /tmp/dpi.err &
program=$!
sleep 6; kill $landscape; sleep 1
caboose-display-probe --url ws://127.0.0.1:14690/ --token-file /tmp/token --display 932x1356@60x3 --duration 400 >/dev/null 2>&1 &
sleep 10
echo "before: $(head -1 /tmp/dpi.out)"
echo "after:  $(tail -1 /tmp/dpi.out)"
grep -a "Assertion" /tmp/dpi.err | head -2
# Wine keeps ENUM_CURRENT_SETTINGS at 1338x911 (emulate_modeset) while WINE_ENUM_PHYSICAL_SETTINGS
# becomes 932x1356; MDT_RAW_DPI is round(932*96/1338)=67 by round(1356*96/911)=143.
if kill -0 $program 2>/dev/null && grep -q "raw dpi 67 143" /tmp/dpi.out; then
  echo "PASS: $(grep 'raw dpi 67 143' /tmp/dpi.out | tail -1)"
else
  echo "FAIL: $(tail -1 /tmp/dpi.out)"
fi
