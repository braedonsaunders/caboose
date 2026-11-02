// SPDX-License-Identifier: MIT
// Synchronization check for the Caboose Vulkan driver against a live phone executor
// (README.md). Each case prints one CABOOSE_SYNC_CHECK line; the exit status is nonzero
// when a case fails.
#define _POSIX_C_SOURCE 200809L
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
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
static int surfaces;  // the instance has VK_KHR_xcb_surface and VK_KHR_get_surface_capabilities2

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
        (PFN_vkGetPhysicalDeviceSurfaceFormats2KHR)vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceSurfaceFormats2KHR");
    int bad = 0, enumerations = 0;
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
            filled = count < 64 ? count : 64;
            VkResult fill = result == VK_SUCCESS ? vkGetPhysicalDeviceSurfaceFormatsKHR(physical, surface, &filled, formats) : result;
            ++enumerations;
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
            if (i < 10) {
                struct timespec pause = {0, 20 * 1000 * 1000};  // span the window's bind
                nanosleep(&pause, NULL);
            }
        }
        vkDestroySurfaceKHR(instance, surface, NULL);
        xcb_destroy_window(connection, window);
        xcb_flush(connection);
    }
    xcb_disconnect(connection);
    report("surface_enumeration", bad == 0, "enumerations=%d inconsistent=%d%s%s", enumerations, bad, bad ? " first: " : "",
           first);
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

int main(int argc, char** argv) {
    const char* only = argc > 1 ? argv[1] : NULL;
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
        int found = 0;
        for (uint32_t i = 0; i < available; ++i)
            for (int k = 0; k < 3; ++k)
                if (!strcmp(properties[i].extensionName, surfaceExtensions[k])) ++found;
        if (found == 3) {
            instanceInfo.enabledExtensionCount = 3;
            instanceInfo.ppEnabledExtensionNames = surfaceExtensions;
            surfaces = 1;
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

#define RUN(name, call) if (!only || strstr(name, only)) call
    RUN("event_set2_timeline", eventCase(0));
    RUN("event_set2_unsignalled", eventCase(1));
    RUN("event_set1_fence", eventCase(2));
    RUN("query_timestamp", queryCase(VK_QUERY_TYPE_TIMESTAMP));
    RUN("query_occlusion", queryCase(VK_QUERY_TYPE_OCCLUSION));
    RUN("surface_enumeration", surfaceCase());
    RUN("free_after_wait", freeCase());
    RUN("completion_after_gpu", completionCase());
    RUN("calls", callsCase());

    CHECK(vkDeviceWaitIdle(device));
    vkDestroySemaphore(device, timeline, NULL);
    vkDestroyCommandPool(device, commandPool, NULL);
    vkDestroyDevice(device, NULL);
    vkDestroyInstance(instance, NULL);
    printf("CABOOSE_SYNC_CHECK done failures=%d\n", failures);
    return failures ? 1 : 0;
}
