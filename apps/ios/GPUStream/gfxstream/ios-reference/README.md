# Private iOS link probe

This target compiles and links the real upstream offscreen framebuffer, decoder,
connection and registry with a caller-provided stock iOS MoltenVK static archive.
It does not install or run an application. A successful link is not evidence of
GPU execution, stream compatibility, coherent memory or physical-phone behavior.

[`../../../scripts/build-live-gpu.sh`](../../../scripts/build-live-gpu.sh) runs this
recipe for the product runtime: it checks out the gfxstream fork at the commit pinned in
[`../fork.env`](../fork.env), verifies it with `generate-v4-profile.py`, builds MoltenVK
1.4.2 with the SPIRV-Cross provider patch, then configures this project with
presentation leases, indexed WSI and the memory audit on and packages the result.

To configure it by hand, check out the fork at the pinned `GFXSTREAM_COMMIT`. Keep a
separate private snapshot of the Caboose gfxstream adapter. Use an iOS arm64
MoltenVK 1.4.2 archive; the stock release archive has SHA-256
`245e7e05926c55ae97ace1b1822190139d87bda5aaefbcfd2f5156e1287f448b`.

With those paths set to absolute paths and Xcode selected:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer cmake \
  -S "$CABOOSE_ADAPTER_DIR/ios-reference" -B "$CABOOSE_BUILD_DIR" -G Ninja \
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
stub window, replacement decoder or fake GPU implementation is linked. The arm64 iOS 26 link succeeds with the pinned fork commit and MoltenVK archive. It
does not execute Vulkan, validate shaders on a device, or prove decoder runtime
correctness.
