# Native GPU runtimes

`CMakeLists.txt`, `src/` and `include/` build the GFXReconstruct replay player.
[`gfxstream/`](gfxstream/README.md) contains the separate live Vulkan decoder,
its pinned backend patches and real-provider validation fixtures.

## Live runtime package

`../scripts/package-live-gpu.py` packages an already-built, matching physical-iOS
backend with one hash-checked patched MoltenVK archive. It does not download or
build those dependencies. The retained CMake build must contain the
`caboose_gpu_native_runtime` target and its headless dependency closure, with
`CABOOSE_GFXSTREAM_PRESENTATION_LEASE=ON` and `CABOOSE_GFXSTREAM_INDEXED_WSI=ON`; the
caller must first build and validate that exact source using the
[`ios-reference` recipe](gfxstream/patches/ios-reference/README.md).

From `apps/ios`, with the input paths and digest set to the validated artifacts:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
python3 scripts/package-live-gpu.py \
  --build-dir "$GPU_BUILD" \
  --provider "$MOLTENVK_ARCHIVE" --provider-sha256 "$MOLTENVK_SHA256" \
  --vulkan-headers "$VULKAN_HEADERS" \
  --output "$GPU_PACKAGE_OUTPUT/CabooseGPULive.xcframework"
python3 scripts/test_package_live_gpu.py
```

The package contains an iOS arm64 slice, the C module `CabooseGPULive`, and a
provenance receipt with all archive hashes. Existing output is refused. The
packager compiles a Swift module import and links the actual start, surface
prepare/attach/query/present/retire/detach APIs and indexed create/map/acquire/
cancel/observe/release/present/retire APIs into an iOS executable to check
the complete static dependency closure, including the Objective-C Metal-layer
interface. It never runs or installs that executable. The receipt includes the
public presentation-header hashes. Input hashes are rechecked before publication. The
generated provider address table retains only real exports with Vulkan registry
declarations. It resolves dispatch to this statically linked provider without a
process-wide dynamic-symbol search; it does not advertise Vulkan capabilities.
`caboose_gpu_live_start_v4()` initializes that provider once in virtual-WSI mode,
off the main thread. The versioned symbol rejects older native packages at link
time; packaging requires the real indexed-WSI initializer and records the exact
v4/0x70 hello contract. It does not enable an unsupported device feature.
The public header also exposes process open, run, stop and finish. `run` blocks;
`finish` waits for upstream process cleanup after every stream returns. Surface
retirement on a worker and layer detachment on main must complete first: they
release decoder-instance leases that upstream cleanup waits for. A failed
retirement retains the reservation and layer; it does not permit replacement.

The indexed package is kept separate from the selected v3 app package while the
matching wire adapter is incomplete. Selecting it requires the matching v4
consumer; the versioned start symbol deliberately prevents linking an older
consumer against it.

CabooseKit conditionally links a selected package on iOS. Its manifest rejects the
simultaneous presence of the replay `CabooseGPUStream.xcframework`, which contains
a different provider. Without either package, the portable app and tests build
without a native GPU backend. Packaging alone does not activate a connection or
establish presentation, coherent memory, or game compatibility. The live image
lease and its presentation retirement barrier are separate from process cleanup.

## Live connection retirement

`LiveGPUSession` keeps the authenticated WebSocket open during normal `close()`.
Its native consumer sends the session-scoped `EXECUTOR_DRAIN` request after
negotiation. The broker stops admission, requests actual process retirement and
then revokes the generation. The phone returns the existing retirement receipts
only after native cleanup. The broker closes the transport after releasing its
lease; local cleanup alone does not authorize a replacement.

The graceful interval is bounded to ten seconds. A blocked decoder or missing
peer response forces local revocation and reports `drainTimedOut`; it does not
establish remote retirement. `abort()` immediately invokes that local teardown
without a graceful request. Abrupt loss remains fenced at the broker. Neither
path proves presentation-layer retirement.

Run the portable transport, envelope and native-boundary policy tests from
`apps/ios/CabooseKit` with the Xcode Swift toolchain:

```sh
swift test --jobs 1 --filter 'LiveGPUTransportTests|LiveGPUEnvelopeTests|LiveGPUNativeBindingTests|LiveGPUDisplayIdentityTests'
```

These tests use injected runtime operations and socketpairs, not phone GPU work.
