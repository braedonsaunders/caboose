# Shader cache (guest side)

`shader_cache.h` is the driver's half of the phone's persistent shader cache
([docs/gpu-live.md](../../../../docs/gpu-live.md#shader-cache)): the SHADER_INVENTORY request
and reply, the 48-byte token, and the decision patch 0041 makes for each
`vkCreateShaderModule`: send the code, or name a module the phone holds by its BLAKE3 hash.
`prepare.py` copies it to `src/gfxstream/guest/vulkan_enc/caboose-shader-cache/`; the hash
is Mesa's (`util/mesa-blake3.h`).

`vectors.json` holds the byte-exact wire forms and BLAKE3 values. The phone's store
(`apps/ios/GPUStream/gfxstream/tests/shader_store_test.cpp`) is tested against the same
file. `test_shader_cache.cpp` checks the wire forms, that the inventory is asked for once
per executor, that modules too small to cache never ask, that a module sent as code is
named by token afterwards only on a single device stream and only when the inventory listed
a key (an executor without a store answers an empty one), and that a failed, malformed or
superseded inventory leaves the process sending code. `../driver/test.sh` builds and runs
it with Mesa's BLAKE3 sources; by hand, from a prepared Mesa tree `MESA`:

```sh
for f in blake3.c blake3_dispatch.c blake3_portable.c; do
  cc -O2 -DBLAKE3_NO_SSE2 -DBLAKE3_NO_SSE41 -DBLAKE3_NO_AVX2 -DBLAKE3_NO_AVX512 -DBLAKE3_USE_NEON=0 \
    -c "$MESA/src/util/blake3/$f" -o "/tmp/$f.o"
done
c++ -std=c++17 -pthread -I guest/gpu/gfxstream/shader-cache -I "$MESA/src/util/blake3" \
  guest/gpu/gfxstream/shader-cache/test_shader_cache.cpp /tmp/blake3*.o -o /tmp/test_shader_cache
/tmp/test_shader_cache guest/gpu/gfxstream/shader-cache/vectors.json
```
