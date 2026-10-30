# Private physical-device diagnostic source

This is an uncompiled fixture adapter, not an app feature or a Vulkan ICD. It must
be explicitly invoked by the signed test application. The root thread owns that
application, signing, installation, transport authentication and device execution.
No public or system Vulkan configuration is changed.

The host integration supplies the existing process-owned MoltenVK
`vkGetInstanceProcAddr` and a resolver for that same provider's real exported
Vulkan trampolines, plus a random nonzero 128-bit session identity, nonzero executor
generation and broker-assigned 64-bit process ID. It reports the returned start
error and uses `caboose_gpu_diagnostic_identity` to report the bound identity.
The upstream dispatch singleton cannot be replaced: an initialization failure or
finish requires a fresh app process for another diagnostic attempt. Upstream logs
carry the detailed framebuffer/compositor error; initialization error `EIO` alone
is not a Vulkan driver result. Parent patch 0009 for compositor pipeline failure
propagation is required before claiming initialization failures are reported fully.

The broker authenticates and binds each guest thread's separate, ordered,
full-duplex connection to that exact process/session/generation outside this byte
stream. The app passes an already connected socket fd to `run`, owns it until the
call returns, and never reuses it during the call. The diagnostic checks the exact
48-byte `CBGLREF1` v1 hello and pinned schema fingerprint, rejects any feature mask
other than zero, and echoes the hello before the guest's existing uint32 flags and
upstream gfxstream bytes enter the real decoder. Direct memory, VirtioGpuNext,
ExternalBlob, decoder snapshots and queue-submit sequence numbers are disabled and
checked against the initialized backend. This is a private test handshake, not a
claim of a finalized Caboose protocol. A caller must not hand over unauthenticated
bytes; generated Vulkan unmarshalling is not hardened against malicious packets.

The handshake deadline is at most 60 seconds and covers both read and reply.
Packet and reply-buffer limits are 256 KiB including framing; the guest probe caps
individual allocations/payloads at 64 KiB. A stop revokes admission, shuts down
handshaking and decoding sockets, and marks the guest process dead. The caller
joins every `run` call before `finish` and serializes finish against all other
calls. `finish` waits for actual upstream cleanup, which has no bounded API; a
host-owned watchdog must report a timeout without claiming cleanup succeeded.
Execution waits may also require the real Vulkan driver to return. Abrupt loss has
no certified recovery and must report device loss rather than fake completion.

## Acceptance sequence, not yet run

1. Link this source against the iOS backend and process-wide nativeVulkan provider,
   including compositor error propagation. Test handshake fragmentation, timeout,
   bad version, mismatched fingerprint/features, duplicate fds and stop races.
2. Forward the guest worker's private AMD64 encoder socket through the authenticated
   broker to this receiver, preserving byte order, per-thread streams and EOF. The
   guest probe from `guest/gpu/gfxstream/draw_probe.cpp` is invoked only in the
   diagnostic environment with its socket, fresh random seed (`seed % 4 == 3`),
   `feedback.comp.spv`, shader directory and output image path. Neither the
   public ICD nor ordinary guests are enabled by this fixture.
3. Capture the guest's actual JSON `feedback_seed` and `gpu_feedback_words`, CPU
   derived indirect arguments, final RGBA and the decoder's executor identity.
   Verify with the guest's unchanged `verify.py` and `expected.json` using
   `compute_cpu_feedback`. Missing, stale, zero or mismatched results fail; the
   fixture never manufactures readback values or CPU decisions. It requires the
   real physical device to expose a usable HOST_VISIBLE noncoherent type and the
   guest's current non-direct mapped-memory path.
4. Report session and generation, actual Vulkan/transport errors, completion and
   readback results, plus teardown outcome separately. A transport hello or byte
   receipt is not GPU completion. Coherent memory, arbitrary extension payloads,
   untrusted-stream safety and crash recovery remain unproven even if this oracle
   passes. Linux lavapipe success is a control, not evidence of phone execution.
