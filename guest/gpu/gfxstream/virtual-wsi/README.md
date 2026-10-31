# Private virtual WSI client

`client.cpp` implements the private CGLS version-1 Unix sequenced-packet client.
It is separate from Mesa's raw Vulkan command streams. The caller supplies an
explicit socket path and serializes access to each client. There is one connection
per native surface. Binding sends only the boxed instance, the object, its namespace
(0, a Wayland `wl_surface` protocol ID; 1, an X11 window ID) and dimensions; the
broker authenticates the connecting process and obtains the window and grant from
the compositor. The client sends no PID or grant.
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

The driver includes `mesa_surface.inc` from `gfxstream_vk_device.cpp` (patches 0002
and 0008 of [`../driver`](../driver/README.md)); `prepare.py` copies these files to
`src/gfxstream/guest/vulkan/caboose-wsi/` in the Mesa tree. When `CABOOSE_GFXSTREAM_SOCKET`
is set, it installs the instance, physical-device and device entry points for surfaces,
presentation support and swapchains; otherwise Mesa's entry points are unchanged.

The surface wrapper is a standard `VkIcdSurfaceWayland` containing the actual display
and surface pointers, a `VkIcdSurfaceXcb` containing the connection and window, or a
`VkIcdSurfaceXlib` containing the Xlib display and window,
allocated with Mesa's Vulkan allocator. It does not need a common window-system backend
or create a Linux presentation buffer. Binding sends the `wl_proxy_get_id` of a Wayland
surface or the X11 window ID, uses an explicit `CABOOSE_GFXSTREAM_SURFACE_SOCKET`,
and a ten-second deadline. Provider replies populate base capabilities, formats
and modes, including the base `*2` forms; a reply less than 500 ms old answers the same
physical device's next query (Zink asks every frame). Unknown extension chains fail
explicitly. Uncertain retirement retains the bounded wrapper and instance lease.

Toolkits create a surface, query it and create a swapchain before its window exists: GTK
for a `wl_surface` without an `xdg_toplevel` yet, X11 toolkits for windows not yet
mapped. The compositor grants a bind only for an existing window, and the broker closes
the connection of a bind it refused; that close is not executor loss (only a bound
connection's end is reported to `peerGone`). The surface binds lazily: a query tries
again at most every 100 ms on a new connection (`Client::reset`), and a present always
tries. Until a bind succeeds, with guest-owned images, queries are answered locally:
the phone's formats (`B8G8R8A8_UNORM` and `_SRGB`, sRGB nonlinear), FIFO, 4 to 8 images,
opaque or premultiplied alpha, and no fixed extent (X11 surfaces report their window's
size). Presentation support needs no window and is answered for the first queue family.
`vkGetPhysicalDevice{Xcb,Xlib,Wayland}PresentationSupportKHR` are returned from
`vkGetInstanceProcAddr` directly (patch 0029).

Each present commits a Wayland application's `wl_surface`, without a buffer, as a window
system's own present does with its buffer: toolkits request their frame callback, regions
and geometry before presenting and pace drawing on that callback.

`mesa_swapchain.inc` supplies the indexed swapchain. It requires the socket's version-4
handshake (mask `0x70`, with or without guest-assigned handles) and a read-only check of
Mesa's actual synchronous feature selection. It exposes basic KHR_swapchain only;
unsupported presentation extensions, device groups and host-image-copy features
are disabled or rejected before native device creation.

CREATE forwards actual creation fields, obtains the provider image count,
allocates decoder-owned images with real compatible memory requirements and
maps the exact ordered array. ACQUIRE forwards the original boxed binary
semaphore/fence and returns only the actual acquired index. Image reuse also
requires the prior source-release proof. PRESENT intercepts the original wait
set before Mesa common prewait; multiple swapchains are rejected before consuming
waits. Native capacity is one frame per surface (two with ordered presents), so the
next presentation waits for actual kind 36 once the window is full. The phone makes capacity available before its final callback is
observable. Source release alone does not
open presentation admission or signal an acquire semaphore.

With hello bit `0x400`, PRESENT sends a device-stream order mark and an ordered present
(kind 39) and returns without waiting for PRESENT_RESULT; `presentOrdered` records the
frame and `pump` (or any later wait) consumes its result when it arrives. A frame that
was not queued ends its swapchain: the next present or acquire returns
`VK_ERROR_OUT_OF_DATE_KHR` (or `VK_ERROR_DEVICE_LOST`), a rejected frame's image counts
as released, and an uncertain frame never retires and is not waited for.

With ordered presents and the completion feed, the next image is acquired right after
each present, on the phone, against one of three private semaphores. The application's
acquire then waits only if that image is not ready yet (honouring its timeout), and one
submission on a presentation-family queue waits for the private semaphore and signals
the application's semaphore and fence. A private semaphore is acquired again only once
its slot's fence shows that hand-off ran. Swapchain retirement first cancels an acquire
made ahead of time; an image it acquired is released by native retirement.

Unknown creation or retirement completion quarantines allocations and prevents
device destruction. Source images are freed only after real swapchain or surface
retirement. App-issued idle calls remain unchanged; the native decoder owns the
observed completion proof for acquired-but-unused images. Source images use
a compatible memory type that is neither host-visible nor host-coherent where the device
has one (lavapipe has none, and its first compatible type is used), and do not
alter application memory-property queries. Guest-visible flags are decoder-projected
properties, not raw Apple provider flags.

## Tests

`../driver/test.sh` builds and runs both client tests on Linux; the driver build runs it
before compiling. By hand:

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

After a revocation the phone owes no further retirements, releases or acquire replies:
waits for them end at once, and present and acquire report `VK_ERROR_OUT_OF_DATE_KHR`.
Once the process's executor is lost (see `../bounded-memory/README.md`), present and
acquire report `VK_ERROR_DEVICE_LOST`. A surface connection the broker closes marks the
executor lost.

With guest-owned images (hello feature `0x800`), the swapchain's images are the guest's
own pool of 4 to 8 (surface capabilities report a minimum of 4 and a maximum of 8, and
offer mailbox). MAP sends them with flag 1 (3 with mailbox), the phone's own swapchain is
a FIFO of its natural size, and there is no SWAPCHAIN_ACQUIRE: acquisition hands the
application an image whose last copy the phone has released, at once, and signals its
semaphore and fence with a submission that has no waits. Each present names a guest
image; the phone acquires a native image inside the present, and drops the frame (it
still reports queued and releases its image) when none is free in mailbox, or after 1 s.

A guest-owned swapchain is created on the guest first, and the phone's swapchain once the
surface binds, at creation or at a later present. Until then each present is dropped:
its wait semaphores are consumed by a submission on its queue and its image is free at
once. The phone copies every presented image into its own, so only the fields its
presentation layer takes reach CREATE: no flags, one layer, exclusive sharing, FIFO,
identity transform, the application's alpha if the phone offers it (else opaque), and
the usage the phone supports of the images' usage, which always adds transfer source and
destination. The images keep the application's usage but are created without flags
(`VK_SWAPCHAIN_CREATE_MUTABLE_FORMAT_BIT_KHR` is accepted and not passed on, since the
phone maps only images without flags) and exclusive. A swapchain whose extent, format or
queue family does not fit the bound window reports `VK_ERROR_OUT_OF_DATE_KHR` at its
next present, as on any window system after a resize.
