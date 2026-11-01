# zstd decompressor

`zstddeclib.c` is the single-file decompressor of Zstandard 1.5.7 (BSD, `LICENSE`),
generated from the release tarball (`zstd-1.5.7.tar.gz`, SHA-256
`eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3`) with its own
`build/single_file_libs/combine.py -r ../../lib -x legacy/zstd_legacy.h zstddeclib-in.c`.
It is unmodified; `../caboose_zstd.c` includes it and is the only part CabooseKit calls.
