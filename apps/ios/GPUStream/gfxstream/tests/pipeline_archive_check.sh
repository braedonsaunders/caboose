#!/bin/sh
# Checks the patched MoltenVK's persistent Metal pipeline binaries
# (provider-patches/moltenvk-pipeline-binary-archive.patch) on this Mac's GPU.
#
#   sh pipeline_archive_check.sh MOLTENVK_MACOS_ARCHIVE VULKAN_HEADERS_INCLUDE [COUNT]
#
# MOLTENVK_MACOS_ARCHIVE is libMoltenVK.a from the patched "MoltenVK Package (macOS only)"
# build. Needs Xcode and glslangValidator. It builds COUNT (default 64) distinct shader
# pairs, then creates their pipelines in four fresh processes: twice without an archive
# (the second shows what Metal's own shader cache gives), then twice with one (the first
# fills it, the second loads from it). It fails unless every run creates every pipeline,
# the archive was written, and loading it costs no more than Metal's warm cache does
# (within 2x or 50 ms). Metal's own cache is warm here, so this checks that the archive is
# correct and free; it is faster only where that cache is cold.
set -eu
[ $# -ge 2 ] || { echo "usage: $0 MOLTENVK_MACOS_ARCHIVE VULKAN_HEADERS_INCLUDE [COUNT]" >&2; exit 2; }
MVK=$1; HEADERS=$2; COUNT=${3:-64}
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# A different constant in every shader keeps each pipeline distinct to Metal's caches; the
# random salt keeps this run's shaders out of the caches of earlier runs.
SALT=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')
i=0
while [ "$i" -lt "$COUNT" ]; do
  cat > "$WORK/$i.vert" <<EOF
#version 450
layout(location = 0) out vec4 color;
void main() {
  vec2 p = vec2(float(gl_VertexIndex & 1), float(gl_VertexIndex >> 1));
  float k = float($i) * 0.001 + float($SALT % 977u) * 0.0001;
  for (int j = 0; j < 8; ++j) p = vec2(sin(p.x * k + float(j)), cos(p.y + k));
  color = vec4(p, k, 1.0);
  gl_Position = vec4(p, 0.0, 1.0);
}
EOF
  cat > "$WORK/$i.frag" <<EOF
#version 450
layout(location = 0) in vec4 color;
layout(location = 0) out vec4 outColor;
void main() {
  vec4 c = color;
  for (int j = 0; j < 16; ++j) c = fract(c * vec4(1.7, 2.3, 3.1, 1.1) + float($i + j) * 0.013 + float($SALT % 991u) * 0.0001);
  outColor = c;
}
EOF
  glslangValidator -V -o "$WORK/$i.vert.spv" "$WORK/$i.vert" >/dev/null 2>&1
  glslangValidator -V -o "$WORK/$i.frag.spv" "$WORK/$i.frag" >/dev/null 2>&1
  i=$((i + 1))
done
c++ -std=c++17 -O2 -I"$HEADERS" "$HERE/pipeline_archive_check.cpp" "$MVK" -o "$WORK/check" \
  -framework Metal -framework Foundation -framework QuartzCore -framework IOSurface \
  -framework IOKit -framework CoreGraphics -framework AppKit -lc++
run() { MVK_CONFIG_LOG_LEVEL=1 "$WORK/check" "$1" "$WORK" "$COUNT" > "$WORK/$2.out"; echo "$2: $(cat "$WORK/$2.out")"; }
ms() { sed -n 's/.*total_ms=\([0-9.]*\).*/\1/p' "$WORK/$1.out"; }
run - cold
run - system
run "$WORK/archive.bin" fill
[ -s "$WORK/archive.bin" ] || { echo "FAIL: no archive written" >&2; exit 1; }
run "$WORK/archive.bin" archive
# Every pipeline of the fill run was compiled and added; every one of the next run was found.
grep -q "hits=0 misses=$COUNT " "$WORK/fill.out" || { echo "FAIL: the fill run did not compile each pipeline once" >&2; exit 1; }
grep -q "hits=$COUNT misses=0 " "$WORK/archive.out" || { echo "FAIL: the archive did not hold every pipeline" >&2; exit 1; }
echo "archive bytes: $(wc -c < "$WORK/archive.bin" | tr -d ' ')"
awk -v c="$(ms cold)" -v s="$(ms system)" -v a="$(ms archive)" 'BEGIN {
  printf "cold %.1f ms, Metal cache %.1f ms, archive %.1f ms\n", c, s, a
  exit !(a <= 2 * s || a <= s + 50) }' || { echo "FAIL: loading the archive slowed pipeline creation" >&2; exit 1; }
echo "pipeline_archive_check: ok"
