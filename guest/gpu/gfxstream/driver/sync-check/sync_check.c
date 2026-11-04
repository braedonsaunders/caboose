// SPDX-License-Identifier: MIT
// Synchronization check for the Caboose Vulkan driver against a live phone executor
// (README.md). Each case prints one CABOOSE_SYNC_CHECK line; the exit status is nonzero
// when a case fails.
#define _POSIX_C_SOURCE 200809L
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <poll.h>
#include <sys/wait.h>
#include <unistd.h>
#include <xcb/xcb.h>
#include <vulkan/vulkan.h>
#include <vulkan/vulkan_xcb.h>

static VkInstance instance;
static VkPhysicalDevice physical;
static VkDevice device;
static VkQueue queue;
static uint32_t family;
static VkCommandPool commandPool;
static VkCommandBuffer cb;
static VkSemaphore timeline;
static uint64_t timelineValue;
static int failures;
static int surfaces2;  // VK_KHR_get_surface_capabilities2 is enabled
static int surfaces;  // the instance has VK_KHR_xcb_surface (and VK_KHR_get_surface_capabilities2 when offered)

static uint64_t nowUs(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000u + (uint64_t)ts.tv_nsec / 1000u;
}

static void fail(const char* what, VkResult result) {
    printf("CABOOSE_SYNC_CHECK fatal %s result=%d\n", what, result);
    exit(2);
}
#define CHECK(call) do { VkResult r_ = (call); if (r_ != VK_SUCCESS) fail(#call, r_); } while (0)

static void report(const char* name, int ok, const char* format, ...) {
    char details[512];
    va_list args;
    va_start(args, format);
    vsnprintf(details, sizeof(details), format, args);
    va_end(args);
    printf("CABOOSE_SYNC_CHECK case=%s %s %s\n", name, ok ? "PASS" : "FAIL", details);
    fflush(stdout);
    if (!ok) ++failures;
}

static void begin(void) {
    CHECK(vkResetCommandPool(device, commandPool, 0));
    VkCommandBufferBeginInfo info = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    info.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    CHECK(vkBeginCommandBuffer(cb, &info));
}

// Submits `cb` with vkQueueSubmit2 the way DXVK does: one batch, a timeline signal, no
// fence. Returns the value signalled, or 0 for a submit that signals nothing.
static uint64_t submit2(int signal) {
    CHECK(vkEndCommandBuffer(cb));
    VkCommandBufferSubmitInfo cbInfo = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO};
    cbInfo.commandBuffer = cb;
    VkSemaphoreSubmitInfo signalInfo = {VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO};
    signalInfo.semaphore = timeline;
    signalInfo.value = ++timelineValue;
    signalInfo.stageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT;
    VkSubmitInfo2 submit = {VK_STRUCTURE_TYPE_SUBMIT_INFO_2};
    submit.commandBufferInfoCount = 1;
    submit.pCommandBufferInfos = &cbInfo;
    if (signal) {
        submit.signalSemaphoreInfoCount = 1;
        submit.pSignalSemaphoreInfos = &signalInfo;
    } else {
        --timelineValue;
    }
    CHECK(vkQueueSubmit2(queue, 1, &submit, VK_NULL_HANDLE));
    return signal ? timelineValue : 0;
}

static void waitTimeline(uint64_t value) {
    VkSemaphoreWaitInfo wait = {VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO};
    wait.semaphoreCount = 1;
    wait.pSemaphores = &timeline;
    wait.pValues = &value;
    CHECK(vkWaitSemaphores(device, &wait, 5000000000ull));
}

// Events: a host reset, a command buffer that sets the event, polled with vkGetEventStatus
// until it reads as set (DXVK's D3D11 event query). Mode 0: vkCmdSetEvent2 in a timeline
// batch; 1: vkCmdSetEvent2 in a batch that signals nothing; 2: vkCmdSetEvent with
// vkQueueSubmit and a fence.
static void eventCase(int mode) {
    static const char* const names[] = {"event_set2_timeline", "event_set2_unsignalled", "event_set1_fence"};
    VkEventCreateInfo info = {VK_STRUCTURE_TYPE_EVENT_CREATE_INFO};
    VkEvent event;
    CHECK(vkCreateEvent(device, &info, NULL, &event));
    VkFenceCreateInfo fenceInfo = {VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    VkFence fence;
    CHECK(vkCreateFence(device, &fenceInfo, NULL, &fence));
    const int iterations = 60;
    int set = 0;
    uint64_t polls = 0, pollUs = 0, worstUs = 0;
    for (int i = 0; i < iterations; ++i) {
        CHECK(vkResetEvent(device, event));
        begin();
        if (mode == 2) {
            vkCmdSetEvent(cb, event, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT);
            CHECK(vkEndCommandBuffer(cb));
            VkSubmitInfo submit = {VK_STRUCTURE_TYPE_SUBMIT_INFO};
            submit.commandBufferCount = 1;
            submit.pCommandBuffers = &cb;
            CHECK(vkQueueSubmit(queue, 1, &submit, fence));
        } else {
            VkMemoryBarrier2 barrier = {VK_STRUCTURE_TYPE_MEMORY_BARRIER_2};
            barrier.srcStageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT;
            barrier.srcAccessMask = VK_ACCESS_2_MEMORY_WRITE_BIT;
            barrier.dstStageMask = VK_PIPELINE_STAGE_2_HOST_BIT;
            barrier.dstAccessMask = VK_ACCESS_2_HOST_READ_BIT;
            VkDependencyInfo dependency = {VK_STRUCTURE_TYPE_DEPENDENCY_INFO};
            dependency.memoryBarrierCount = 1;
            dependency.pMemoryBarriers = &barrier;
            vkCmdSetEvent2(cb, event, &dependency);
            submit2(mode == 0);
        }
        const uint64_t start = nowUs();
        VkResult status = VK_EVENT_RESET;
        while (nowUs() - start < 3000000u) {
            const uint64_t before = nowUs();
            status = vkGetEventStatus(device, event);
            pollUs += nowUs() - before;
            ++polls;
            if (status != VK_EVENT_RESET) break;
        }
        const uint64_t took = nowUs() - start;
        if (took > worstUs) worstUs = took;
        if (status == VK_EVENT_SET) ++set;
        else if (status != VK_EVENT_RESET) fail("vkGetEventStatus", status);
        // Every batch is idle before the next reset, as Vulkan requires.
        if (mode == 2) {
            CHECK(vkWaitForFences(device, 1, &fence, VK_TRUE, 5000000000ull));
            CHECK(vkResetFences(device, 1, &fence));
        } else {
            CHECK(vkQueueWaitIdle(queue));
        }
    }
    const double perPoll = polls ? (double)pollUs / (double)polls : 0;
    // A poll answered on the guest takes microseconds; a round trip to the phone takes
    // milliseconds.
    report(names[mode], set == iterations && perPoll < 200.0,
           "set=%d/%d polls=%llu per_poll_us=%.1f worst_set_ms=%.1f", set, iterations,
           (unsigned long long)polls, perPoll, worstUs / 1000.0);
    vkDestroyFence(device, fence, NULL);
    vkDestroyEvent(device, event, NULL);
}

// Queries: a host reset, a command buffer that writes the query, polled with
// vkGetQueryPoolResults without WAIT until available (DXVK's D3D11 queries).
static void queryCase(VkQueryType type) {
    const char* name = type == VK_QUERY_TYPE_TIMESTAMP ? "query_timestamp" : "query_occlusion";
    VkQueryPoolCreateInfo info = {VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO};
    info.queryType = type;
    info.queryCount = 64;
    VkQueryPool pool;
    CHECK(vkCreateQueryPool(device, &info, NULL, &pool));
    const int iterations = 60;
    int ready = 0;
    uint64_t polls = 0, pollUs = 0, worstUs = 0;
    for (int i = 0; i < iterations; ++i) {
        const uint32_t query = (uint32_t)(i % 64);
        vkResetQueryPool(device, pool, query, 1);
        begin();
        if (type == VK_QUERY_TYPE_TIMESTAMP) {
            vkCmdWriteTimestamp2(cb, VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, pool, query);
        } else {
            vkCmdBeginQuery(cb, pool, query, 0);
            vkCmdEndQuery(cb, pool, query);
        }
        const uint64_t value = submit2(1);
        const uint64_t start = nowUs();
        VkResult status = VK_NOT_READY;
        uint64_t result = 0;
        while (nowUs() - start < 3000000u) {
            const uint64_t before = nowUs();
            status = vkGetQueryPoolResults(device, pool, query, 1, sizeof(result), &result, sizeof(result),
                                           VK_QUERY_RESULT_64_BIT);
            pollUs += nowUs() - before;
            ++polls;
            if (status != VK_NOT_READY) break;
        }
        const uint64_t took = nowUs() - start;
        if (took > worstUs) worstUs = took;
        if (status == VK_SUCCESS) ++ready;
        else if (status != VK_NOT_READY) fail("vkGetQueryPoolResults", status);
        waitTimeline(value);
    }
    const double perPoll = polls ? (double)pollUs / (double)polls : 0;
    report(name, ready == iterations, "ready=%d/%d polls=%llu per_poll_us=%.1f worst_ready_ms=%.1f", ready,
           iterations, (unsigned long long)polls, perPoll, worstUs / 1000.0);
    vkDestroyQueryPool(device, pool, NULL);
}

static uint32_t memoryType(uint32_t bits, VkMemoryPropertyFlags want) {
    VkPhysicalDeviceMemoryProperties props;
    vkGetPhysicalDeviceMemoryProperties(physical, &props);
    for (uint32_t i = 0; i < props.memoryTypeCount; ++i)
        if ((bits & (1u << i)) && (props.memoryTypes[i].propertyFlags & want) == want) return i;
    for (uint32_t i = 0; i < props.memoryTypeCount; ++i)
        if (bits & (1u << i)) return i;
    fail("memoryType", VK_ERROR_FEATURE_NOT_PRESENT);
    return 0;
}

// Frees: a 64 MiB buffer filled by the GPU, its batch waited for on the timeline, then the
// buffer destroyed and its memory freed, while a second batch still runs (the release
// before the device loss in phone-console-0141). The device must survive every round.
static void freeCase(void) {
    const VkDeviceSize size = 64ull << 20;
    const int rounds = 24;
    VkBuffer keep;
    VkDeviceMemory keepMemory;
    VkBufferCreateInfo bufferInfo = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
    bufferInfo.size = size;
    bufferInfo.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
    CHECK(vkCreateBuffer(device, &bufferInfo, NULL, &keep));
    VkMemoryRequirements req;
    vkGetBufferMemoryRequirements(device, keep, &req);
    VkMemoryAllocateInfo alloc = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    alloc.allocationSize = req.size;
    alloc.memoryTypeIndex = memoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    CHECK(vkAllocateMemory(device, &alloc, NULL, &keepMemory));
    CHECK(vkBindBufferMemory(device, keep, keepMemory, 0));
    uint64_t worstUs = 0;
    for (int i = 0; i < rounds; ++i) {
        VkBuffer buffer;
        VkDeviceMemory memory;
        CHECK(vkCreateBuffer(device, &bufferInfo, NULL, &buffer));
        CHECK(vkAllocateMemory(device, &alloc, NULL, &memory));
        VkBindBufferMemoryInfo bind = {VK_STRUCTURE_TYPE_BIND_BUFFER_MEMORY_INFO};
        bind.buffer = buffer;
        bind.memory = memory;
        CHECK(vkBindBufferMemory2(device, 1, &bind));
        begin();
        vkCmdFillBuffer(cb, buffer, 0, VK_WHOLE_SIZE, (uint32_t)i);
        const uint64_t used = submit2(1);
        waitTimeline(used);
        // A second batch, on unrelated memory, is in flight while the first one's buffer goes.
        begin();
        for (int k = 0; k < 8; ++k) vkCmdFillBuffer(cb, keep, 0, VK_WHOLE_SIZE, (uint32_t)k);
        const uint64_t busy = submit2(1);
        const uint64_t start = nowUs();
        vkDestroyBuffer(device, buffer, NULL);
        vkFreeMemory(device, memory, NULL);
        const uint64_t took = nowUs() - start;
        if (took > worstUs) worstUs = took;
        waitTimeline(busy);
    }
    CHECK(vkDeviceWaitIdle(device));
    vkDestroyBuffer(device, keep, NULL);
    vkFreeMemory(device, keepMemory, NULL);
    report("free_after_wait", 1, "rounds=%d worst_free_us=%llu", rounds, (unsigned long long)worstUs);
}

// The feed reports a batch complete only once the GPU has finished it. A long batch ends by
// writing a new value into host-visible memory; once its timeline value is reported reached
// (answered by the feed), that memory is invalidated, which reads the phone's copy without
// waiting for the GPU. The old value there means the completion was reported early.
static void completionCase(void) {
    const VkDeviceSize size = 256ull << 20;
    VkBufferCreateInfo bufferInfo = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
    bufferInfo.size = size;
    bufferInfo.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    VkBuffer big, small;
    CHECK(vkCreateBuffer(device, &bufferInfo, NULL, &big));
    VkMemoryRequirements req;
    vkGetBufferMemoryRequirements(device, big, &req);
    VkMemoryAllocateInfo alloc = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    alloc.allocationSize = req.size;
    alloc.memoryTypeIndex = memoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    VkDeviceMemory bigMemory, smallMemory;
    CHECK(vkAllocateMemory(device, &alloc, NULL, &bigMemory));
    CHECK(vkBindBufferMemory(device, big, bigMemory, 0));
    bufferInfo.size = 4096;
    CHECK(vkCreateBuffer(device, &bufferInfo, NULL, &small));
    vkGetBufferMemoryRequirements(device, small, &req);
    alloc.allocationSize = req.size;
    alloc.memoryTypeIndex = memoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT);
    CHECK(vkAllocateMemory(device, &alloc, NULL, &smallMemory));
    CHECK(vkBindBufferMemory(device, small, smallMemory, 0));
    void* mapped = NULL;
    CHECK(vkMapMemory(device, smallMemory, 0, VK_WHOLE_SIZE, 0, &mapped));
    const VkMappedMemoryRange range = {VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE, NULL, smallMemory, 0, VK_WHOLE_SIZE};
    const int rounds = 8;
    int early = 0;
    uint64_t batchUs = 0;
    for (int i = 0; i < rounds; ++i) {
        const uint32_t before = 0x1000u + 2u * (uint32_t)i, after = before + 1;
        begin();
        vkCmdFillBuffer(cb, small, 0, VK_WHOLE_SIZE, before);
        waitTimeline(submit2(1));
        begin();
        for (int k = 0; k < 64; ++k) vkCmdFillBuffer(cb, big, 0, VK_WHOLE_SIZE, (uint32_t)(i + k));
        VkMemoryBarrier2 barrier = {VK_STRUCTURE_TYPE_MEMORY_BARRIER_2};
        barrier.srcStageMask = VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT;
        barrier.srcAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT;
        barrier.dstStageMask = VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT;
        barrier.dstAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT;
        VkDependencyInfo dependency = {VK_STRUCTURE_TYPE_DEPENDENCY_INFO};
        dependency.memoryBarrierCount = 1;
        dependency.pMemoryBarriers = &barrier;
        vkCmdPipelineBarrier2(cb, &dependency);  // the small write comes after the big ones
        vkCmdFillBuffer(cb, small, 0, VK_WHOLE_SIZE, after);
        const uint64_t start = nowUs();
        waitTimeline(submit2(1));
        batchUs += nowUs() - start;
        CHECK(vkInvalidateMappedMemoryRanges(device, 1, &range));
        if (*(volatile uint32_t*)mapped != after) ++early;
    }
    vkUnmapMemory(device, smallMemory);
    CHECK(vkDeviceWaitIdle(device));
    vkDestroyBuffer(device, small, NULL);
    vkFreeMemory(device, smallMemory, NULL);
    vkDestroyBuffer(device, big, NULL);
    vkFreeMemory(device, bigMemory, NULL);
    report("completion_after_gpu", early == 0, "rounds=%d early=%d mean_batch_ms=%.1f", rounds, early,
           batchUs / 1000.0 / rounds);
}

