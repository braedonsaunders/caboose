#!/bin/sh
# The two arguments are the baseline and patched spirv-multiplane executables.
set -eu
[ "$#" -eq 2 ] || { echo "usage: $0 BASELINE PATCHED" >&2; exit 2; }
expect() {
    expected=$1; shift
    if "$@"; then actual=0; else actual=$?; fi
    if [ "$actual" -ne "$expected" ]; then
        echo "unexpected exit $actual (expected $expected): $*" >&2
        exit 1
    fi
}
for probe in "$1" "$2"; do
    for first in 0 1; do
        expect 0 "$probe" 1 "$first" 1 0
        expect 0 "$probe" 1 "$first" 2 0
        for planes in 2 3; do
            expect 1 "$probe" "$planes" "$first" 2 0
        done
    done
    expect 1 "$probe" 2 0 1 1
    expect 1 "$probe" 2 0 1 2
done
for first in 0 1; do
    for planes in 2 3; do
        expect 1 "$1" "$planes" "$first" 1 0
        expect 0 "$2" "$planes" "$first" 1 0
    done
done
