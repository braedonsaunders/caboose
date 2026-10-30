# Standalone iOS GPU diagnostic

This app is a separate device diagnostic fixture. It does not modify the
shipping Caboose app or enable a public guest ICD. Root owns build-slot scheduling,
signing, installation and any physical-device execution. The iOS arm64 target
compiles and links with the private patched MoltenVK archive and the half-close
bridge. Physical-device execution is unverified. The compositor failure-propagation
patch 0009 and real device-info patch 0012 are required in the private upstream source.

The app starts no GPU or network work until the user presses **Start diagnostic**.
The launch environment supplies a temporary broker's host and decimal port as
`CABOOSE_GPU_HOST` and `CABOOSE_GPU_PORT`; a SHA-256 pin of its DER leaf certificate
as 64 hex characters in `CABOOSE_GPU_CERT_SHA256`; an opaque random 256-bit token as
64 hex characters in `CABOOSE_GPU_TOKEN`; a random 128-bit nonzero session ID as
32 hex characters in `CABOOSE_GPU_SESSION`; and nonzero decimal uint64 values in
`CABOOSE_GPU_GENERATION` and `CABOOSE_GPU_PROCESS`. Root supplies these privately;
no addresses, pins or tokens belong in source, logs, command arguments or artifacts.
The app emits only session/generation/process, executor identity and error status.

The outbound connection requires TLS 1.3 and authenticates the server by exact
leaf-certificate SHA-256 pin. Once TLS is ready, it writes exactly 64 bytes:
`CBGTLS01`, 16 session bytes, generation as big-endian uint64, and 32 token bytes.
The broker returns one byte: zero accepts, any other byte or EOF rejects. Only then
are the guest's `CBGLREF1` handshake and upstream byte stream carried through a
socketpair to the real decoder. Each direction permits at most one 16 KiB chunk
in flight, preserving order and backpressure. Once decoder output drains, the app
enqueues a TLS final message and waits; send completion is not proof of peer receipt.
After the independent guest oracle and broker finish, the operator can press Stop.
A 90-second transport timer also cancels and shuts down streams; actual Vulkan waits
or upstream cleanup may outlive it and need the external root watchdog. This is one private guest encoder thread and does
not establish the multithreaded production transport.

Starting from the reviewed private source and adapter with the iOS patches (plus
parent's 0009), configure this app using the Xcode generator and the same iOS SDK,
arm64 and MoltenVK archive as the link probe. For example, after setting the three
absolute source/archive variables in the parent shell:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer cmake \
  -S "$CABOOSE_ADAPTER_DIR/diagnostics/app" -B "$CABOOSE_BUILD_DIR" -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
  -DDEPENDENCY_RESOLUTION=AOSP -DCABOOSE_GFXSTREAM_SOURCE="$CABOOSE_GFXSTREAM_SOURCE" \
  -DCABOOSE_ADAPTER_DIR="$CABOOSE_ADAPTER_DIR" \
  -DCABOOSE_MOLTENVK_ARCHIVE="$CABOOSE_MOLTENVK_ARCHIVE"
```

Root reviews the generated project, configures signing and builds the
`CabooseGPUDiagnostic` scheme. The app force-loads the one explicitly selected MoltenVK archive
and exports its trampolines for the same-provider resolver; if these exports are
not available at runtime it fails initialization. Xcode signing credentials or
entitlements are not specified by this project.

The guest probe generates the fresh challenge, runs actual compute, reads GPU
words to its CPU, derives the indirect draw, then returns actual image bytes. The
broker/guest side retains the JSON, image and independent `verify.py` verdict;
the phone app does not invent or cache the verdict. Record app executor identity,
session, generation, decoder status and teardown alongside those guest artifacts.
Any missing/stale feedback, pixel mismatch, TLS/identity failure, shader pipeline
failure, timeout or incomplete teardown is a failed or inconclusive diagnostic,
not a pass. No coherent-memory or failure-recovery claim follows from this fixture.

The source fixture `../tests/graceful_close_test.cpp` exercises input-first and
output-first half-closes, duplicate output EOF and final-send failure. When a
compiler slot is authorized, run it without a GPU or network using:

```sh
c++ -std=c++17 -I apps/ios/GPUStream/gfxstream/diagnostics/app \
  apps/ios/GPUStream/gfxstream/diagnostics/tests/graceful_close_test.cpp \
  -o /tmp/caboose-graceful-close-test
/tmp/caboose-graceful-close-test
```

It tests local transition decisions only; a real broker/TLS test is required to
prove end-to-end delivery and EOF behavior.
