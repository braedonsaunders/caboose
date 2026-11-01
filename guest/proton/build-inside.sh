#!/bin/bash
# Runs in a Debian 13 container (build.sh): GE-Proton's Wine with Caboose's patches, built
# for x86_64 and i386, only the modules Caboose replaces, into /work/out.
set -euo pipefail
dpkg --add-architecture i386
apt-get -qq update >/dev/null
apt-get -qq install -y --no-install-recommends git ca-certificates patch autoconf python3 make flex bison \
  gcc gcc-multilib libfreetype-dev libfontconfig-dev libfreetype-dev:i386 libfontconfig-dev:i386 \
  libegl-dev libgl-dev libegl-dev:i386 libgl-dev:i386 \
  libvulkan-dev libvulkan-dev:i386 libdbus-1-dev libdbus-1-dev:i386 pkgconf >/dev/null
/src/prepare-wine.sh /work "$GE_TAG"
cd /work/ge/wine
git reset -q --hard HEAD
for p in /src/*.patch; do git apply "$p"; echo "applied $(basename "$p")"; done
rm -rf /work/out && mkdir -p /work/out/x86_64-unix /work/out/i386-unix
build() {  # dir, configure arguments...
  local dir=$1; shift
  mkdir -p "/work/$dir" && cd "/work/$dir"
  if ! [ -f Makefile ] || ! grep -q '^#define SONAME_LIBVULKAN ' include/config.h 2>/dev/null; then
    rm -f dlls/win32u/vulkan.o dlls/win32u/sni.o
    /work/ge/wine/configure -q --without-mingw --without-x "$@"
  fi
  make -s -j"${JOBS:-4}" dlls/ntdll/ntdll.so dlls/win32u/win32u.so
}
build build64 --enable-win64
cp /work/build64/dlls/ntdll/ntdll.so /work/build64/dlls/win32u/win32u.so /work/out/x86_64-unix/
build build32 CC="gcc -m32" PKG_CONFIG_LIBDIR=/usr/lib/i386-linux-gnu/pkgconfig \
  FREETYPE_CFLAGS="-I/usr/include/freetype2" FREETYPE_LIBS="-lfreetype" FONTCONFIG_CFLAGS= FONTCONFIG_LIBS="-lfontconfig"
cp /work/build32/dlls/ntdll/ntdll.so /work/build32/dlls/win32u/win32u.so /work/out/i386-unix/
strip --strip-unneeded /work/out/*/*.so
ls -l /work/out/*/*.so
