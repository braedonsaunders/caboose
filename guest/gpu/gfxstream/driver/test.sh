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
    c++ $flags "$@" -o "$scratch/$name"
    "$scratch/$name" >"$scratch/$name.log" 2>&1 || { cat "$scratch/$name.log" >&2; echo "FAIL $name" >&2; exit 1; }
    echo "pass $name"
}
# The owned headers include each other and Vulkan's headers as they do in the Mesa tree.
mkdir -p "$scratch/include"
ln -sfn "$gfxstream/bounded-memory" "$scratch/include/caboose-bounded-memory"
includes="-I$gfxstream/bounded-memory -I$scratch/include -I${CABOOSE_VULKAN_INCLUDE:-/work/mesa/include}"
for test in "$gfxstream"/bounded-memory/test_*.cpp; do
    run "$(basename "$test" .cpp)" $includes "$test"
done
run test_client "$gfxstream/virtual-wsi/test_client.cpp" "$gfxstream/virtual-wsi/client.cpp"
run test_indexed "$gfxstream/virtual-wsi/test_indexed.cpp" "$gfxstream/virtual-wsi/client.cpp"
run test_socket_stream $config -I"$gfxstream/fixtures/iostream" -I"$scratch/include" \
    "$gfxstream/test_socket_stream.cpp" "$gfxstream/SocketStream.cpp"
