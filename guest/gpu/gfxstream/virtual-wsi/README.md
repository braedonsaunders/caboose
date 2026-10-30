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

This directory is not connected to Mesa entrypoints. It provides no swapchain,
capability advertisement, acquire synchronization, coherent memory support or
game presentation. `SOURCE_RELEASED` proves source-read completion only; it is not
Vulkan swapchain acquisition or semaphore/fence signaling. The current record set
has no native swapchain create/acquire operation. An empty submit on an application
queue cannot implement acquisition because an earlier same-queue wait on that
acquire semaphore can block it indefinitely.

## Focused Linux verification

With an existing C++17 toolchain in an isolated Linux environment:

```sh
c++ -std=c++17 -Wall -Wextra -Werror client.cpp test_client.cpp -o /tmp/test-wsi
timeout 15 /tmp/test-wsi
python3 check_vectors.py /tmp/test-wsi
```

The test executable uses temporary Unix sockets and reaps its fake peer children.
It checks release ordering, rejects changed identity and oversized result payloads,
and checks terminal EOF without retirement. The vector check reads the independent
frozen CGLV surface vectors from `guest/gpu/broker`, wraps their receiver records
in CGLS, and exercises every truncated prefix and invalid header. These are
transport tests, not real compositor, Vulkan or physical-phone evidence.
