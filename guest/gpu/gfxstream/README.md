# guest/gpu/gfxstream

The guest side of live GPU rendering: the Vulkan driver applications load, and the
broker that relays its command streams to the phone. The protocol is in
[docs/gpu-live.md](../../../docs/gpu-live.md).

| Path | What |
| --- | --- |
| [`driver/`](driver/README.md) | Builds `libvulkan_gfxstream.so` from pinned Mesa, the patch series and the sources below |
| `SocketStream.{h,cpp}` | The driver's transport: a Unix stream socket to the broker and the 48-byte hello that negotiates its features |
| [`virtual-wsi/`](virtual-wsi/README.md) | The driver's surfaces and swapchains, presented on the phone through the broker |
| [`bounded-memory/`](bounded-memory/README.md) | The driver's mapped-memory transfer, command buffer staging and deferred replies |
| `caboose-gpu-broker` and its modules | The broker (below) |
| `make_manifest.py` | Writes a Vulkan loader manifest for a built library after checking its hash |
| `check_opcodes.py` | Compares the guest and decoder opcode tables of the pinned revisions |
| `check_live_broker.py`, `phone_guest_oracle.py` | Broker transport check with a fake executor; feedback renderer run against a broker |
| [`coherent/`](coherent/README.md) | A standalone exact-byte publication library; the driver does not use it |

## The driver

```sh
guest/gpu/gfxstream/driver/build.sh OUTPUT_DIRECTORY
```

builds the driver in a pinned container; [`driver/README.md`](driver/README.md) describes
the build, the patch series, capability negotiation and runtime switches.
`python3 guest/gpu/gfxstream/make_manifest.py LIBRARY SHA256 OUTPUT 1.3.358` writes a
loader manifest naming the library's absolute path; it refuses to replace a manifest.

The driver is Mesa `541c56aa3fd24027ed46ae350287d21dcd56c901`'s gfxstream guest
encoder. The phone's decoder is gfxstream `f0ce013371a68e85b5a1a1b0cf14ac9ad729f4be`
(`apps/ios/GPUStream/gfxstream`). `python3 guest/gpu/gfxstream/check_opcodes.py`
downloads one header from each revision, checks their SHA-256 hashes and compares the
Vulkan opcode names and numbers: all 370 guest opcodes have the decoder's values, and the
decoder has 41 more. Matching opcodes do not by themselves establish compatible
marshaling.

### Diagnostics

The driver accepts `CABOOSE_PRIVATE_GPU_FLUSH_TIMING=1` for bounded
flush diagnostics. Up to 128 numeric call records and one limit marker report
pre-lock validation time, encoder-lock wait time, serialization time, first-reply
buffered-write/wait time, remaining-reply wait time, byte counts and results.
The whole-call elapsed interval begins before validation and encoder-lock
acquisition and reports `validation_us` and `lock_wait_us` separately. The first
reply includes the IOStream buffer commit; neither whole-call elapsed nor
first-reply wait is a pure network round-trip measurement. Each packed flush RPC
has one reply, so its remaining-reply count is zero. Diagnostics preserve
packet ordering, control/lock order and metadata budget accounting, and
do not log handles, addresses or memory contents.

It also accepts `CABOOSE_PRIVATE_GPU_RPC_TIMING=1` for bounded whole-call
timing across ten fixed synchronous RPC entrypoints (`vkQueueSubmit`,
`vkQueueWaitIdle`, `vkDeviceWaitIdle`, `vkResetFences`, `vkWaitForFences`,
`vkBeginCommandBuffer`, `vkEndCommandBuffer`, `vkResetCommandBuffer`,
`vkAllocateDescriptorSets`, `vkResetDescriptorPool`). Up to 128 periodic
two-second numeric snapshots, a final flush snapshot on process exit, and one
limit marker report per-opcode call/error counts, `lock_wait_sum_us`/`max_us`,
and whole-call `elapsed_sum_us`/`max_us` alongside cumulative totals so steady
frames remain observable after high-rate startup calls. Whole-call elapsed
includes validation, encoder-lock wait, marshaling, buffered write and reply
read; it is not network RTT, and records contain no handles, addresses or
payloads.

## Broker

`caboose-gpu-broker` is the private owner-compositor child. It accepts an
inherited Unix control socket and a per-wake token-file path, and binds the
requested local socket only after the executor reports real session readiness.
Its modules use the CGLV codec in `guest/gpu/broker/live_protocol.py`. The
compositor's routing hook is disabled by default; `/gpu` returns HTTP 503 until
it is explicitly wired and the private bridge is validated. `../install-live.py`
stages the broker; it does not start it.

A local stream EOF stops work admission for that stream. The broker retains its
process binding while draining native replies and FIN, including when the original
creator has exited; replies to an exited creator are discarded. Only the actual
PROCESS_RETIRED receipt releases the process identity. New bytes, sockets and
surface requests still require the original live peer identity.

### WSI handle mapping

The local WSI control records carry the encoder's host-boxed Vulkan IDs. Mesa
`internal_object` values are guest gfxstream handles, so instance, physical device,
device, queue, image, semaphore and fence fields use the pinned
`get_host_u64_Vk*` mappings before serialization. Ordinary encoder and
ResourceTracker calls still receive their guest handles. Surface and swapchain
wrapper pointers remain local; the control protocol identifies their native
objects with authenticated grants and returned swapchain IDs.

The private broker accepts `CABOOSE_PRIVATE_GPU_PROGRESS=1` for diagnostic runs.
It records at most 128 surface-control direction/kind/timestamp and successful capability-extent records and one
limit marker per session; records contain no payloads or credentials. Queued
requests do not establish delivery, GPU completion or presentation.
The same opt-in records at most 128 frame-timing aggregates, spaced by at least
two seconds of observed retirement receipts. These contain broker-clock intervals
from indexed-present admission to result, source release and retirement, the
interval between admissions, and queued DATA bytes. They contain no payloads or
identities. Retirement receipt rate is not displayed FPS; intervals include relay
and executor scheduling, and do not isolate GPU execution time.

## Tests

`python3 -m unittest discover -s guest/gpu/gfxstream -p 'test_*.py'` runs the broker,
protocol and driver-series tests. `guest/gpu/gfxstream/driver/test.sh` builds and runs
the driver sources' C++ tests on Linux, including `test_socket_stream.cpp`, which
negotiates the hello against a scripted broker.
