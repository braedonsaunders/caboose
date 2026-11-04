# Synchronization check

`sync_check.c` runs the driver's synchronization paths against a real phone executor and
times them. It needs a computer whose broker has a phone attached (the broker's socket,
`$XDG_RUNTIME_DIR/caboose-gpu/gpu.sock`, exists) and the driver under test. The
[Linux executor](../../../../../apps/ios/GPUStream/gfxstream/linux-executor/README.md) can
stand in for the phone; its `check.sh` runs this probe in a disposable computer.

Build it on any x86-64 Linux host with Vulkan headers and the loader:

```sh
cc -std=c11 -O2 -Wall -Wextra -Wno-missing-field-initializers -Werror \
    -I/path/to/vulkan/include guest/gpu/gfxstream/driver/sync-check/sync_check.c \
    -o sync_check -lvulkan -lxcb
```

Run it on the computer as the seat user with the seat's environment, selecting the driver
under test through a loader manifest (`../../make_manifest.py`) and no layers:

```sh
set -a; . /run/caboose/display.env; set +a
VK_DRIVER_FILES=/path/to/manifest.json VK_LOADER_LAYERS_DISABLE='*' ./sync_check [CASE]
```

`CASE` runs only the cases whose names contain it. Each case prints one
`CABOOSE_SYNC_CHECK case=… PASS|FAIL …` line; the exit status is 1 when a case fails and 2
when the device cannot be set up. A full run takes about fifteen seconds.