// Surface formats and present modes enumerated the usual way, a count and then an array of
// that size, from the moment a window's surface exists (while it binds to the phone, whose
// answers then replace the local defaults): every enumeration must succeed with the count
// it reported, through vkGetPhysicalDeviceSurfaceFormatsKHR, ...Formats2KHR and
// ...PresentModesKHR. DXVK fails to create its swapchain on VK_INCOMPLETE.
static void surfaceCase(void) {
    if (!surfaces) {
        printf("CABOOSE_SYNC_CHECK note=surface_enumeration skipped (no X11 display)\n");
        return;
    }
    xcb_connection_t* connection = xcb_connect(NULL, NULL);
    if (xcb_connection_has_error(connection)) {
        printf("CABOOSE_SYNC_CHECK note=surface_enumeration skipped (no X11 connection)\n");
        return;
    }
    const xcb_setup_t* setup = xcb_get_setup(connection);
    xcb_screen_t* screen = xcb_setup_roots_iterator(setup).data;
    PFN_vkGetPhysicalDeviceSurfaceFormats2KHR formats2 =
        surfaces2 ? (PFN_vkGetPhysicalDeviceSurfaceFormats2KHR)vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceSurfaceFormats2KHR") : NULL;
    int bad = 0, enumerations = 0;
    uint32_t fewestFormats = UINT32_MAX, mostFormats = 0;
    char first[96] = "";
    for (int round = 0; round < 5; ++round) {
        xcb_window_t window = xcb_generate_id(connection);
        xcb_create_window(connection, XCB_COPY_FROM_PARENT, window, screen->root, 0, 0, 320, 240, 0,
                          XCB_WINDOW_CLASS_INPUT_OUTPUT, screen->root_visual, 0, NULL);
        xcb_map_window(connection, window);
        xcb_flush(connection);
        VkXcbSurfaceCreateInfoKHR surfaceInfo = {VK_STRUCTURE_TYPE_XCB_SURFACE_CREATE_INFO_KHR};
        surfaceInfo.connection = connection;
        surfaceInfo.window = window;
        VkSurfaceKHR surface;
        CHECK(vkCreateXcbSurfaceKHR(instance, &surfaceInfo, NULL, &surface));
        for (int i = 0; i < 40; ++i) {
            uint32_t count = 0, filled;
            VkResult result = vkGetPhysicalDeviceSurfaceFormatsKHR(physical, surface, &count, NULL);
            VkSurfaceFormatKHR formats[64];
            // Work between the two calls, as an application allocating its array does: the
            // window's bind may complete in between.
            struct timespec between = {0, 25 * 1000 * 1000};
            nanosleep(&between, NULL);
            filled = count < 64 ? count : 64;
            VkResult fill = result == VK_SUCCESS ? vkGetPhysicalDeviceSurfaceFormatsKHR(physical, surface, &filled, formats) : result;
            ++enumerations;
            if (result == VK_SUCCESS) {
                if (count < fewestFormats) fewestFormats = count;
                if (count > mostFormats) mostFormats = count;
            }
            if (result != VK_SUCCESS || fill != VK_SUCCESS || filled != count) {
                if (!bad++) snprintf(first, sizeof(first), "formats round=%d i=%d count=%u filled=%u result=%d", round, i, count, filled, fill);
            }
            if (formats2) {
                VkPhysicalDeviceSurfaceInfo2KHR info = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SURFACE_INFO_2_KHR};
                info.surface = surface;
                count = 0;
                result = formats2(physical, &info, &count, NULL);
                VkSurfaceFormat2KHR formats2Out[64];
                for (int k = 0; k < 64; ++k) {
                    formats2Out[k].sType = VK_STRUCTURE_TYPE_SURFACE_FORMAT_2_KHR;
                    formats2Out[k].pNext = NULL;
                }
                filled = count < 64 ? count : 64;
                fill = result == VK_SUCCESS ? formats2(physical, &info, &filled, formats2Out) : result;
                ++enumerations;
                if (result != VK_SUCCESS || fill != VK_SUCCESS || filled != count) {
                    if (!bad++) snprintf(first, sizeof(first), "formats2 round=%d i=%d count=%u filled=%u result=%d", round, i, count, filled, fill);
                }
            }
            count = 0;
            result = vkGetPhysicalDeviceSurfacePresentModesKHR(physical, surface, &count, NULL);
            VkPresentModeKHR modes[16];
            filled = count < 16 ? count : 16;
            fill = result == VK_SUCCESS ? vkGetPhysicalDeviceSurfacePresentModesKHR(physical, surface, &filled, modes) : result;
            ++enumerations;
            if (result != VK_SUCCESS || fill != VK_SUCCESS || filled != count) {
                if (!bad++) snprintf(first, sizeof(first), "modes round=%d i=%d count=%u filled=%u result=%d", round, i, count, filled, fill);
            }
            struct timespec pause = {0, 50 * 1000 * 1000};  // 2 s a window: span its bind
            nanosleep(&pause, NULL);
        }
        vkDestroySurfaceKHR(instance, surface, NULL);
        xcb_destroy_window(connection, window);
        xcb_flush(connection);
    }
    xcb_disconnect(connection);
    // Formats that change across the bind (local defaults, then the phone's) are what an
    // enumeration must survive; the range shows whether this run saw that change.
    report("surface_enumeration", bad == 0, "enumerations=%d inconsistent=%d formats=%u..%u%s%s", enumerations, bad,
           fewestFormats == UINT32_MAX ? 0 : fewestFormats, mostFormats, bad ? " first: " : "", first);
}

