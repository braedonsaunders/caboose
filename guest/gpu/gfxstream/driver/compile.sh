#!/bin/sh
# Runs inside the build image (Dockerfile): /caboose is guest/gpu/gfxstream, /mesa the
# pinned Mesa checkout, both read-only; /out receives the driver. Every path the compiler
# sees is fixed, so identical inputs produce an identical library.
set -eu
/caboose/driver/test.sh /work/tests >/work/tests.log 2>&1 || { cat /work/tests.log >&2; exit 1; }
git -c safe.directory='*' clone --quiet --no-hardlinks /mesa /work/mesa
python3 /caboose/driver/prepare.py /work/mesa
meson setup /work/build /work/mesa --wrap-mode=nodownload \
    -Dplatforms= -Dgallium-drivers= -Dvulkan-drivers=gfxstream \
    -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dbuildtype=release \
    >/work/meson.log 2>&1 || { tail -40 /work/meson.log >&2; exit 1; }
ninja -C /work/build -j "${CABOOSE_BUILD_JOBS:-4}" src/gfxstream/guest/vulkan/libvulkan_gfxstream.so \
    >/work/ninja.log 2>&1 || { tail -60 /work/ninja.log >&2; exit 1; }
cp /work/build/src/gfxstream/guest/vulkan/libvulkan_gfxstream.so /out/
cp /work/mesa/src/gfxstream/caboose-driver.json /out/
cd /out && sha256sum libvulkan_gfxstream.so caboose-driver.json >SHA256SUMS
