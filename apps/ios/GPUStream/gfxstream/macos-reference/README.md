# macOS real-backend reference

This source-only fixture configures the existing upstream macOS desktop backend,
not the iOS target. It adds the Caboose connection and registry libraries and a
manual lifecycle executable. The offline configure and four adapter syntax checks
pass on macOS; the full target has not been compiled, linked or run.
It does not validate the decoder wire schema, GPU compute, readback, recovery,
coherent memory or physical-phone viability.

It uses the gfxstream fork at `GFXSTREAM_LOADER_COMMIT` from
[`../fork.env`](../fork.env): upstream plus loader injection only, without the iOS
headless factoring that follows it. From the Caboose checkout root, substitute absolute
paths:

```sh
GFXSTREAM_SOURCE=/absolute/path/to/private/gfxstream
GFXSTREAM_BUILD=/absolute/path/to/private/build
CABOOSE_GFXSTREAM="$PWD/apps/ios/GPUStream/gfxstream"
. "$CABOOSE_GFXSTREAM/fork.env"
git clone -q "$GFXSTREAM_REPOSITORY" "$GFXSTREAM_SOURCE"
git -C "$GFXSTREAM_SOURCE" checkout -q --detach "$GFXSTREAM_LOADER_COMMIT"
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