// A descriptor pool reports VK_ERROR_OUT_OF_POOL_MEMORY when an allocation exceeds its sets or
// its descriptors, also when the sets' handles are assigned without waiting for the phone: an
// application (DXVK) moves to a new pool, and recycles the full one, only on that result.
static void poolCapacityCase(void) {
    VkDescriptorSetLayoutBinding bindings[2] = {
        {0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, VK_SHADER_STAGE_ALL, NULL},
        {1, VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 2, VK_SHADER_STAGE_ALL, NULL},
    };
    VkDescriptorSetLayoutCreateInfo layoutInfo = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
    layoutInfo.bindingCount = 2;
    layoutInfo.pBindings = bindings;
    VkDescriptorSetLayout layout;
    CHECK(vkCreateDescriptorSetLayout(device, &layoutInfo, NULL, &layout));
    // Pool A holds 4 sets and descriptors for 8: its sets run out first. Pool B holds 8 sets
    // but sampled images for 3: its images run out at the second set.
    VkDescriptorPoolSize sizesA[2] = {{VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 8}, {VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 16}};
    VkDescriptorPoolSize sizesB[2] = {{VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 8}, {VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 3}};
    struct { const char* name; uint32_t maxSets; VkDescriptorPoolSize* sizes; uint32_t fits; } pools[2] = {
        {"sets", 4, sizesA, 4}, {"descriptors", 8, sizesB, 1}};
    int ok = 1;
    char details[256] = "";
    size_t used = 0;
    for (int p = 0; p < 2; ++p) {
        VkDescriptorPoolCreateInfo poolInfo = {VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};
        poolInfo.maxSets = pools[p].maxSets;
        poolInfo.poolSizeCount = 2;
        poolInfo.pPoolSizes = pools[p].sizes;
        VkDescriptorPool pool;
        CHECK(vkCreateDescriptorPool(device, &poolInfo, NULL, &pool));
        for (int round = 0; round < 2; ++round) {  // again after a reset
            uint32_t made = 0;
            VkResult last = VK_SUCCESS;
            for (uint32_t i = 0; i <= pools[p].fits; ++i) {
                VkDescriptorSetAllocateInfo setInfo = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
                setInfo.descriptorPool = pool;
                setInfo.descriptorSetCount = 1;
                setInfo.pSetLayouts = &layout;
                VkDescriptorSet set;
                last = vkAllocateDescriptorSets(device, &setInfo, &set);
                if (last != VK_SUCCESS) break;
                ++made;
            }
            const int good = made == pools[p].fits && last == VK_ERROR_OUT_OF_POOL_MEMORY;
            ok &= good;
            used += (size_t)snprintf(details + used, sizeof(details) - used, "%s%s/%d made=%u of %u result=%d",
                                     used ? " " : "", pools[p].name, round, made, pools[p].fits, last);
            CHECK(vkResetDescriptorPool(device, pool, 0));
        }
        vkDestroyDescriptorPool(device, pool, NULL);
    }
    vkDestroyDescriptorSetLayout(device, layout, NULL);
    report("pool_capacity", ok, "%s", details);
}

// Sets bound without any descriptor written since their allocation: a set the shader never
// reads (DXVK's sets for unused stages, a set of immutable samplers) is still allocated on the
// device by the submit that binds it, with batched descriptor sets as without. Each round binds
// such a set alone, beside a written one, and again after a free and a reallocation in a pool
// that frees sets one by one; a set the device never allocated binds nothing there (the Linux
// executor faults on it, as lavapipe reads the set) and a later free names a set it never had.
static void unwrittenSetsCase(void) {
    VkDescriptorSetLayoutBinding binding = {0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL};
    VkDescriptorSetLayoutCreateInfo layoutInfo = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
    layoutInfo.bindingCount = 1;
    layoutInfo.pBindings = &binding;
    VkDescriptorSetLayout layout;
    CHECK(vkCreateDescriptorSetLayout(device, &layoutInfo, NULL, &layout));
    VkDescriptorSetLayout layouts[2] = {layout, layout};
    VkPipelineLayoutCreateInfo pipelineLayoutInfo = {VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
    pipelineLayoutInfo.setLayoutCount = 2;
    pipelineLayoutInfo.pSetLayouts = layouts;
    VkPipelineLayout pipelineLayout;
    CHECK(vkCreatePipelineLayout(device, &pipelineLayoutInfo, NULL, &pipelineLayout));
    VkBufferCreateInfo bufferInfo = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
    bufferInfo.size = 256;
    bufferInfo.usage = VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
    VkBuffer buffer;
    CHECK(vkCreateBuffer(device, &bufferInfo, NULL, &buffer));
    VkMemoryRequirements req;
    vkGetBufferMemoryRequirements(device, buffer, &req);
    VkMemoryAllocateInfo memoryInfo = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    memoryInfo.allocationSize = req.size;
    memoryInfo.memoryTypeIndex = memoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    VkDeviceMemory memory;
    CHECK(vkAllocateMemory(device, &memoryInfo, NULL, &memory));
    CHECK(vkBindBufferMemory(device, buffer, memory, 0));
    VkDescriptorPoolSize size = {VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 64};
    int ok = 1, rounds = 0;
    VkResult last = VK_SUCCESS;
    char first[160] = "";
    for (int freeing = 0; freeing < 2 && ok; ++freeing) {
        VkDescriptorPoolCreateInfo poolInfo = {VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};
        poolInfo.flags = freeing ? VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT : 0;
        poolInfo.maxSets = 64;
        poolInfo.poolSizeCount = 1;
        poolInfo.pPoolSizes = &size;
        VkDescriptorPool pool;
        CHECK(vkCreateDescriptorPool(device, &poolInfo, NULL, &pool));
        for (int round = 0; round < 8 && ok; ++round) {
            // Round 0 of each pool: an unwritten set alone; then beside a written one; in the
            // freeing pool, the written set is freed after its submit and the next round's
            // allocation takes its id again.
            VkDescriptorSetAllocateInfo setInfo = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
            setInfo.descriptorPool = pool;
            setInfo.descriptorSetCount = 2;
            setInfo.pSetLayouts = layouts;
            VkDescriptorSet sets[2];
            if ((last = vkAllocateDescriptorSets(device, &setInfo, sets)) != VK_SUCCESS) {
                ok = 0;
                snprintf(first, sizeof(first), "allocate pool=%d round=%d", freeing, round);
                break;
            }
            if (round > 0) {
                VkDescriptorBufferInfo described = {buffer, 0, 256};
                VkWriteDescriptorSet write = {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET};
                write.dstSet = sets[0];
                write.descriptorCount = 1;
                write.descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
                write.pBufferInfo = &described;
                vkUpdateDescriptorSets(device, 1, &write, 0, NULL);
            }
            begin();
            if (round > 0) vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipelineLayout, 0, 2, sets, 0, NULL);
            else vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipelineLayout, 1, 1, &sets[1], 0, NULL);
            const uint64_t value = submit2(1);
            VkSemaphoreWaitInfo wait = {VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO};
            wait.semaphoreCount = 1;
            wait.pSemaphores = &timeline;
            wait.pValues = &value;
            if ((last = vkWaitSemaphores(device, &wait, 5000000000ull)) != VK_SUCCESS) {
                ok = 0;
                snprintf(first, sizeof(first), "wait pool=%d round=%d", freeing, round);
                break;
            }
            if (freeing && (last = vkFreeDescriptorSets(device, pool, 2, sets)) != VK_SUCCESS) {
                ok = 0;
                snprintf(first, sizeof(first), "free pool=%d round=%d", freeing, round);
                break;
            }
            ++rounds;
        }
        if (ok && (last = vkDeviceWaitIdle(device)) != VK_SUCCESS) {
            ok = 0;
            snprintf(first, sizeof(first), "idle pool=%d", freeing);
        }
        vkDestroyDescriptorPool(device, pool, NULL);
    }
    vkDestroyBuffer(device, buffer, NULL);
    vkFreeMemory(device, memory, NULL);
    vkDestroyPipelineLayout(device, pipelineLayout, NULL);
    vkDestroyDescriptorSetLayout(device, layout, NULL);
    report("unwritten_sets", ok, "rounds=%d of 16 result=%d%s%s", rounds, last, ok ? "" : " at ", first);
}

