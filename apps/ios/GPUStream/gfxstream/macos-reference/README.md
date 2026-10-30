# macOS real-backend reference

This source-only fixture configures the existing upstream macOS desktop backend,
not the iOS target. It adds the Caboose connection and registry libraries and a
manual lifecycle executable. The offline configure and four adapter syntax checks
pass on macOS; the full target has not been compiled, linked or run.
It does not validate the decoder wire schema, GPU compute, readback, recovery,
coherent memory or physical-phone viability.

Starting from the verified pinned source archive, make a private writable copy.
Apply only the loader-injection patch; do not apply the separate iOS headless
factoring draft. From the Caboose checkout root, substitute absolute paths:

```sh
GFXSTREAM_SOURCE=/absolute/path/to/private/gfxstream
GFXSTREAM_BUILD=/absolute/path/to/private/build
CABOOSE_GFXSTREAM="$PWD/apps/ios/GPUStream/gfxstream"
git -C "$GFXSTREAM_SOURCE" apply --check --unidiff-zero "$CABOOSE_GFXSTREAM/0001-inject-vulkan-loader.patch"
git -C "$GFXSTREAM_SOURCE" apply --unidiff-zero "$CABOOSE_GFXSTREAM/0001-inject-vulkan-loader.patch"
cmake -S "$CABOOSE_GFXSTREAM/macos-reference" -B "$GFXSTREAM_BUILD" -G Ninja \
  -DCABOOSE_GFXSTREAM_SOURCE="$GFXSTREAM_SOURCE" \
  -DCMAKE_BUILD_TYPE=Debug -DDEPENDENCY_RESOLUTION=AOSP \
  -DBUILD_STANDALONE=ON -DENABLE_VKCEREAL_TESTS=OFF
```

Once a build is separately authorized, the narrow target is:

```sh
cmake --build "$GFXSTREAM_BUILD" --target caboose_gfxstream_lifecycle --parallel 1
```

Execution requires a separate hardware/runtime grant and an absolute path to a
real Vulkan loader dynamic library. The loader's exported symbols and
`vkGetInstanceProcAddr` are injected into the same upstream dispatch singleton;
the fixture holds the loader open for the entire process. The target initializes a
real upstream framebuffer with an offscreen Vulkan compositor, associates two
64-bit IDs with real process resources, passes the actual four-byte client flags
and EOF through a socket pair, and invokes real process cleanup. It does not send
any Vulkan command. It can fail honestly if the selected device, loader, required
features or upstream initialization are unavailable.

```sh
"$GFXSTREAM_BUILD/caboose_gfxstream_lifecycle" /absolute/path/to/libvulkan.dylib
```

The build still compiles and links upstream's GL-capable macOS backend, including
AppKit. The fixture is not a demonstration that those desktop dependencies have
been removed. Both the source copy and build directory are disposable; keep the
verified source archive untouched.
