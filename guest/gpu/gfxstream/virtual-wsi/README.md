# Private virtual WSI client

`client.cpp` implements the private CGLS version-1 Unix sequenced-packet client.
It is separate from Mesa's raw Vulkan command streams. The caller supplies an
explicit socket path and serializes access to each client. There is one connection
per native Wayland surface. Binding sends only the boxed instance, Wayland object
ID and dimensions; the broker authenticates the connecting process and obtains
the window and grant from the compositor. The client sends no PID or grant.
A zero width/height pair requests the trusted visible owner layer extent. A
positive pair asserts equality with that extent. Mixed zero pairs are rejected.

The client retains the native capability response verbatim. It does not turn it
into Vulkan advertisements. Local transport errors are `std::system_error` values;
native errno and optional Vulkan results remain distinct in `Status`.

Every operation uses an absolute steady-clock deadline. Packets are at most
256 KiB; at most 64 source serials remain outstanding. Received descriptors,
truncated packets, invalid scope identities and unexpected replies terminate the
connection. No background worker or listener is started by the client.

`present` sends the supplied boxed binary wait handles once in one record. It
requires actual GENERAL layout in that record. It neither waits those semaphores
locally nor changes an image layout. The caller must intercept presentation before
Mesa's common WSI prewait and must establish actual remote image layout through
the negotiated private virtual-image implementation.

A successful submission is not source release. `waitReleased` accepts only the
matching native `SOURCE_RELEASED`, including when it precedes the submission
reply. The caller consumes that proof with `consumeRelease` when reusing its
image. `retired()` becomes true only after successful native `SURFACE_RETIRED`;
closing a client, EOF and deadline expiry never establish retirement. The caller
must retain native allocations on uncertain completion and cooperate with broker
process draining.
Release-only waits can expire without closing the connection; they send no
request and create no uncertain submission. `waitAnyReleased` can poll with an
already expired deadline. Other operation deadlines terminate the transport.

The indexed client also encodes CREATE/MAP/ACQUIRE/CANCEL/RETIRE/PRESENT controls
and validates the native count and returned indices. It preserves an acquire that
wins a cancellation race and keeps the platform errno separate from the explicit
local completion reason. Owner revocation stops new admission without discarding
an in-flight acquire result. Request IDs share a surface-wide counter; native
swapchain IDs and present serials use monotonic admission high-water marks.

Indexed source-release proof remains available in a bounded per-image ledger.
Active frame bookkeeping is removed only after matching submission, source release
and final `PRESENT_RETIRED` (kind 36). A rejected-without-submission result removes
its frame record; uncertain work remains reserved. Late native failure events are
retained until final retirement. None of these records signals a guest semaphore.

`../prepare_virtual_wsi_surface.py` installs the native Wayland instance and
physical-device query overrides from `mesa_surface.inc` into a separately prepared
private Mesa tree. It checks the exact pinned upstream blobs and each insertion
anchor before writing, refuses duplicate application, and leaves `prepare_mesa.py`
unchanged. `--check` validates the tree without writing. The overrides require
both private build defines and a Wayland build; the ordinary diagnostic is unchanged.

The private surface wrapper is a standard `VkIcdSurfaceWayland` containing the
actual display and surface pointers, allocated with Mesa's Vulkan allocator.
It does not need a common Wayland backend or create a Linux presentation buffer.
Binding uses `wl_proxy_get_id`, an explicit `CABOOSE_GFXSTREAM_SURFACE_SOCKET`,
and a ten-second deadline. Provider replies populate base capabilities, formats
and modes, including the base `*2` forms. Unknown extension chains fail explicitly.
Uncertain binding or retirement retains the bounded wrapper and instance lease.

