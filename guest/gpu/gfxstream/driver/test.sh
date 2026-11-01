#!/bin/sh
# Compile and run the unit tests of the Caboose-owned driver sources with the driver's
# configuration. Linux; compile.sh runs it in the build image before every build.
# usage: test.sh [SCRATCH_DIRECTORY]
set -eu
gfxstream=$(cd "$(dirname "$0")/.." && pwd)
scratch=${1:-$(mktemp -d)}
mkdir -p "$scratch"
flags="-std=c++17 -Wall -Wextra -Werror -pthread -UNDEBUG"
config="-DCABOOSE_GFXSTREAM_PRIVATE_ICD -DCABOOSE_GFXSTREAM_PRIVATE_LIVE -DCABOOSE_GFXSTREAM_PRIVATE_INDEXED_WSI"
run() {
    name=$1; shift
    ${cxx:-c++} $flags "$@" -o "$scratch/$name"
    "$scratch/$name" >"$scratch/$name.log" 2>&1 || { cat "$scratch/$name.log" >&2; echo "FAIL $name" >&2; exit 1; }
    echo "pass $name"
}
# The owned headers include each other and Vulkan's headers as they do in the Mesa tree.
mkdir -p "$scratch/include"
ln -sfn "$gfxstream/bounded-memory" "$scratch/include/caboose-bounded-memory"
ln -sfn "$gfxstream/shader-cache" "$scratch/include/caboose-shader-cache"
includes="-I$gfxstream/bounded-memory -I$scratch/include -I${CABOOSE_VULKAN_INCLUDE:-/work/mesa/include}"
for test in "$gfxstream"/bounded-memory/test_*.cpp; do
    run "$(basename "$test" .cpp)" $includes "$test"
done
# Again for the i386 driver, where the compiler is installed (the build image, which has
# the i386 C library but not libstdc++).
if command -v i686-linux-gnu-g++ >/dev/null; then
    cxx=i686-linux-gnu-g++
    for test in "$gfxstream"/bounded-memory/test_*.cpp; do
        run "$(basename "$test" .cpp)-i386" -static-libstdc++ -static-libgcc $includes "$test"
    done
    cxx=
fi
run test_client "$gfxstream/virtual-wsi/test_client.cpp" "$gfxstream/virtual-wsi/client.cpp"
run test_indexed "$gfxstream/virtual-wsi/test_indexed.cpp" "$gfxstream/virtual-wsi/client.cpp"
run test_socket_stream $config -I"$gfxstream/fixtures/iostream" -I"$scratch/include" \
    "$gfxstream/test_socket_stream.cpp" "$gfxstream/SocketStream.cpp"
run feature_emulation_test $includes "$gfxstream/feature-emulation/feature_emulation_test.cpp"
# The shader cache's keys are Mesa's BLAKE3 (portable C, as the driver's build compiles it
# without the x86 assembly), checked against the vectors the phone's store is tested with.
blake3=${CABOOSE_MESA:-/work/mesa}/src/util/blake3
for source in blake3.c blake3_dispatch.c blake3_portable.c; do
    cc -O2 -DBLAKE3_NO_SSE2 -DBLAKE3_NO_SSE41 -DBLAKE3_NO_AVX2 -DBLAKE3_NO_AVX512 -DBLAKE3_USE_NEON=0 \
        -c "$blake3/$source" -o "$scratch/$source.o"
done
c++ $flags -I"$gfxstream/shader-cache" -I"$blake3" "$gfxstream/shader-cache/test_shader_cache.cpp" \
    "$scratch"/blake3*.o -o "$scratch/test_shader_cache"
"$scratch/test_shader_cache" "$gfxstream/shader-cache/vectors.json" >"$scratch/test_shader_cache.log" 2>&1 ||
    { cat "$scratch/test_shader_cache.log" >&2; echo "FAIL test_shader_cache" >&2; exit 1; }
echo "pass test_shader_cache"
c++ $flags -I"$gfxstream/bounded-memory" -I"$blake3" "$gfxstream/upload-cache/test_upload_cache_vectors.cpp" \
    "$scratch"/blake3*.o -o "$scratch/test_upload_cache_vectors"
"$scratch/test_upload_cache_vectors" "$gfxstream/upload-cache/vectors.json" >"$scratch/test_upload_cache_vectors.log" 2>&1 ||
    { cat "$scratch/test_upload_cache_vectors.log" >&2; echo "FAIL test_upload_cache_vectors" >&2; exit 1; }
echo "pass test_upload_cache_vectors"
run d3d11_emulation_test -I"${CABOOSE_VULKAN_INCLUDE:-/work/mesa/include}" \
    "$gfxstream/feature-emulation/d3d11_emulation_test.cpp"
