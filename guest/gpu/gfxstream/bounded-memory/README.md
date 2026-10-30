# Private bounded memory RPCs

The indexed socket encoder splits ordinary flush and invalidate ranges into
atom-aligned fragments of at most 64 KiB including single-range framing. Flush
holds one encoder lock, packs up to eight fragments into one ordinary
multi-range packet of at most 512 KiB, flushes each deferred-reply packet to the
socket immediately, and pipelines up to eight packets (up to 4 MiB, 64 fragments)
per window before reading every queued provider result in order. Invalidate sends
one fragment per RPC and waits for each result. Original range order and overlaps
are preserved; WHOLE_SIZE ends at the current mapping, and chunks obey the actual
noncoherent atom and allocation-end rules. All ranges are validated before the
first RPC. The original public, non-indexed, direct-mapping and sequenced-stream
methods remain unchanged.

Flush returns the first failed packet's actual provider error only after all
already queued replies in that window have been consumed, and sends no later
packet or window; later packets in the failed window may execute after an earlier
packet fails, and already published bytes have no rollback. A partial send,
failed reply read, or exception with pending packets invalidates the stream;
transport loss takes precedence over a provider error. Fixed packet metadata and
the temporary mapped-range array share the process staging budget. The native
16 MiB frame limit, 64 KiB transport DATA slices, and transport queue budgets
are unchanged. Only flush packets combine fragments; invalidate replies remain
bounded by the original 64 KiB RPC size.

Invalidate retains every chunk until all original ranges succeed, then publishes
in original order. A process-wide 64 MiB budget covers operation staging bytes
and range-plan metadata across concurrent calls; unavailable capacity returns
VK_ERROR_OUT_OF_HOST_MEMORY before any RPC. This is a bounded private profile,
not arbitrary-size or coherent-memory support. Failure returns the original
encoder result and publishes no invalidate bytes. Transport loss retains the
existing VK_ERROR_DEVICE_LOST behavior.

In the synchronous socket profile, command buffer recording (`vkBeginCommandBuffer`
plus unsequenced `vkCmd*` packets) stages locally per command buffer in
`CabooseCommandBufferStream` (`64 KiB` initial chunk, `4 MiB` per-CB cap backed
by `processBudget`) without touching the thread-local socket stream during
recording or emitting cross-thread `OP_vkCommandBufferHostSyncGOOGLE` stalls.
On `vkEndCommandBuffer`, the staged `OP_vkBeginCommandBuffer + OP_vkCmd*` bytes
and `OP_vkEndCommandBuffer` are sent atomically under one thread-local encoder
lock and both 4-byte `VkResult` replies are read in a single round-trip. Any
command buffer that exceeds `4 MiB` or exhausts `processBudget` fails closed on
`vkEndCommandBuffer` with `VK_ERROR_OUT_OF_HOST_MEMORY` without sending partial
commands.

Apply `python3 guest/gpu/gfxstream/prepare_bounded_memory.py PREPARED_PRIVATE_MESA`
after the pinned socket/shadow preparation. It checks upstream hashes and rejects
duplicate application. Compile both VkEncoder.cpp and ResourceTracker.cpp with
CABOOSE_GFXSTREAM_PRIVATE_INDEXED_WSI; setting that macro only on WSI device
objects does not select these wrappers. Existing WSI header additions must be
preserved in the same prepared tree.

Pure checks (no Vulkan provider):

```sh
c++ -std=c++17 -Wall -Wextra -Werror -pthread -UNDEBUG test_ranges.cpp -o /tmp/test_ranges
/tmp/test_ranges
c++ -std=c++17 -Wall -Wextra -Werror -pthread -UNDEBUG test_flush_window.cpp -o /tmp/test_flush_window
/tmp/test_flush_window
c++ -std=c++17 -Wall -Wextra -Werror -pthread -UNDEBUG test_flush_packet.cpp -o /tmp/test_flush_packet
/tmp/test_flush_packet
c++ -std=c++17 -Wall -Wextra -Werror -pthread -UNDEBUG test_flush_timing.cpp -o /tmp/test_flush_timing
/tmp/test_flush_timing
c++ -std=c++17 -Wall -Wextra -Werror -pthread -UNDEBUG test_rpc_timing.cpp -o /tmp/test_rpc_timing
/tmp/test_rpc_timing
c++ -std=c++17 -Wall -Wextra -Werror -pthread -UNDEBUG test_cb_staging.cpp -o /tmp/test_cb_staging
/tmp/test_cb_staging
```

The fixture covers 32 MiB transfers, failure without publication, original
range overlaps, partial maps, allocation tails, atom limits, metadata reservation,
command buffer local staging, and concurrent budget pressure. It does not prove
the generated encoder or GPU transport. Actual acceptance requires the
transformed objects, matching broker credit implementation, exact linked ICD, and
the ordinary Vulkan memory probe with real flush/copy/fence/invalidate byte
comparisons through the current private executor. A library link or fake emit
callback does not establish that runtime result.
