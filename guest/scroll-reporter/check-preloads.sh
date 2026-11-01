#!/bin/sh
# Checks the preload libraries every application is started with (the scroll reporters and
# guest/draw's cairo recorder) for each architecture the image builds them for. It builds the
# image's preloads stage (guest/container/Dockerfile) in a throwaway image, lays the builds out
# as the install scripts do (lib/MULTIARCH), and starts a 64-bit and a 32-bit process with
# LD_PRELOAD naming each library as ROOT/$LIB/NAME: each must load its own architecture's build
# of every library, and the dynamic loader must report nothing. Needs Docker on an x86-64 host.
# usage: check-preloads.sh
set -eu
guest=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sed -n '/^FROM debian:trixie-slim AS preloads$/,/^FROM /p' "$guest/container/Dockerfile" | sed '$d' > "$work/Dockerfile"
cp -r "$guest/scroll-reporter" "$guest/draw" "$work/"
rm -rf "$work/scroll-reporter/gtk/out" "$work/scroll-reporter/qt/out" "$work/draw/build"
image=caboose-preloads-check:$$
docker build -q -t "$image" "$work" >/dev/null
trap 'rm -rf "$work"; docker image rm -f "$image" >/dev/null' EXIT
docker run --rm --network none "$image" sh -eu -c '
for arch in x86_64-linux-gnu i386-linux-gnu; do
    mkdir -p /opt/s/lib/$arch /opt/d/lib/$arch
    cp /scroll-reporter/gtk/out/$arch/*.so /scroll-reporter/qt/out/$arch/*.so /opt/s/lib/$arch/
    cp /draw/build/$arch/libcaboose-draw-cairo.so /opt/d/lib/$arch/
done
printf "int main(void) { return 0; }\n" > /tmp/m.c
gcc -o /tmp/m64 /tmp/m.c
i686-linux-gnu-gcc -o /tmp/m32 /tmp/m.c
preload=$(cd /opt/s/lib/x86_64-linux-gnu && ls libcaboose-scroll-*.so | grep -v -- -quick | sed "s|^|/opt/s/\$LIB/|" | paste -sd: -)
preload="$preload:/opt/d/\$LIB/libcaboose-draw-cairo.so"
for program in m64:x86_64-linux-gnu m32:i386-linux-gnu; do
    binary=/tmp/${program%%:*}; arch=${program#*:}
    LD_PRELOAD="$preload" LD_DEBUG=files "$binary" > /tmp/out 2>&1
    if grep -q "ERROR: ld.so" /tmp/out; then grep "ERROR: ld.so" /tmp/out >&2; exit 1; fi
    for library in $(echo "$preload" | tr : " "); do
        expected=$(echo "$library" | sed "s|\$LIB|lib/$arch|")
        grep -q "calling init: $expected\$" /tmp/out || { echo "$binary did not load $expected" >&2; exit 1; }
    done
    echo "pass $arch: $(echo "$preload" | tr : "\n" | wc -l) preloads"
done
'
