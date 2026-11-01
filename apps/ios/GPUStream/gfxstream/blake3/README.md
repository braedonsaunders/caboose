# BLAKE3

The portable and NEON C implementation of [BLAKE3](https://github.com/BLAKE3-team/BLAKE3)
1.8.2 (`c/` at tag `1.8.2`), unmodified. It is used under the Apache License 2.0
([LICENSE_A2](LICENSE_A2)); upstream also offers it under CC0 1.0.

The shader store (`../shader_store.h`) keys SPIR-V modules by their BLAKE3 hash. The guest
driver computes the same hash with Mesa's copy of this library (`src/util/blake3`), and the
vectors in `guest/gpu/gfxstream/shader-cache/vectors.json` pin that both agree.
