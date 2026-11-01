#!/bin/sh
# Runs inside the build image (Dockerfile): /caboose is guest/gpu/gfxstream, /mesa the
# pinned Mesa checkout, both read-only; /out receives the driver, and /out/i386 the driver
# for 32-bit applications. Every path the compiler sees is fixed, so identical inputs
# produce identical libraries.
set -eu
git -c safe.directory='*' clone --quiet --no-hardlinks /mesa /work/mesa
python3 /caboose/driver/prepare.py /work/mesa
/caboose/driver/test.sh /work/tests >/work/tests.log 2>&1 || { cat /work/tests.log >&2; exit 1; }
# The driver's soname is its own: Mesa's packaged gfxstream manifest names its library by
# the bare libvulkan_gfxstream.so, which the dynamic loader would resolve to this driver
# once loaded (a second ICD for the same phone GPU), in Flatpak runtimes as on the computer.
soname=libvulkan_caboose_gfxstream.so
cat >/work/i386.ini <<'CROSS'
[binaries]
c = 'i686-linux-gnu-gcc'
cpp = 'i686-linux-gnu-g++'
ar = 'i686-linux-gnu-ar'
strip = 'i686-linux-gnu-strip'
pkg-config = 'pkg-config'

[properties]
pkg_config_libdir = ['/usr/lib/i386-linux-gnu/pkgconfig', '/usr/share/pkgconfig']

[host_machine]
system = 'linux'
cpu_family = 'x86'
cpu = 'i686'
endian = 'little'
CROSS
library=src/gfxstream/guest/vulkan/libvulkan_gfxstream.so
# build NAME [MESON_ARGUMENTS]: the driver in /work/build-NAME.
build() {
    name=$1; shift
    meson setup "/work/build-$name" /work/mesa --wrap-mode=nodownload "$@" \
        -Dc_link_args=-Wl,-soname,$soname -Dcpp_link_args=-Wl,-soname,$soname \
        -Dplatforms= -Dgallium-drivers= -Dvulkan-drivers=gfxstream \
        -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dbuildtype=release \
        >"/work/meson-$name.log" 2>&1 || { tail -40 "/work/meson-$name.log" >&2; exit 1; }
    ninja -C "/work/build-$name" -j "${CABOOSE_BUILD_JOBS:-4}" $library \
        >"/work/ninja-$name.log" 2>&1 || { tail -60 "/work/ninja-$name.log" >&2; exit 1; }
    readelf -d "/work/build-$name/$library" | grep -q "Library soname: \[$soname\]" ||
        { echo "the $name driver's soname is not $soname" >&2; exit 1; }
}
build native
build i386 --cross-file /work/i386.ini
readelf -h /work/build-i386/$library | grep -q 'Class: *ELF32' || { echo "the i386 driver is not 32-bit" >&2; exit 1; }
mkdir /out/i386
cp /work/build-native/$library /out/
cp /work/build-i386/$library /out/i386/
cp /work/mesa/src/gfxstream/caboose-driver.json /out/
cd /out && sha256sum libvulkan_gfxstream.so i386/libvulkan_gfxstream.so caboose-driver.json >SHA256SUMS
