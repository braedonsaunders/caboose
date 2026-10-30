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

The private surface wrapper comes from Mesa's actual Wayland WSI allocator.
Binding uses `wl_proxy_get_id` on the supplied `wl_surface`, an explicit
`CABOOSE_GFXSTREAM_SURFACE_SOCKET`, and a ten-second bind deadline. Query replies
populate the base capabilities, format and mode enumeration APIs, including their
base `*2` forms. Unknown extension chains fail explicitly. Local transport errors
map to the WSI API's surface-loss result; they never become claimed provider
device-loss results. Uncertain bind or retirement retains the bounded wrapper and
instance lease. Destruction completes only after actual native retirement.

The private device advertises no swapchain or dependent presentation extensions,
and surface support returns false: the implemented swapchain path is absent.
Other surface-platform extensions are disabled for this private path. The query
values are unmodified actual provider properties, not claims of a usable device.
The Mesa device swapchain entrypoints are not installed. This source provides no
active swapchain, acquire synchronization, coherent memory support or game
presentation. `SOURCE_RELEASED` proves source-read completion only; it is not
Vulkan swapchain acquisition or semaphore/fence signaling. The indexed control
client does not activate a v4 handshake or advertise the native indexed feature.

The Mesa check is syntax-only against the retained generated headers and compiler
command. `check_mesa_surface.py COMPILE_COMMANDS_JSON TRANSLATED_DEVICE_CPP`
removes compiler output/dependency flags, enables the private Wayland query guard,
prints the exact argv and source hash, and gives the single compiler sixty seconds.
It does not link an ICD or validate runtime compositor integration. The current
toolchain image is identified in `verification.json`; its historical use for the
retained build is not established.

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