| Case | What it does | Passes when |
| --- | --- | --- |
| `event_set2_timeline` | 60 times: a host `vkResetEvent`, a command buffer that sets the event with `vkCmdSetEvent2` in a `vkQueueSubmit2` batch that signals a timeline (DXVK's D3D11 event query), then `vkGetEventStatus` until set | every event reads as set within 3 s and a poll takes under 200 µs on average (answered on the computer, not by the phone) |
| `event_set2_unsignalled` | The same in a batch that signals nothing | as above |
| `event_set1_fence` | `vkCmdSetEvent` in a `vkQueueSubmit` batch with a fence | as above |
| `query_timestamp`, `query_occlusion` | 60 times: a host `vkResetQueryPool`, a command buffer that writes a timestamp or ends an occlusion query, then `vkGetQueryPoolResults` without `WAIT` until available | every result arrives within 3 s |
| `free_after_wait` | 24 times: a 64 MiB buffer filled by the GPU and waited for, then destroyed and its memory freed while a second batch runs on other memory | the device is never lost |
| `completion_after_gpu` | 8 times: a batch of 64 fills of a 256 MiB buffer that ends by writing a new value into host-visible memory, its timeline value waited for (answered by the completion feed), then that memory invalidated, which reads the phone's copy without waiting for the GPU | the new value is there every time: the feed never reports a batch before the GPU has finished it |
| `lazy_query_results` | 4 times: a 1 MiB coherent buffer the GPU may also read (vertex usage) filled by a copy, with a timestamp, the batch waited for, then `vkGetQueryPoolResults` (with `WAIT`) and `vkGetPipelineCacheData` written straight into it, while it is still lazy (lazy readback, `../../bounded-memory/README.md`) | both calls return (a watchdog fails the case after 30 s), the cache data matches a copy written to ordinary memory, and the GPU's bytes before, between and after them are there; without completion payloads the results are read from the device with the encoder held, which a fill needing that encoder deadlocked |
| `unwritten_memory_coherent`, `unwritten_memory_cached` | In coherent and in cached memory: a host-visible buffer written and flushed, invalidated 16 times before anything was submitted, then filled by the GPU and waited for with `vkQueueWaitIdle`, invalidated, and waited for again | the invalidates before the fill keep what was written (they read nothing, `device_work.h`) and the one after reads the fill (in coherent memory through lazy readback): an idle wait with work sent waits for it, and a lazy or GPU-marked block is never taken for unwritten |
| `pool_capacity` | Sets of a two-binding layout allocated one at a time from a pool whose sets run out first and from one whose sampled images run out at the second set, each twice with a reset between | each pool holds exactly the sets it has room for and the next allocation returns `VK_ERROR_OUT_OF_POOL_MEMORY`, with the guest-assigned set handles a phone negotiates |
| `unwritten_sets` | In a pool without and one with `VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT`, 8 rounds each: two sets allocated, the first written (from the second round), both bound to a compute layout in one submit (the first round binds only the unwritten one), its timeline value waited for (answered at once with speculated waits), then, in the freeing pool, both sets freed so the next round takes their ids again | every wait and free succeeds and the device is never lost: the sets are allocated on the device though nothing was written to them, and a free reaches the phone only after the batch that used the set (the Linux executor faulted in lavapipe on a freed set) |
| `one_way_start` | Twice, a new process that makes an instance, its physical device, a device with one queue and that queue as this probe's child processes do, then waits for an empty batch; with the driver's diagnostics on | both processes complete their batch within 40 s, and with one-way start granted (`CABOOSE_GPU_HELLO`) the second sends at least its instance, device and queue without their replies (`CABOOSE_ONE_WAY_START`, `../../bounded-memory/one_way_start.h`) |
| `one_way_misprediction` | A new process with `CABOOSE_ONE_WAY_START=predict` that calls the driver directly (the loader would refuse it) to make an instance enabling a layer no executor has, which nothing before the phone checks, then a device and its queue, waits for an empty batch, and destroys what it made; then this probe runs a batch of its own and starts one more process as `one_way_start` does | with one-way start granted the process sees its device lost (the phone refused the instance it was told of without a reply), destroys its objects and exits within 40 s, never hanging; without it the instance is asked and refused; either way this probe's batch and the next process complete: the executor and the session carry on |
| `threaded_set_frees` | 300 times on one thread: two sets of a pool with `VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT` allocated, written, bound, submitted, waited for and freed, while a second thread creates and destroys buffers | every round succeeds and the device is never lost: a free written to the shared device stream without the encoder lock interleaved with the other thread's commands, and the phone found neither (`Failed to try unbox VkDescriptorSet`, the process lost) |
| `call_*` | 40 each of `vkAllocateDescriptorSets`, `vkCreateBufferView`, `vkBindImageMemory2`, `vkBindBufferMemory2` and `vkGetImageMemoryRequirements2` for an image shape already asked about; one batch then fills the bound buffers, so a failed bind shows as device loss | the mean is under a millisecond: the call did not wait for the phone |
| `pipeline_cache` | A pipeline cache created with 4 MiB of another device's saved data, a compute pipeline built into it, its data read 200 times | the data is the device's empty cache, its 32-byte header with the device's properties, a smaller buffer gets nothing and `VK_INCOMPLETE`, and a read takes under a millisecond: the phone's own cache holds the pipelines |
| `child_windows` | A top-level X11 window with a child that covers it and an inset child, and a second top-level with only an inset child; each child presents 30 cleared frames from a swapchain of its own, interleaved | every present is accepted; `linux-executor/check.sh` also requires each child's surface to retire with 30 frames on the executor |
| `abandoned_work` | Starts this program again (`--abandon`): it submits a batch that waits for a timeline value nothing signals, with a fence, and exits at once | the process exits; `linux-executor/check.sh` also requires the executor to release its wait (`CABOOSE_GPU_RELEASED`) and finish it within 5 s |
| `coherent_rewrite` | A 64 MiB host-coherent buffer filled once, then 30 times written whole with the same bytes but one changed KiB, each followed by a submit, which flushes coherent memory, and its wait | an iteration takes under 20 ms on average: only the changed bytes are sent |
| `exit_latency` | The probe runs itself again as a child that does what a launcher's splash does: an instance, a device, an X11 window with a surface whose capabilities it asks (starting the bind) and a swapchain; it destroys its window and ends, once without destroying anything and once after destroying everything | each child ends under 50 ms after its window went, while its bind may still be in flight; the line also reports how long its setup took (`setup_ms`) |

It also prints the mean time of `vkGetImageMemoryRequirements2` for a new image shape,
which asks the phone once.

`unmapped_popup` runs only when named, against a compositor that maps windows: an
override-redirect window, still unmapped, gets its swapchain (which sends the bind) and a
first frame; a second process (the probe again, `--map-window`) maps it half a second later,
and 30 frames cleared to colours with green half on follow. It passes when all 31 presents
are accepted and the mapper succeeded, and prints the window and how long the first present
took. [`check-unmapped-bind.sh`](../../../../../apps/ios/GPUStream/gfxstream/linux-executor/README.md#bind-of-an-unmapped-popup)
checks what the compositor and the executor did with it.

`one_shot` submits one cleared frame and makes no Vulkan calls for two seconds. The Linux
executor check requires exactly one retired frame. `--lifetime-child` repeats instance,
device, surface and swapchain creation/destruction 32 times with custom allocators. Every
cycle requires zero outstanding bytes at destruction and no callbacks after allocator
lifetime ends. With `CABOOSE_GFXSTREAM_RETIREMENT_DIAGNOSTICS=1`, the Linux executor check
also requires 32 empty native retirement ledgers. Its broker refuses X11 windows that no
longer exist when the delayed bind is answered.

`wayland_present.c` shares the clear/present sequence and exercises a real xdg toplevel:

```sh
wayland-scanner client-header /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml xdg-shell-client-protocol.h
wayland-scanner private-code /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml xdg-shell-protocol.c
cc -std=c11 -O2 -Wall -Wextra -Wno-missing-field-initializers -Werror \
  -I. wayland_present.c xdg-shell-protocol.c -o wayland_present -lvulkan -lxcb -lwayland-client
```

Run `linux-executor/check-wayland.sh IMAGE WORK RELEASE DRIVER WAYLAND_PROBE OUT` to
exercise the release's packaged session/display/broker and require one and 30 frames
on the real Linux executor. Both disposable containers are removed on exit.

`capability_queries.c` measures 184 format/image-format pairs and 16 descriptor-layout
support queries, reporting separate setup, format, device and descriptor timings and an
answer hash. Build with `cc -std=c11 -O2 capability_queries.c -lvulkan -o capability_queries`.
`linux-executor/check-capabilities.sh IMAGE WORK DRIVER PROBE OUT [RELEASE]` runs a cold
process and two fresh processes warmed within the same executor session. With RELEASE,
it uses that payload's session, display and broker. A private empty cache directory keeps
the cold probe independent of compositor queries. Cache diagnostics must show cold misses
and warmed hits; all answer hashes must agree. This is session-warm reuse, not reuse across
executor replacement, and Linux timing does not establish phone timing.
