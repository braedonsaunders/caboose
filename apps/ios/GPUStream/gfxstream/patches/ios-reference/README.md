# Private iOS link probe

This target compiles and links the real upstream offscreen framebuffer, decoder,
connection and registry with a caller-provided stock iOS MoltenVK static archive.
It does not install or run an application. A successful link is not evidence of
GPU execution, stream compatibility, coherent memory or physical-phone behavior.

Prepare a private gfxstream copy at pinned commit
`f0ce013371a68e85b5a1a1b0cf14ac9ad729f4be`, and apply the loader patch 0001 and
headless patches 0002 through 0008, then 0010 in that order with
`git apply --unidiff-zero`. Patch 0009 independently propagates compositor pipeline
creation failure and is required for runtime acceptance; it is not included in
the retained link-only result.
Keep a separate private snapshot of the Caboose gfxstream adapter. Use an iOS arm64
MoltenVK 1.4.2 archive from the verified stock release; the archive used for this
probe has SHA-256 `245e7e05926c55ae97ace1b1822190139d87bda5aaefbcfd2f5156e1287f448b`.

With those paths set to absolute paths and Xcode selected, configure and build only
when a compiler slot has been granted:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer cmake \
  -S "$CABOOSE_ADAPTER_DIR/patches/ios-reference" -B "$CABOOSE_BUILD_DIR" -G Ninja \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
  -DCMAKE_BUILD_TYPE=Debug -DDEPENDENCY_RESOLUTION=AOSP \
  -DCABOOSE_GFXSTREAM_SOURCE="$CABOOSE_GFXSTREAM_SOURCE" \
  -DCABOOSE_ADAPTER_DIR="$CABOOSE_ADAPTER_DIR" \
  -DCABOOSE_MOLTENVK_ARCHIVE="$CABOOSE_MOLTENVK_ARCHIVE"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer cmake --build \
  "$CABOOSE_BUILD_DIR" --target caboose_gfxstream_ios_link_probe --parallel 1
```

The executable references actual framebuffer, process registry, decoder connection,
loader injection and MoltenVK entrypoints so the final link must resolve them. No
stub window, replacement decoder or fake GPU implementation is linked. The arm64 iOS 26 link succeeds with these patches and the pinned archive. It
does not execute Vulkan, validate shaders on a device, or prove decoder runtime
correctness.