// Calls that must not wait for the phone: each is timed; a round trip takes milliseconds.
static void callsCase(void) {
    const int n = 40;
    // vkAllocateDescriptorSets
    VkDescriptorSetLayoutBinding binding = {0, VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, 1, VK_SHADER_STAGE_ALL, NULL};
    VkDescriptorSetLayoutCreateInfo layoutInfo = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
    layoutInfo.bindingCount = 1;
    layoutInfo.pBindings = &binding;
    VkDescriptorSetLayout layout;
    CHECK(vkCreateDescriptorSetLayout(device, &layoutInfo, NULL, &layout));
    VkDescriptorPoolSize poolSize = {VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, (uint32_t)n};
    VkDescriptorPoolCreateInfo poolInfo = {VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};
    poolInfo.maxSets = (uint32_t)n;
    poolInfo.poolSizeCount = 1;
    poolInfo.pPoolSizes = &poolSize;
    VkDescriptorPool descriptorPool;
    CHECK(vkCreateDescriptorPool(device, &poolInfo, NULL, &descriptorPool));
    VkBufferCreateInfo bufferInfo = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
    bufferInfo.size = 1 << 20;
    bufferInfo.usage = VK_BUFFER_USAGE_UNIFORM_TEXEL_BUFFER_BIT;
    VkBuffer texel;
    CHECK(vkCreateBuffer(device, &bufferInfo, NULL, &texel));
    VkMemoryRequirements req;
    vkGetBufferMemoryRequirements(device, texel, &req);
    VkMemoryAllocateInfo alloc = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    alloc.allocationSize = req.size;
    alloc.memoryTypeIndex = memoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    VkDeviceMemory texelMemory;
    CHECK(vkAllocateMemory(device, &alloc, NULL, &texelMemory));
    CHECK(vkBindBufferMemory(device, texel, texelMemory, 0));

    uint64_t allocUs = 0, viewUs = 0, bindImageUs = 0, bindBufferUs = 0, reqUs = 0, firstReqUs = 0;
    uint64_t allocMax = 0, viewMax = 0, bindImageMax = 0, bindBufferMax = 0, reqMax = 0, firstReqMax = 0;
#define TIMED(sum, max, call) do { const uint64_t t0_ = nowUs(); CHECK(call); const uint64_t d_ = nowUs() - t0_; sum += d_; if (d_ > max) max = d_; } while (0)
#define TIMED_VOID(sum, max, call) do { const uint64_t t0_ = nowUs(); call; const uint64_t d_ = nowUs() - t0_; sum += d_; if (d_ > max) max = d_; } while (0)
    VkDescriptorSet sets[64];
    VkBufferView views[64];
    VkImage images[64];
    VkBuffer buffers[64];
    VkDeviceMemory imageMemory[64], bufferMemory[64];
    for (int i = 0; i < n; ++i) {
        VkDescriptorSetAllocateInfo setInfo = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
        setInfo.descriptorPool = descriptorPool;
        setInfo.descriptorSetCount = 1;
        setInfo.pSetLayouts = &layout;
        TIMED(allocUs, allocMax, vkAllocateDescriptorSets(device, &setInfo, &sets[i]));
        VkBufferViewCreateInfo viewInfo = {VK_STRUCTURE_TYPE_BUFFER_VIEW_CREATE_INFO};
        viewInfo.buffer = texel;
        viewInfo.format = VK_FORMAT_R32_UINT;
        viewInfo.offset = 0;
        viewInfo.range = (VkDeviceSize)(256 * (i + 1));
        TIMED(viewUs, viewMax, vkCreateBufferView(device, &viewInfo, NULL, &views[i]));

        VkImageCreateInfo imageInfo = {VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
        imageInfo.imageType = VK_IMAGE_TYPE_2D;
        imageInfo.format = VK_FORMAT_R8G8B8A8_UNORM;
        imageInfo.extent = (VkExtent3D){256, (uint32_t)(64 + (i % 4) * 64), 1};
        imageInfo.mipLevels = 1;
        imageInfo.arrayLayers = 1;
        imageInfo.samples = VK_SAMPLE_COUNT_1_BIT;
        imageInfo.tiling = VK_IMAGE_TILING_OPTIMAL;
        imageInfo.usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
        CHECK(vkCreateImage(device, &imageInfo, NULL, &images[i]));
        VkImageMemoryRequirementsInfo2 reqInfo = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_REQUIREMENTS_INFO_2};
        reqInfo.image = images[i];
        VkMemoryDedicatedRequirements dedicated = {VK_STRUCTURE_TYPE_MEMORY_DEDICATED_REQUIREMENTS};
        VkMemoryRequirements2 req2 = {VK_STRUCTURE_TYPE_MEMORY_REQUIREMENTS_2};
        req2.pNext = &dedicated;
        // Four image shapes: the first of each asks the phone, the rest repeat a known one.
        if (i < 4) TIMED_VOID(firstReqUs, firstReqMax, vkGetImageMemoryRequirements2(device, &reqInfo, &req2));
        else TIMED_VOID(reqUs, reqMax, vkGetImageMemoryRequirements2(device, &reqInfo, &req2));
        VkMemoryAllocateInfo imageAlloc = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
        imageAlloc.allocationSize = req2.memoryRequirements.size;
        imageAlloc.memoryTypeIndex = memoryType(req2.memoryRequirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        CHECK(vkAllocateMemory(device, &imageAlloc, NULL, &imageMemory[i]));
        VkBindImageMemoryInfo bindImage = {VK_STRUCTURE_TYPE_BIND_IMAGE_MEMORY_INFO};
        bindImage.image = images[i];
        bindImage.memory = imageMemory[i];
        TIMED(bindImageUs, bindImageMax, vkBindImageMemory2(device, 1, &bindImage));

        VkBufferCreateInfo plainInfo = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
        plainInfo.size = 65536;
        plainInfo.usage = VK_BUFFER_USAGE_VERTEX_BUFFER_BIT;
        CHECK(vkCreateBuffer(device, &plainInfo, NULL, &buffers[i]));
        VkMemoryRequirements plainReq;
        vkGetBufferMemoryRequirements(device, buffers[i], &plainReq);
        VkMemoryAllocateInfo plainAlloc = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
        plainAlloc.allocationSize = plainReq.size;
        plainAlloc.memoryTypeIndex = memoryType(plainReq.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        CHECK(vkAllocateMemory(device, &plainAlloc, NULL, &bufferMemory[i]));
        VkBindBufferMemoryInfo bindBuffer = {VK_STRUCTURE_TYPE_BIND_BUFFER_MEMORY_INFO};
        bindBuffer.buffer = buffers[i];
        bindBuffer.memory = bufferMemory[i];
        TIMED(bindBufferUs, bindBufferMax, vkBindBufferMemory2(device, 1, &bindBuffer));
    }
    // Everything made above is used once, so a failed create or bind shows as device loss.
    begin();
    for (int i = 0; i < n; ++i) vkCmdFillBuffer(cb, buffers[i], 0, VK_WHOLE_SIZE, 1);
    waitTimeline(submit2(1));
    CHECK(vkDeviceWaitIdle(device));
    for (int i = 0; i < n; ++i) {
        vkDestroyBufferView(device, views[i], NULL);
        vkDestroyImage(device, images[i], NULL);
        vkFreeMemory(device, imageMemory[i], NULL);
        vkDestroyBuffer(device, buffers[i], NULL);
        vkFreeMemory(device, bufferMemory[i], NULL);
    }
    vkDestroyDescriptorPool(device, descriptorPool, NULL);
    vkDestroyDescriptorSetLayout(device, layout, NULL);
    vkDestroyBuffer(device, texel, NULL);
    vkFreeMemory(device, texelMemory, NULL);
    // Each mean must stay under a millisecond: a call that waits for the phone does not.
    const struct { const char* name; uint64_t sum, max; } calls[] = {
        {"vkAllocateDescriptorSets", allocUs, allocMax},
        {"vkCreateBufferView", viewUs, viewMax},
        {"vkBindImageMemory2", bindImageUs, bindImageMax},
        {"vkBindBufferMemory2", bindBufferUs, bindBufferMax},
        {"vkGetImageMemoryRequirements2_repeated", reqUs, reqMax},
    };
    printf("CABOOSE_SYNC_CHECK note=vkGetImageMemoryRequirements2_new_shape n=4 mean_us=%.1f max_us=%llu\n",
           (double)firstReqUs / 4, (unsigned long long)firstReqMax);
    for (size_t i = 0; i < sizeof(calls) / sizeof(calls[0]); ++i) {
        const double mean = (double)calls[i].sum / (i == 4 ? n - 4 : n);
        char name[64];
        snprintf(name, sizeof(name), "call_%s", calls[i].name);
        report(name, mean < 1000.0, "n=%d mean_us=%.1f max_us=%llu", n, mean, (unsigned long long)calls[i].max);
    }
}

// Host-coherent memory rewritten with what it already holds, as an application refilling its
// upload or constant buffers each frame does: a 64 MiB buffer filled once, then 30 times
// written whole with the same bytes but one changed KiB, each followed by a submit (which
// flushes coherent memory) and its wait. Only the changed bytes should travel, so an
// iteration takes well under the time 64 MiB takes to send.
static void coherentRewriteCase(void) {
    const VkDeviceSize size = 64u << 20;
    VkBufferCreateInfo bufferInfo = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
    bufferInfo.size = size;
    bufferInfo.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
    VkBuffer buffer;
    CHECK(vkCreateBuffer(device, &bufferInfo, NULL, &buffer));
    VkMemoryRequirements req;
    vkGetBufferMemoryRequirements(device, buffer, &req);
    VkMemoryAllocateInfo alloc = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    alloc.allocationSize = req.size;
    alloc.memoryTypeIndex = memoryType(req.memoryTypeBits,
                                       VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    VkDeviceMemory memory;
    CHECK(vkAllocateMemory(device, &alloc, NULL, &memory));
    CHECK(vkBindBufferMemory(device, buffer, memory, 0));
    uint8_t* mapped;
    CHECK(vkMapMemory(device, memory, 0, VK_WHOLE_SIZE, 0, (void**)&mapped));
    uint8_t* source = malloc(size);
    if (!source) fail("malloc", VK_ERROR_OUT_OF_HOST_MEMORY);
    for (VkDeviceSize i = 0; i < size; ++i) source[i] = (uint8_t)(i * 13 + (i >> 12));
    memcpy(mapped, source, size);
    begin();
    waitTimeline(submit2(1));
    const int iterations = 30;
    uint64_t totalUs = 0, worstUs = 0;
    for (int i = 0; i < iterations; ++i) {
        const uint64_t t0 = nowUs();
        source[(size_t)i * 1024 * 1024 + 7] ^= 0x5A;
        memcpy(mapped, source, size);
        begin();
        waitTimeline(submit2(1));
        const uint64_t d = nowUs() - t0;
        totalUs += d;
        if (d > worstUs) worstUs = d;
    }
    free(source);
    vkUnmapMemory(device, memory);
    vkDestroyBuffer(device, buffer, NULL);
    vkFreeMemory(device, memory, NULL);
    const double meanMs = (double)totalUs / iterations / 1000.0;
    report("coherent_rewrite", meanMs < 20.0, "mib=64 iterations=%d mean_ms=%.1f max_ms=%.1f", iterations, meanMs,
           (double)worstUs / 1000.0);
}

// A swapchain on one X11 window, presenting frames cleared to a color.
struct Presenter {
    VkSurfaceKHR surface;
    VkSwapchainKHR swapchain;
    VkImage images[16];
    uint32_t imageCount;
    VkSemaphore acquired, rendered;
    VkFence done;
    int presented;
};

static void presenterSetup(struct Presenter* p, uint32_t width, uint32_t height) {
    VkBool32 supported = VK_FALSE;
    CHECK(vkGetPhysicalDeviceSurfaceSupportKHR(physical, family, p->surface, &supported));
    if (!supported) fail("vkGetPhysicalDeviceSurfaceSupportKHR", VK_ERROR_FEATURE_NOT_PRESENT);
    VkSurfaceCapabilitiesKHR caps;
    CHECK(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical, p->surface, &caps));
    uint32_t count = 16;
    VkSurfaceFormatKHR formats[16];
    VkResult listed = vkGetPhysicalDeviceSurfaceFormatsKHR(physical, p->surface, &count, formats);
    if ((listed != VK_SUCCESS && listed != VK_INCOMPLETE) || !count) fail("vkGetPhysicalDeviceSurfaceFormatsKHR", listed);
    VkSwapchainCreateInfoKHR info = {VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR};
    info.surface = p->surface;
    info.minImageCount = caps.minImageCount;
    info.imageFormat = formats[0].format;
    info.imageColorSpace = formats[0].colorSpace;
    info.imageExtent = caps.currentExtent.width != UINT32_MAX ? caps.currentExtent : (VkExtent2D){width, height};
    info.imageArrayLayers = 1;
    info.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    info.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
    info.preTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
    info.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    info.presentMode = VK_PRESENT_MODE_FIFO_KHR;
    info.clipped = VK_TRUE;
    CHECK(vkCreateSwapchainKHR(device, &info, NULL, &p->swapchain));
    p->imageCount = 16;
    CHECK(vkGetSwapchainImagesKHR(device, p->swapchain, &p->imageCount, p->images));
    VkSemaphoreCreateInfo semaphoreInfo = {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
    CHECK(vkCreateSemaphore(device, &semaphoreInfo, NULL, &p->acquired));
    CHECK(vkCreateSemaphore(device, &semaphoreInfo, NULL, &p->rendered));
    VkFenceCreateInfo fenceInfo = {VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    CHECK(vkCreateFence(device, &fenceInfo, NULL, &p->done));
}

static void presenterCreate(struct Presenter* p, xcb_connection_t* connection, xcb_window_t window,
                            uint32_t width, uint32_t height) {
    memset(p, 0, sizeof(*p));
    VkXcbSurfaceCreateInfoKHR surfaceInfo = {VK_STRUCTURE_TYPE_XCB_SURFACE_CREATE_INFO_KHR};
    surfaceInfo.connection = connection;
    surfaceInfo.window = window;
    CHECK(vkCreateXcbSurfaceKHR(instance, &surfaceInfo, NULL, &p->surface));
    presenterSetup(p,width,height);
}

// One frame: acquire, clear to `shade`, present. Counts presents the driver accepted.
static void presenterFrame(struct Presenter* p, float shade) {
    uint32_t index;
    VkResult acquired = vkAcquireNextImageKHR(device, p->swapchain, 5000000000ull, p->acquired, VK_NULL_HANDLE, &index);
    if (acquired != VK_SUCCESS && acquired != VK_SUBOPTIMAL_KHR) return;
    begin();
    VkImageSubresourceRange range = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    VkImageMemoryBarrier toClear = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
    toClear.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    toClear.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    toClear.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    toClear.srcQueueFamilyIndex = toClear.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    toClear.image = p->images[index];
    toClear.subresourceRange = range;
    vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &toClear);
    VkClearColorValue color = {{shade, 0.5f, 1.0f - shade, 1.0f}};
    vkCmdClearColorImage(cb, p->images[index], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &color, 1, &range);
    VkImageMemoryBarrier toPresent = toClear;
    toPresent.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    toPresent.dstAccessMask = 0;
    toPresent.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    toPresent.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, NULL, 0, NULL, 1, &toPresent);
    CHECK(vkEndCommandBuffer(cb));
    const VkPipelineStageFlags stage = VK_PIPELINE_STAGE_TRANSFER_BIT;
    VkSubmitInfo submit = {VK_STRUCTURE_TYPE_SUBMIT_INFO};
    submit.waitSemaphoreCount = 1;
    submit.pWaitSemaphores = &p->acquired;
    submit.pWaitDstStageMask = &stage;
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &cb;
    submit.signalSemaphoreCount = 1;
    submit.pSignalSemaphores = &p->rendered;
    CHECK(vkResetFences(device, 1, &p->done));
    CHECK(vkQueueSubmit(queue, 1, &submit, p->done));
    VkPresentInfoKHR present = {VK_STRUCTURE_TYPE_PRESENT_INFO_KHR};
    present.waitSemaphoreCount = 1;
    present.pWaitSemaphores = &p->rendered;
    present.swapchainCount = 1;
    present.pSwapchains = &p->swapchain;
    present.pImageIndices = &index;
    const VkResult presented = vkQueuePresentKHR(queue, &present);
    if (presented == VK_SUCCESS || presented == VK_SUBOPTIMAL_KHR) ++p->presented;
    // The command buffer is reused by the next frame.
    CHECK(vkWaitForFences(device, 1, &p->done, VK_TRUE, 5000000000ull));
}

static void presenterDestroy(struct Presenter* p) {
    CHECK(vkDeviceWaitIdle(device));
    vkDestroyFence(device, p->done, NULL);
    vkDestroySemaphore(device, p->acquired, NULL);
    vkDestroySemaphore(device, p->rendered, NULL);
    vkDestroySwapchainKHR(device, p->swapchain, NULL);
    vkDestroySurfaceKHR(instance, p->surface, NULL);
}

static xcb_window_t createWindow(xcb_connection_t* connection, xcb_window_t parent, xcb_visualid_t visual,
                                 int16_t x, int16_t y, uint16_t width, uint16_t height) {
    xcb_window_t window = xcb_generate_id(connection);
    xcb_create_window(connection, XCB_COPY_FROM_PARENT, window, parent, x, y, width, height, 0,
                      XCB_WINDOW_CLASS_INPUT_OUTPUT, visual, 0, NULL);
    xcb_map_window(connection, window);
    return window;
}

// Child windows with their own swapchains, as a browser's GPU process draws its views: a
// top-level with a child that covers it and an inset child beside it, and a second top-level
// with only an inset child. Every swapchain must present every frame; the executor's log
// shows each window's frames (linux-executor/check.sh).
static void childWindowsCase(void) {
    if (!surfaces) {
        printf("CABOOSE_SYNC_CHECK note=child_windows skipped (no X11 display)\n");
        return;
    }
    xcb_connection_t* connection = xcb_connect(NULL, NULL);
    if (xcb_connection_has_error(connection)) {
        printf("CABOOSE_SYNC_CHECK note=child_windows skipped (no X11 connection)\n");
        return;
    }
    xcb_screen_t* screen = xcb_setup_roots_iterator(xcb_get_setup(connection)).data;
    const xcb_visualid_t visual = screen->root_visual;
    const xcb_window_t first = createWindow(connection, screen->root, visual, 0, 0, 640, 480);
    const xcb_window_t covering = createWindow(connection, first, visual, 0, 0, 640, 480);
    const xcb_window_t inset = createWindow(connection, first, visual, 40, 120, 400, 240);
    const xcb_window_t second = createWindow(connection, screen->root, visual, 700, 0, 320, 240);
    const xcb_window_t lone = createWindow(connection, second, visual, 16, 32, 200, 150);
    xcb_flush(connection);
    struct Presenter presenters[3];
    presenterCreate(&presenters[0], connection, covering, 640, 480);
    presenterCreate(&presenters[1], connection, inset, 400, 240);
    presenterCreate(&presenters[2], connection, lone, 200, 150);
    const int frames = 30;
    for (int i = 0; i < frames; ++i)
        for (int k = 0; k < 3; ++k) presenterFrame(&presenters[k], (float)i / frames);
    for (int k = 0; k < 3; ++k) presenterDestroy(&presenters[k]);
    xcb_destroy_window(connection, first);
    xcb_destroy_window(connection, second);
    xcb_flush(connection);
    xcb_disconnect(connection);
    const int all = presenters[0].presented == frames && presenters[1].presented == frames &&
                    presenters[2].presented == frames;
    report("child_windows", all, "frames=%d covering=%d inset=%d lone_inset=%d windows=%#x,%#x,%#x", frames,
           presenters[0].presented, presenters[1].presented, presenters[2].presented, covering, inset, lone);
}

// A popup as a toolkit makes a menu: an override-redirect window, still unmapped, gets its
// surface and swapchain (which sends the bind) and its first frame; another process maps it
// half a second later, as a toolkit's UI process shows a menu its GPU process drew, and 30
// more frames follow. The compositor holds the bind until the window maps and answers it
// then (unmapped-bind check: linux-executor/check-unmapped-bind.sh). Run only by name.
static void unmappedPopupCase(void) {
    if (!surfaces) fail("unmapped_popup needs an X11 display", VK_ERROR_INITIALIZATION_FAILED);
    xcb_connection_t* connection = xcb_connect(NULL, NULL);
    if (xcb_connection_has_error(connection)) fail("unmapped_popup X11", VK_ERROR_INITIALIZATION_FAILED);
    xcb_screen_t* screen = xcb_setup_roots_iterator(xcb_get_setup(connection)).data;
    const xcb_window_t parent = createWindow(connection, screen->root, screen->root_visual, 0, 0, 640, 480);
    const xcb_window_t popup = xcb_generate_id(connection);
    const uint32_t overrideRedirect = 1;
    xcb_create_window(connection, XCB_COPY_FROM_PARENT, popup, screen->root, 40, 40, 320, 200, 0,
                      XCB_WINDOW_CLASS_INPUT_OUTPUT, screen->root_visual, XCB_CW_OVERRIDE_REDIRECT, &overrideRedirect);
    xcb_flush(connection);
    fflush(stdout);
    const pid_t mapper = fork();
    if (mapper < 0) fail("fork", VK_ERROR_INITIALIZATION_FAILED);
    if (mapper == 0) {
        char windowArg[16];
        snprintf(windowArg, sizeof(windowArg), "%u", popup);
        execl("/proc/self/exe", "sync_check", "--map-window", windowArg, "500", (char*)NULL);
        _exit(4);
    }
    struct Presenter presenter;
    presenterCreate(&presenter, connection, popup, 320, 200);
    const uint64_t start = nowUs();
    presenterFrame(&presenter, 0.0f);
    const double firstMs = (double)(nowUs() - start) / 1000.0;
    int status = 0;
    waitpid(mapper, &status, 0);
    const int mapped = WIFEXITED(status) && WEXITSTATUS(status) == 0;
    const int frames = 30;
    for (int i = 0; i < frames; ++i) presenterFrame(&presenter, (float)i / frames);
    presenterDestroy(&presenter);
    xcb_destroy_window(connection, popup);
    xcb_destroy_window(connection, parent);
    xcb_flush(connection);
    xcb_disconnect(connection);
    report("unmapped_popup", mapped && presenter.presented == frames + 1,
           "accepted=%d window=%#x mapped_by_other_process=%d first_frame_ms=%.1f", presenter.presented, popup, mapped,
           firstMs);
}

// The mapper of unmappedPopupCase: maps `window` after `delayMs` on a connection of its own.
static int mapWindowChild(xcb_window_t window, int delayMs) {
    xcb_connection_t* connection = xcb_connect(NULL, NULL);
    if (xcb_connection_has_error(connection)) return 2;
    struct timespec pause = {delayMs / 1000, (long)(delayMs % 1000) * 1000000L};
    nanosleep(&pause, NULL);
    xcb_generic_error_t* error = xcb_request_check(connection, xcb_map_window_checked(connection, window));
    xcb_disconnect(connection);
    if (error) { free(error); return 3; }
    return 0;
}

// Exactly one present followed by no Vulkan calls: a delayed bind must progress
// independently. The executor verifies the frame, not merely the API return value.
static void oneShotCase(void) {
    if (!surfaces) return;
    xcb_connection_t* connection=xcb_connect(NULL,NULL);
    if (xcb_connection_has_error(connection)) fail("one-shot X11",VK_ERROR_INITIALIZATION_FAILED);
    xcb_screen_t* screen=xcb_setup_roots_iterator(xcb_get_setup(connection)).data;
    const xcb_window_t window=createWindow(connection,screen->root,screen->root_visual,0,0,320,240);
    xcb_flush(connection);
    struct Presenter presenter;
    presenterCreate(&presenter,connection,window,320,240);
    const uint64_t start=nowUs();
    presenterFrame(&presenter,0.25f);
    const uint64_t elapsed=nowUs()-start;
    struct timespec pause={2,0};
    nanosleep(&pause,NULL);
    presenterDestroy(&presenter);
    xcb_destroy_window(connection,window);
    xcb_flush(connection);
    xcb_disconnect(connection);
    report("one_shot",presenter.presented==1,"accepted=%d window=%#x first_frame_ms=%.3f",
           presenter.presented,window,elapsed/1000.0);
}

// Application pipeline caches: created with 4 MiB of saved data (another device's, so any
// driver ignores it), a compute pipeline built into one, its data read back 200 times. The
// data is the empty cache of this device, 32 bytes of VkPipelineCacheHeaderVersionOne with
// its properties, and no read waits for the phone: the phone's own cache, which it seeds into
// every application cache, holds the pipelines.
static void pipelineCacheCase(const VkPhysicalDeviceProperties* props) {
    // void main() {} with local size 1x1x1.
    static const uint32_t spirv[] = {
        0x07230203, 0x00010000, 0, 5, 0,
        0x00020011, 1,                                  // OpCapability Shader
        0x0003000E, 0, 1,                               // OpMemoryModel Logical GLSL450
        0x0005000F, 5, 1, 0x6E69616D, 0,                // OpEntryPoint GLCompute %1 "main"
        0x00060010, 1, 17, 1, 1, 1,                     // OpExecutionMode %1 LocalSize 1 1 1
        0x00020013, 2,                                  // %2 = OpTypeVoid
        0x00030021, 3, 2,                               // %3 = OpTypeFunction %2
        0x00050036, 2, 1, 0, 3,                         // %1 = OpFunction %2 None %3
        0x000200F8, 4,                                  // %4 = OpLabel
        0x000100FD,                                     // OpReturn
        0x00010038,                                     // OpFunctionEnd
    };
    const size_t savedSize = 4u << 20;
    uint8_t* saved = calloc(1, savedSize);
    if (!saved) fail("calloc", VK_ERROR_OUT_OF_HOST_MEMORY);
    const uint32_t savedHeader[4] = {32, VK_PIPELINE_CACHE_HEADER_VERSION_ONE, props->vendorID ^ 0xFFFFu, props->deviceID};
    memcpy(saved, savedHeader, sizeof(savedHeader));
    VkPipelineCacheCreateInfo cacheInfo = {VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO};
    cacheInfo.initialDataSize = savedSize;
    cacheInfo.pInitialData = saved;
    VkPipelineCache cache;
    const uint64_t createStart = nowUs();
    CHECK(vkCreatePipelineCache(device, &cacheInfo, NULL, &cache));
    const uint64_t createUs = nowUs() - createStart;
    free(saved);

    VkShaderModuleCreateInfo moduleInfo = {VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};
    moduleInfo.codeSize = sizeof(spirv);
    moduleInfo.pCode = spirv;
    VkShaderModule module;
    CHECK(vkCreateShaderModule(device, &moduleInfo, NULL, &module));
    VkPipelineLayoutCreateInfo layoutInfo = {VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
    VkPipelineLayout layout;
    CHECK(vkCreatePipelineLayout(device, &layoutInfo, NULL, &layout));
    VkComputePipelineCreateInfo pipelineInfo = {VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};
    pipelineInfo.stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    pipelineInfo.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT;
    pipelineInfo.stage.module = module;
    pipelineInfo.stage.pName = "main";
    pipelineInfo.layout = layout;
    VkPipeline pipeline;
    CHECK(vkCreateComputePipelines(device, cache, 1, &pipelineInfo, NULL, &pipeline));

    const int reads = 200;
    uint64_t readUs = 0, readMax = 0;
    size_t size = 0;
    uint8_t data[64];
    int headerOk = 1;
    for (int i = 0; i < reads; ++i) {
        const uint64_t t0 = nowUs();
        size = 0;
        CHECK(vkGetPipelineCacheData(device, cache, &size, NULL));
        size_t filled = sizeof(data);
        const VkResult got = vkGetPipelineCacheData(device, cache, &filled, data);
        const uint64_t d = nowUs() - t0;
        readUs += d;
        if (d > readMax) readMax = d;
        if (size != 32 || got != VK_SUCCESS || filled != 32) { headerOk = 0; continue; }
        uint32_t fields[4];
        memcpy(fields, data, sizeof(fields));
        if (fields[0] != 32 || fields[1] != VK_PIPELINE_CACHE_HEADER_VERSION_ONE || fields[2] != props->vendorID ||
            fields[3] != props->deviceID || memcmp(data + 16, props->pipelineCacheUUID, VK_UUID_SIZE))
            headerOk = 0;
    }
    // A buffer smaller than the header gets nothing.
    size_t small = 16;
    const VkResult incomplete = vkGetPipelineCacheData(device, cache, &small, data);
    vkDestroyPipeline(device, pipeline, NULL);
    vkDestroyPipelineLayout(device, layout, NULL);
    vkDestroyShaderModule(device, module, NULL);
    vkDestroyPipelineCache(device, cache, NULL);
    const double mean = (double)readUs / reads;
    report("pipeline_cache", headerOk && incomplete == VK_INCOMPLETE && small == 0 && mean < 1000.0,
           "size=%zu header=%s small=%d/%zu create_with_4mib_us=%llu reads=%d mean_us=%.1f max_us=%llu", size,
           headerOk ? "device" : "other", incomplete, small, (unsigned long long)createUs, reads, mean,
           (unsigned long long)readMax);
}

// The exit_latency child: what a launcher's splash does (Steam's update window): an instance,
// a device, an X11 window with a surface whose capabilities it asks (which starts the bind)
// and a swapchain; then it says so on `fd`, destroys its window, presents one more frame and
// ends, in `mode` 0 without destroying
// anything, in mode 1 after destroying everything.
struct AllocationProbe { atomic_size_t blocks, bytes, late; atomic_int alive; };
struct AllocationHeader { void* base; size_t size; };
static struct AllocationProbe allocationProbes[32];
static struct AllocationProbe* allocationProbe;
static void* VKAPI_PTR trackedAllocate(void* opaque, size_t size, size_t alignment, VkSystemAllocationScope scope) {
    (void)scope;
    struct AllocationProbe* probe=opaque;
    if (!atomic_load(&probe->alive)) atomic_fetch_add(&probe->late,1);
    if (!size) return NULL;
    if (alignment<sizeof(void*)) alignment=sizeof(void*);
    void* base=malloc(size+alignment+sizeof(struct AllocationHeader));
    if (!base) return NULL;
    uintptr_t address=((uintptr_t)base+sizeof(struct AllocationHeader)+alignment-1)&~(uintptr_t)(alignment-1);
    struct AllocationHeader* header=(struct AllocationHeader*)address-1;
    header->base=base; header->size=size;
    atomic_fetch_add(&probe->blocks,1); atomic_fetch_add(&probe->bytes,size);
    return (void*)address;
}
static void VKAPI_PTR trackedFree(void* opaque, void* memory) {
    struct AllocationProbe* probe=opaque;
    if (!atomic_load(&probe->alive)) atomic_fetch_add(&probe->late,1);
    if (!memory) return;
    struct AllocationHeader* header=(struct AllocationHeader*)memory-1;
    atomic_fetch_sub(&probe->blocks,1); atomic_fetch_sub(&probe->bytes,header->size);
    free(header->base);
}
static void* VKAPI_PTR trackedReallocate(void* opaque, void* original, size_t size, size_t alignment, VkSystemAllocationScope scope) {
    if (!original) return trackedAllocate(opaque,size,alignment,scope);
    if (!size) { trackedFree(opaque,original); return NULL; }
    void* replacement=trackedAllocate(opaque,size,alignment,scope);
    if (!replacement) return NULL;
    size_t old=((struct AllocationHeader*)original-1)->size;
    memcpy(replacement,original,old<size ? old : size);
    trackedFree(opaque,original);
    return replacement;
}

static int exitChild(int mode, int fd) {
    VkAllocationCallbacks callbacks={0};
    const VkAllocationCallbacks* allocator=NULL;
    if (mode==2) {
        atomic_store(&allocationProbe->alive,1);
        callbacks.pUserData=allocationProbe;
        callbacks.pfnAllocation=trackedAllocate;
        callbacks.pfnReallocation=trackedReallocate;
        callbacks.pfnFree=trackedFree;
        allocator=&callbacks;
    }
    const char* extensions[] = {VK_KHR_SURFACE_EXTENSION_NAME, VK_KHR_XCB_SURFACE_EXTENSION_NAME};
    VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO};
    app.pApplicationName = "caboose-sync-check-exit";
    app.apiVersion = VK_API_VERSION_1_3;
    VkInstanceCreateInfo instanceInfo = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    instanceInfo.pApplicationInfo = &app;
    instanceInfo.enabledExtensionCount = 2;
    instanceInfo.ppEnabledExtensionNames = extensions;
    VkInstance childInstance;
    if (vkCreateInstance(&instanceInfo, allocator, &childInstance) != VK_SUCCESS) return 3;
    uint32_t count = 1;
    VkPhysicalDevice childPhysical;
    VkResult enumerated = vkEnumeratePhysicalDevices(childInstance, &count, &childPhysical);
    if ((enumerated != VK_SUCCESS && enumerated != VK_INCOMPLETE) || !count) return 3;
    const float priority = 1.0f;
    VkDeviceQueueCreateInfo queueInfo = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
    queueInfo.queueFamilyIndex = 0;
    queueInfo.queueCount = 1;
    queueInfo.pQueuePriorities = &priority;
    const char* swapchainExtension = VK_KHR_SWAPCHAIN_EXTENSION_NAME;
    VkDeviceCreateInfo deviceInfo = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
    deviceInfo.queueCreateInfoCount = 1;
    deviceInfo.pQueueCreateInfos = &queueInfo;
    deviceInfo.enabledExtensionCount = 1;
    deviceInfo.ppEnabledExtensionNames = &swapchainExtension;
    VkDevice childDevice;
    if (vkCreateDevice(childPhysical, &deviceInfo, allocator, &childDevice) != VK_SUCCESS) return 3;
    xcb_connection_t* connection = xcb_connect(NULL, NULL);
    if (xcb_connection_has_error(connection)) return 3;
    xcb_screen_t* screen = xcb_setup_roots_iterator(xcb_get_setup(connection)).data;
    xcb_window_t window = xcb_generate_id(connection);
    xcb_create_window(connection, XCB_COPY_FROM_PARENT, window, screen->root, 0, 0, 320, 240, 0,
                      XCB_WINDOW_CLASS_INPUT_OUTPUT, screen->root_visual, 0, NULL);
    xcb_map_window(connection, window);
    xcb_flush(connection);
    VkXcbSurfaceCreateInfoKHR surfaceInfo = {VK_STRUCTURE_TYPE_XCB_SURFACE_CREATE_INFO_KHR};
    surfaceInfo.connection = connection;
    surfaceInfo.window = window;
    VkSurfaceKHR surface;
    if (vkCreateXcbSurfaceKHR(childInstance, &surfaceInfo, allocator, &surface) != VK_SUCCESS) return 3;
    VkSurfaceCapabilitiesKHR caps;
    if (vkGetPhysicalDeviceSurfaceCapabilitiesKHR(childPhysical, surface, &caps) != VK_SUCCESS) return 3;
    VkSurfaceFormatKHR format;
    count = 1;
    VkResult listed = vkGetPhysicalDeviceSurfaceFormatsKHR(childPhysical, surface, &count, &format);
    if ((listed != VK_SUCCESS && listed != VK_INCOMPLETE) || !count) return 3;
    VkSwapchainCreateInfoKHR swapInfo = {VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR};
    swapInfo.surface = surface;
    swapInfo.minImageCount = caps.minImageCount;
    swapInfo.imageFormat = format.format;
    swapInfo.imageColorSpace = format.colorSpace;
    swapInfo.imageExtent = caps.currentExtent.width != UINT32_MAX ? caps.currentExtent : (VkExtent2D){320, 240};
    swapInfo.imageArrayLayers = 1;
    swapInfo.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    swapInfo.preTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
    swapInfo.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    swapInfo.presentMode = VK_PRESENT_MODE_FIFO_KHR;
    swapInfo.clipped = VK_TRUE;
    VkSwapchainKHR swapchain;
    if (vkCreateSwapchainKHR(childDevice, &swapInfo, allocator, &swapchain) != VK_SUCCESS) return 3;
    // Shutdown: the window goes first, as a toolkit's does, and one more frame is presented
    // to it (Steam's update window does), with its bind refused or still in flight.
    const char done = 1;
    if (fd>=0 && write(fd, &done, 1) != 1) return 3;
    xcb_destroy_window(connection, window);
    xcb_flush(connection);
    VkSemaphoreCreateInfo semaphoreInfo = {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
    VkSemaphore acquired;
    if (vkCreateSemaphore(childDevice, &semaphoreInfo, allocator, &acquired) != VK_SUCCESS) return 3;
    uint32_t index = 0;
    const VkResult got = vkAcquireNextImageKHR(childDevice, swapchain, 1000000000ull, acquired, VK_NULL_HANDLE, &index);
    if (got == VK_SUCCESS || got == VK_SUBOPTIMAL_KHR) {
        VkQueue childQueue;
        vkGetDeviceQueue(childDevice, 0, 0, &childQueue);
        VkPresentInfoKHR present = {VK_STRUCTURE_TYPE_PRESENT_INFO_KHR};
        present.waitSemaphoreCount = 1;
        present.pWaitSemaphores = &acquired;
        present.swapchainCount = 1;
        present.pSwapchains = &swapchain;
        present.pImageIndices = &index;
        vkQueuePresentKHR(childQueue, &present);
    }
    if (mode != 0) {
        vkDeviceWaitIdle(childDevice);
        vkDestroySemaphore(childDevice, acquired, allocator);
        vkDestroySwapchainKHR(childDevice, swapchain, allocator);
        vkDestroySurfaceKHR(childInstance, surface, allocator);
        vkDestroyDevice(childDevice, allocator);
        vkDestroyInstance(childInstance, allocator);
        xcb_disconnect(connection);
    }
    if (mode==2) {
        atomic_store(&allocationProbe->alive,0);
        if (atomic_load(&allocationProbe->blocks) || atomic_load(&allocationProbe->bytes)) {
            printf("CABOOSE_SYNC_CHECK allocator outstanding blocks=%zu bytes=%zu\n",
                   atomic_load(&allocationProbe->blocks),atomic_load(&allocationProbe->bytes));
            return 5;
        }
    }
    return 0;
}

// Exit latency: from a child's shutdown (exitChild above) to its end. A process's end never
// waits for the phone, so a launcher that starts again at once never finds it still running.
static void exitLatencyCase(void) {
    if (!surfaces) {
        printf("CABOOSE_SYNC_CHECK note=exit_latency skipped (no X11 display)\n");
        return;
    }
    double worst[2]={0,0}, worstSetup[2]={0,0};
    int failedChildren=0;
    int ok = 1;
    for (int round = 0; round < 32; ++round) {
        const int mode=round%2;
        int pipefd[2];
        if (pipe(pipefd) != 0) fail("pipe", VK_ERROR_INITIALIZATION_FAILED);
        fflush(stdout);
        const uint64_t started = nowUs();
        const pid_t child = fork();
        if (child < 0) fail("fork", VK_ERROR_INITIALIZATION_FAILED);
        if (child == 0) {
            close(pipefd[0]);
            char modeArg[8], fdArg[16];
            snprintf(modeArg, sizeof(modeArg), "%d", mode);
            snprintf(fdArg, sizeof(fdArg), "%d", pipefd[1]);
            execl("/proc/self/exe", "sync_check", "--exit-child", modeArg, fdArg, (char*)NULL);
            _exit(4);
        }
        close(pipefd[1]);
        struct pollfd ready = {pipefd[0], POLLIN, 0};
        char byte = 0;
        const int signalled = poll(&ready, 1, 30000) == 1 && read(pipefd[0], &byte, 1) == 1;
        const uint64_t shutdown = nowUs();
        const double setupMs = (double)(shutdown - started) / 1000.0;
        int status = 0;
        waitpid(child, &status, 0);
        const double ms = (double)(nowUs() - shutdown) / 1000.0;
        close(pipefd[0]);
        if (!WIFEXITED(status) || WEXITSTATUS(status))
            printf("CABOOSE_SYNC_CHECK exit_child mode=%d wait_status=%d signal=%d\n",mode,status,WIFSIGNALED(status) ? WTERMSIG(status) : 0);
        const int clean = signalled && WIFEXITED(status) && WEXITSTATUS(status) == 0;
        if (!clean || ms >= 50.0) ok = 0;
        if (!clean) ++failedChildren;
        if (ms>worst[mode]) worst[mode]=ms;
        if (setupMs>worstSetup[mode]) worstSetup[mode]=setupMs;
    }
    report("exit_latency",ok,"cycles=32 abandoned_ms=%.1f destroyed_ms=%.1f setup_ms=%.0f/%.0f failed_children=%d",
           worst[0],worst[1],worstSetup[0],worstSetup[1],failedChildren);
}

// The process the abandoned_work case starts: a batch that waits for a timeline value
// nothing will signal, and the process gone at once, so that only the executor's
// teardown can let that work finish.
static void abandonWork(void) {
    begin();
    CHECK(vkEndCommandBuffer(cb));
    VkSemaphoreSubmitInfo waitInfo = {VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO};
    waitInfo.semaphore = timeline;
    waitInfo.value = 1;
    waitInfo.stageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT;
    VkCommandBufferSubmitInfo cbInfo = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO};
    cbInfo.commandBuffer = cb;
    VkSubmitInfo2 submit = {VK_STRUCTURE_TYPE_SUBMIT_INFO_2};
    submit.waitSemaphoreInfoCount = 1;
    submit.pWaitSemaphoreInfos = &waitInfo;
    submit.commandBufferInfoCount = 1;
    submit.pCommandBufferInfos = &cbInfo;
    VkFenceCreateInfo fenceInfo = {VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    VkFence fence;
    CHECK(vkCreateFence(device, &fenceInfo, NULL, &fence));
    CHECK(vkQueueSubmit2(queue, 1, &submit, fence));
    // Time for the batch to reach the executor before the process goes.
    struct timespec pause = {0, 500000000};
    nanosleep(&pause, NULL);
    printf("CABOOSE_SYNC_CHECK abandoned pid=%ld\n", (long)getpid());
    fflush(stdout);
    _exit(0);
}

// Starts this program again to abandon a waiting batch (abandonWork), and waits for it.
static void abandonedWorkCase(void) {
    const uint64_t start = nowUs();
    const pid_t child = fork();
    if (child == 0) {
        execl("/proc/self/exe", "sync_check", "--abandon", (char*)NULL);
        _exit(127);
    }
    int status = 0;
    int exited = 0;
    while (child > 0 && nowUs() - start < 20000000u) {
        const pid_t done = waitpid(child, &status, WNOHANG);
        if (done == child) { exited = 1; break; }
        struct timespec pause = {0, 20000000};
        nanosleep(&pause, NULL);
    }
    report("abandoned_work", exited && WIFEXITED(status) && WEXITSTATUS(status) == 0,
           "exited=%d status=%d ms=%.1f (linux-executor/check.sh also requires its retirement)", exited,
           exited ? WEXITSTATUS(status) : -1, (nowUs() - start) / 1000.0);
}

int main(int argc, char** argv) {
    if (argc>1 && !strcmp(argv[1],"--lifetime-child")) {
        for (int i=0;i<32;++i) {
            allocationProbe=&allocationProbes[i];
            int result=exitChild(2,-1);
            if (result) return result;
            struct timespec pause={0,500000000}; nanosleep(&pause,NULL);
            for (int j=0;j<=i;++j)
                if (atomic_load(&allocationProbes[j].late)) return 6;
        }
        printf("CABOOSE_SYNC_CHECK case=allocator_lifetime PASS cycles=32 outstanding=0 late_callbacks=0\n");
        return 0;
    }
    if (argc > 3 && !strcmp(argv[1], "--exit-child")) return exitChild(atoi(argv[2]), atoi(argv[3]));
    if (argc > 3 && !strcmp(argv[1], "--map-window")) return mapWindowChild((xcb_window_t)strtoul(argv[2], NULL, 10), atoi(argv[3]));
    const int abandon = argc > 1 && !strcmp(argv[1], "--abandon");
    const char* only = argc > 1 && !abandon ? argv[1] : NULL;
    VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO};
    app.pApplicationName = "caboose-sync-check";
    app.apiVersion = VK_API_VERSION_1_3;
    VkInstanceCreateInfo instanceInfo = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    instanceInfo.pApplicationInfo = &app;
    // Surfaces need an X11 display and the driver's XCB surfaces.
    const char* surfaceExtensions[] = {VK_KHR_SURFACE_EXTENSION_NAME, VK_KHR_XCB_SURFACE_EXTENSION_NAME,
                                       VK_KHR_GET_SURFACE_CAPABILITIES_2_EXTENSION_NAME};
    if (getenv("DISPLAY")) {
        uint32_t available = 0;
        vkEnumerateInstanceExtensionProperties(NULL, &available, NULL);
        VkExtensionProperties properties[256];
        if (available > 256) available = 256;
        vkEnumerateInstanceExtensionProperties(NULL, &available, properties);
        int found[3] = {0, 0, 0};
        for (uint32_t i = 0; i < available; ++i)
            for (int k = 0; k < 3; ++k)
                if (!strcmp(properties[i].extensionName, surfaceExtensions[k])) found[k] = 1;
        // Surfaces and XCB are required; the Formats2 query runs when it is offered.
        if (found[0] && found[1]) {
            instanceInfo.enabledExtensionCount = found[2] ? 3 : 2;
            instanceInfo.ppEnabledExtensionNames = surfaceExtensions;
            surfaces = 1;
            surfaces2 = found[2];
        }
    }
    CHECK(vkCreateInstance(&instanceInfo, NULL, &instance));
    uint32_t count = 1;
    VkResult enumerated = vkEnumeratePhysicalDevices(instance, &count, &physical);
    if ((enumerated != VK_SUCCESS && enumerated != VK_INCOMPLETE) || !count) fail("vkEnumeratePhysicalDevices", enumerated);
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(physical, &props);
    uint32_t families = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(physical, &families, NULL);
    VkQueueFamilyProperties familyProps[16];
    if (families > 16) families = 16;
    vkGetPhysicalDeviceQueueFamilyProperties(physical, &families, familyProps);
    family = UINT32_MAX;
    for (uint32_t i = 0; i < families && family == UINT32_MAX; ++i)
        if (familyProps[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) family = i;
    if (family == UINT32_MAX) fail("graphics queue family", VK_ERROR_FEATURE_NOT_PRESENT);

    VkPhysicalDeviceVulkan13Features features13 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES};
    features13.synchronization2 = VK_TRUE;
    VkPhysicalDeviceVulkan12Features features12 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES};
    features12.pNext = &features13;
    features12.timelineSemaphore = VK_TRUE;
    features12.hostQueryReset = VK_TRUE;
    const float priority = 1.0f;
    VkDeviceQueueCreateInfo queueInfo = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
    queueInfo.queueFamilyIndex = family;
    queueInfo.queueCount = 1;
    queueInfo.pQueuePriorities = &priority;
    VkDeviceCreateInfo deviceInfo = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
    deviceInfo.pNext = &features12;
    deviceInfo.queueCreateInfoCount = 1;
    deviceInfo.pQueueCreateInfos = &queueInfo;
    // Swapchains for the child window case, on a device whose instance has surfaces.
    const char* swapchainExtension = VK_KHR_SWAPCHAIN_EXTENSION_NAME;
    if (surfaces) {
        deviceInfo.enabledExtensionCount = 1;
        deviceInfo.ppEnabledExtensionNames = &swapchainExtension;
    }
    CHECK(vkCreateDevice(physical, &deviceInfo, NULL, &device));
    vkGetDeviceQueue(device, family, 0, &queue);
    printf("CABOOSE_SYNC_CHECK device=\"%s\" api=%u.%u\n", props.deviceName, VK_API_VERSION_MAJOR(props.apiVersion),
           VK_API_VERSION_MINOR(props.apiVersion));

    VkCommandPoolCreateInfo poolInfo = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
    poolInfo.queueFamilyIndex = family;
    CHECK(vkCreateCommandPool(device, &poolInfo, NULL, &commandPool));
    VkCommandBufferAllocateInfo cbInfo = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
    cbInfo.commandPool = commandPool;
    cbInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cbInfo.commandBufferCount = 1;
    CHECK(vkAllocateCommandBuffers(device, &cbInfo, &cb));
    VkSemaphoreTypeCreateInfo typeInfo = {VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO};
    typeInfo.semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE;
    VkSemaphoreCreateInfo semaphoreInfo = {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
    semaphoreInfo.pNext = &typeInfo;
    CHECK(vkCreateSemaphore(device, &semaphoreInfo, NULL, &timeline));

    if (abandon) abandonWork();
#define RUN(name, call) if (!only || strstr(name, only)) call
    RUN("event_set2_timeline", eventCase(0));
    RUN("event_set2_unsignalled", eventCase(1));
    RUN("event_set1_fence", eventCase(2));
    RUN("query_timestamp", queryCase(VK_QUERY_TYPE_TIMESTAMP));
    RUN("query_occlusion", queryCase(VK_QUERY_TYPE_OCCLUSION));
    RUN("surface_enumeration", surfaceCase());
    RUN("free_after_wait", freeCase());
    RUN("completion_after_gpu", completionCase());
    RUN("pool_capacity", poolCapacityCase());
    RUN("unwritten_sets", unwrittenSetsCase());
    RUN("calls", callsCase());
    RUN("pipeline_cache", pipelineCacheCase(&props));
    RUN("child_windows", childWindowsCase());
    RUN("one_shot", oneShotCase());
    RUN("coherent_rewrite", coherentRewriteCase());
    RUN("exit_latency", exitLatencyCase());
    RUN("abandoned_work", abandonedWorkCase());
    // Needs a compositor that maps windows (a running computer), so only when named.
    if (only && !strcmp(only, "unmapped_popup")) unmappedPopupCase();

    CHECK(vkDeviceWaitIdle(device));
    vkDestroySemaphore(device, timeline, NULL);
    vkDestroyCommandPool(device, commandPool, NULL);
    vkDestroyDevice(device, NULL);
    vkDestroyInstance(instance, NULL);
    printf("CABOOSE_SYNC_CHECK done failures=%d\n", failures);
    return failures ? 1 : 0;
}
