# Native GPU stream player

Build with `sh apps/ios/scripts/build-gpu-stream.sh macos` from the repository root;
`JOBS=1` limits peak compiler memory. Xcode 26.0.1, CMake and Ninja are required for the
hosted check. The script pins GFXReconstruct `4401228c791b11fb7ea15b93795cbd1e938307c0`
and MoltenVK 1.4.2 (release archive SHA-256
`562a15a29bc358446a56a4091c5f7e08f604184187c1d34f712148b61ef17276`).
See [the iOS README](../README.md#gpu-streams) for platform slices and configuration.

## Ownership audit

The replay uses one FileProcessor, decoder, consumer, application and Metal layer factory
per thread. Patch 0003 makes DecodeAllocator and CommonObjectInfoTable thread-local;
FileProcessor destroys its allocator on that replay thread. Consumers acquire and release
the object table there. Device feature structs used in pNext chains are thread-local,
the virtual-swapchain placeholder counter and log-once flags atomic. Immutable lookup
tables remain shared. Logging initializes once, uses its upstream locks and installs one
noncapturing fatal callback. Dump/screenshot image_writer scratch globals are unreachable
with the player's options; Windows driver_info caching, OpenXR and capture page-guard
managers are outside this Mac replay path. Replay-event plugins are not configured.

MoltenVK's environment configuration initializes through a single call_once before the
wrapper exposes any function. Instance creation/destruction and global enumeration calls
share one mutex: MVKLayerManager's outer singleton read lacks synchronization, and
MVKPixelFormats' dummy format-capability reference is written during physical-device
construction. Other functions retain MoltenVK's own behavior. The wrapper first asks
MoltenVK whether a function is available for the supplied instance, including null handles;
it substitutes a wrapper only when that lookup succeeds. Raw lookups are confined to
`src/moltenvk.cpp` and the comparison test. Runtime mutation of MoltenVK global
configuration is outside this API. Device creation/destruction also share this mutex: MoltenVK reads process performance
statistics at device creation and can write them at destruction in
`DEVICE_LIFETIME_ACCUMULATE` mode. Both instance and device proc lookup routes substitute
the device-destruction wrapper, so the device dispatch table cannot bypass that lock.

The Swift Core retains its callback sink until cgpu_player_destroy joins the replay thread.
Queued event closures copy their handler and event; error strings are copied during the
callback. Queued feeds retain Core. Each native player retains its own CAMetalLayer;
layer factories do not share a host layer. Session callbacks carry connection/playback
identities so stale events cannot acknowledge a replacement connection.

## Checks

`.github/workflows/check-gpu-stream.yml` runs pure Swift tests before building the exact
native framework, checks proc availability against actual MoltenVK and stresses concurrent
instance lifetimes, then runs GPUStream tests using the synthetic fixture. The separate
Linux job runs the display workspace protocol and relay tests. No stock framework proves
this source. The fixture's [provenance](tests/fixtures/README.md) distinguishes retained
producer evidence from independently rerun checks.

The machine-checkable cache criterion is `swift test --jobs 1 --filter GPUStreamCacheTests`:
zero and partial writes release exactly their reservation, repeated discard does not
release another stream's bytes, and removed/cleared writers cannot modify replacements, even when deletion fails.
Failed unlink retains actual remaining bytes in the budget and prevents path reuse;
write ownership and I/O are serialized with removal, including same-length overwrites.
The injected internal file-write boundary performs a real partial FileHandle write before
throwing a disk-full error. The native criterion is `swift test --jobs 1 --filter GPUStream`
with CABOOSE_GPU_CAPTURE pointing to the fixture and CABOOSE_GPU_CAPTURE_FRAMES=300:
the second replay must finish while the first has already presented a frame and remains
live, then the resumed first must render the same 300 frames. These checks require the
source-built framework. Hosted results remain required before accepting this lane.

Capability diagnostics use the same GetInstanceProcAddr boundary when integrated. Mixed
capability-query/replay validation belongs to that combined source; a two-player test does
not prove the diagnostics integration. Cache/resume retain the full byte prefix; they do
not implement periodic GPU checkpoints or CPU readback correctness.
