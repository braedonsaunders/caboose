# Private bounded memory RPCs

The indexed socket encoder splits ordinary flush and invalidate ranges into
complete RPCs of at most 64 KiB. Flush holds one encoder lock and pipelines at most eight ordinary packets before
reading every original result in order. Invalidate waits for each original result
before sending its next chunk. Original range order and overlaps are preserved;
WHOLE_SIZE ends at the current mapping, and chunks obey the actual noncoherent
atom and allocation-end rules. All ranges are validated before the first RPC.
The original public, non-indexed, direct-mapping and sequenced-stream methods remain unchanged.

Flush returns the first provider error only after all already queued replies have
been consumed. Later packets in that window may execute after an earlier packet
fails; flush has no rollback. No further window is sent after failure. A partial
send, failed reply read, or exception with pending packets invalidates the stream;
transport loss takes precedence over a provider error. Fixed window metadata shares
the process staging budget; packet and transport limits are unchanged.

Invalidate retains every chunk until all original ranges succeed, then publishes
in original order. A process-wide 64 MiB budget covers operation staging bytes
and range-plan metadata across concurrent calls; unavailable capacity returns
VK_ERROR_OUT_OF_HOST_MEMORY before any RPC. This is a bounded private profile,
not arbitrary-size or coherent-memory support. Failure returns the original
encoder result and publishes no invalidate bytes. Transport loss retains the
existing VK_ERROR_DEVICE_LOST behavior.

Apply `python3 guest/gpu/gfxstream/prepare_bounded_memory.py PREPARED_PRIVATE_MESA`
after the pinned socket/shadow preparation. It checks upstream hashes and rejects
duplicate application. Compile both VkEncoder.cpp and ResourceTracker.cpp with
CABOOSE_GFXSTREAM_PRIVATE_INDEXED_WSI; setting that macro only on WSI device
objects does not select these wrappers. Existing WSI header additions must be
preserved in the same prepared tree.

Pure checks (no Vulkan provider):

```sh
c++ -std=c++17 -Wall -Wextra -Werror -pthread -UNDEBUG test_ranges.cpp -o /tmp/ranges
/tmp/ranges
c++ -std=c++17 -Wall -Wextra -Werror test_flush_window.cpp -o /tmp/flush-window
/tmp/flush-window
```

The fixture covers 32 MiB transfers, failure without publication, original
range overlaps, partial maps, allocation tails, atom limits, metadata reservation
and concurrent budget pressure. It does not prove the generated encoder or GPU
transport. Actual acceptance requires the transformed objects, matching broker
credit implementation, exact linked ICD, and the ordinary Vulkan memory probe
with real flush/copy/fence/invalidate byte comparisons through the current
private executor. A library link or fake emit callback does not establish that
runtime result.