`mesa_swapchain.inc` supplies the separate indexed device candidate under
`CABOOSE_GFXSTREAM_PRIVATE_INDEXED_WSI`. It requires the current socket's exact
v4/0x70 handshake and a read-only check of Mesa's actual synchronous feature
selection. The canonical socket implementation is guest-owner commit `6dfa6e45`.
The diagnostic v2 and query-only v3 paths retain their existing behavior; v3
advertises no swapchain. The indexed path exposes basic KHR_swapchain only;
unsupported presentation extensions, device groups and host-image-copy features
are disabled or rejected before native device creation.

CREATE forwards actual creation fields, obtains the provider image count,
allocates decoder-owned images with real compatible memory requirements and
maps the exact ordered array. ACQUIRE forwards the original boxed binary
semaphore/fence and returns only the actual acquired index. Image reuse also
requires the prior source-release proof. PRESENT intercepts the original wait
set before Mesa common prewait; multiple swapchains are rejected before consuming
waits. Native capacity is one frame per surface, so the next presentation waits
for actual kind 36. Native ordering fix `dc151a3c` is required: capacity becomes
available before its final callback is observable. Source release alone does not
open presentation admission or signal an acquire semaphore.

Unknown creation or retirement completion quarantines allocations and prevents
device destruction. Source images are freed only after real swapchain or surface
retirement. App-issued idle calls remain unchanged; the native decoder owns the
observed completion proof for acquired-but-unused images. The source allocator
uses compatible noncoherent types and does not alter application memory-property
queries. Guest-visible flags are decoder-projected properties, not raw Apple
provider flags. General coherent memory and actual game execution are unproven.

The syntax check uses retained generated headers and compiler commands.
`check_mesa_surface.py COMPILE_COMMANDS_JSON TRANSLATED_DEVICE_CPP --indexed`
prints the exact argv and source hash and gives one compiler sixty seconds.
`relink_private.py` describes an isolated incremental link: it recompiles the
changed device, socket, connection-manager and CGLS client translation units,
rebuilds the five-member connection archive, and reuses identified retained
objects read-only. `--plan` prints exact commands without compiling. The caller
bounds the whole invocation and mounts only a fresh output directory writable.
Its manifest hashes input files and thin-archive members. This is not a clean
rebuild or proof that retained objects match unrelated uncommitted source.
The toolchain image and completed checks are recorded in `verification.json`;
the historical image used for the retained build is not established. No phone,
compositor or Vulkan execution is established by syntax or transport fixtures.
The completed incremental link produced a 3,008,352-byte ICD with SHA-256
`8ac1f100a2ce243be98962488b48051949f240271cba141f45f48d3d95b706ff`.
`link-verification.json` records its exact commands and 226 identified input hashes,
including 180 thin-archive members. The library requires `libwayland-client.so.0`
and retains `/work/sysroot/lib` as its runpath. Loader and provider execution are
not established by this link result.

## Focused Linux verification

With an existing C++17 toolchain in an isolated Linux environment:

```sh
c++ -std=c++17 -Wall -Wextra -Werror client.cpp test_client.cpp -o /tmp/test-wsi
timeout 15 /tmp/test-wsi
python3 check_vectors.py /tmp/test-wsi
c++ -std=c++17 -Wall -Wextra -Werror client.cpp test_indexed.cpp -o /tmp/test-indexed
timeout 15 /tmp/test-indexed
python3 check_vectors.py /tmp/test-wsi ../../broker/live-swapchain-vectors.json
```

The test executable uses temporary Unix sockets and reaps its fake peer children.
It checks release ordering, rejects changed identity and oversized result payloads,
and checks terminal EOF without retirement. The vector check reads the independent
frozen CGLV surface vectors from `guest/gpu/broker`, wraps their receiver records
in CGLS, and exercises every truncated prefix and invalid header. These are
transport tests, not real compositor, Vulkan or physical-phone evidence.
The indexed fixture checks 130 frames, cancellation racing actual acquisition,
foreign-platform timeout provenance, owner revocation during acquire, and an index
outside the provider's actual count. Additional frozen vector paths are explicit
arguments to `check_vectors.py`.
