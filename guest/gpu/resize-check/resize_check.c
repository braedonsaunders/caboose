// SPDX-License-Identifier: Apache-2.0
// A Vulkan X11 window whose swapchain either keeps its first extent (as a full-screen game
// that renders at its own resolution) or follows the window, drawn as a picture whose
// placement on the phone shows at a glance: four coloured quadrants, a white border and a
// bar that moves so presents keep arriving. See README.md.
#define VK_USE_PLATFORM_XCB_KHR
#include <vulkan/vulkan.h>
#include <xcb/xcb.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define CHECK(call) do { VkResult r_ = (call); if (r_ != VK_SUCCESS) { \
    fprintf(stderr, "resize-check: %s failed: %d\n", #call, r_); exit(1); } } while (0)

static struct {
    bool follow, child, fullscreen;
    uint32_t width, height;
    double seconds;
    // --child-size: the child window becomes this size this many seconds in.
    uint32_t childWidth, childHeight;
    double childAt;
} options = {false, false, false, 800, 600, 60, 0, 0, 0};

static xcb_connection_t* xcb;
static xcb_window_t toplevel, child;
static uint32_t windowWidth, windowHeight;
static VkInstance instance;
static VkPhysicalDevice physical;
static VkDevice device;
static VkQueue queue;
static uint32_t family;
static VkSurfaceKHR surface;
static VkSwapchainKHR swapchain;
static VkExtent2D extent;
static VkFormat format;
static uint32_t imageCount;
static VkImage images[8];
static VkBuffer pattern;
static VkDeviceMemory patternMemory;
static VkDeviceSize patternSize;
static VkCommandPool pool;
static VkCommandBuffer commands;
static VkSemaphore acquired, rendered;
static VkFence done;

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static xcb_atom_t atom(const char* name) {
    xcb_intern_atom_reply_t* reply =
        xcb_intern_atom_reply(xcb, xcb_intern_atom(xcb, 0, (uint16_t)strlen(name), name), NULL);
    xcb_atom_t value = reply ? reply->atom : XCB_ATOM_NONE;
    free(reply);
    return value;
}

static void openWindow(void) {
    xcb = xcb_connect(NULL, NULL);
    if (xcb_connection_has_error(xcb)) { fprintf(stderr, "resize-check: no X display\n"); exit(1); }
    xcb_screen_t* screen = xcb_setup_roots_iterator(xcb_get_setup(xcb)).data;
    uint32_t values[] = {screen->black_pixel, XCB_EVENT_MASK_STRUCTURE_NOTIFY};
    toplevel = xcb_generate_id(xcb);
    xcb_create_window(xcb, XCB_COPY_FROM_PARENT, toplevel, screen->root, 0, 0, options.width, options.height,
                      0, XCB_WINDOW_CLASS_INPUT_OUTPUT, screen->root_visual, XCB_CW_BACK_PIXEL | XCB_CW_EVENT_MASK, values);
    const char* title = "Caboose resize check";
    xcb_change_property(xcb, XCB_PROP_MODE_REPLACE, toplevel, XCB_ATOM_WM_NAME, XCB_ATOM_STRING, 8,
                        (uint32_t)strlen(title), title);
    if (options.fullscreen) {
        xcb_atom_t state = atom("_NET_WM_STATE_FULLSCREEN");
        xcb_change_property(xcb, XCB_PROP_MODE_REPLACE, toplevel, atom("_NET_WM_STATE"), XCB_ATOM_ATOM, 32, 1, &state);
    }
    if (options.child) {
        // Wine draws a Win32 window's client area into a child window of this size.
        child = xcb_generate_id(xcb);
        uint32_t white[] = {screen->white_pixel};
        xcb_create_window(xcb, XCB_COPY_FROM_PARENT, child, toplevel, 0, 0, options.width, options.height,
                          0, XCB_WINDOW_CLASS_INPUT_OUTPUT, screen->root_visual, XCB_CW_BACK_PIXEL, white);
        xcb_map_window(xcb, child);
    }
    xcb_map_window(xcb, toplevel);
    xcb_flush(xcb);
    windowWidth = options.width; windowHeight = options.height;
}

static void openDevice(void) {
    const char* instanceExtensions[] = {VK_KHR_SURFACE_EXTENSION_NAME, VK_KHR_XCB_SURFACE_EXTENSION_NAME};
    VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL, "caboose-resize-check", 1, NULL, 0, VK_API_VERSION_1_1};
    VkInstanceCreateInfo info = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, NULL, 0, &app, 0, NULL, 2, instanceExtensions};
    CHECK(vkCreateInstance(&info, NULL, &instance));
    VkXcbSurfaceCreateInfoKHR surfaceInfo = {VK_STRUCTURE_TYPE_XCB_SURFACE_CREATE_INFO_KHR, NULL, 0, xcb,
                                             options.child ? child : toplevel};
    CHECK(vkCreateXcbSurfaceKHR(instance, &surfaceInfo, NULL, &surface));
    uint32_t count = 1;
    VkResult listed = vkEnumeratePhysicalDevices(instance, &count, &physical);
    if ((listed != VK_SUCCESS && listed != VK_INCOMPLETE) || !count) { fprintf(stderr, "resize-check: no device\n"); exit(1); }
    VkPhysicalDeviceProperties properties;
    vkGetPhysicalDeviceProperties(physical, &properties);
    printf("device %s\n", properties.deviceName);
    VkQueueFamilyProperties families[16];
    count = 16;
    vkGetPhysicalDeviceQueueFamilyProperties(physical, &count, families);
    family = UINT32_MAX;
    for (uint32_t i = 0; i < count && family == UINT32_MAX; ++i) {
        VkBool32 present = VK_FALSE;
        vkGetPhysicalDeviceSurfaceSupportKHR(physical, i, surface, &present);
        if (present && (families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT)) family = i;
    }
    if (family == UINT32_MAX) { fprintf(stderr, "resize-check: no presenting queue\n"); exit(1); }
    float priority = 1;
    VkDeviceQueueCreateInfo queueInfo = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, NULL, 0, family, 1, &priority};
    const char* deviceExtensions[] = {VK_KHR_SWAPCHAIN_EXTENSION_NAME};
    VkDeviceCreateInfo deviceInfo = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, NULL, 0, 1, &queueInfo, 0, NULL, 1, deviceExtensions, NULL};
    CHECK(vkCreateDevice(physical, &deviceInfo, NULL, &device));
    vkGetDeviceQueue(device, family, 0, &queue);
    VkCommandPoolCreateInfo poolInfo = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, NULL,
                                        VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, family};
    CHECK(vkCreateCommandPool(device, &poolInfo, NULL, &pool));
    VkCommandBufferAllocateInfo allocate = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, pool,
                                            VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1};
    CHECK(vkAllocateCommandBuffers(device, &allocate, &commands));
    VkSemaphoreCreateInfo semaphore = {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO, NULL, 0};
    CHECK(vkCreateSemaphore(device, &semaphore, NULL, &acquired));
    CHECK(vkCreateSemaphore(device, &semaphore, NULL, &rendered));
    VkFenceCreateInfo fence = {VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, NULL, VK_FENCE_CREATE_SIGNALED_BIT};
    CHECK(vkCreateFence(device, &fence, NULL, &done));
}

/// Quadrants red, green, blue and yellow, inside a white border 1/40 of the picture wide.
static void writePattern(uint8_t* pixels, bool bgra) {
    uint32_t border = (extent.width < extent.height ? extent.width : extent.height) / 40 + 1;
    for (uint32_t y = 0; y < extent.height; ++y) {
        for (uint32_t x = 0; x < extent.width; ++x) {
            uint8_t r, g, b;
            if (x < border || y < border || x >= extent.width - border || y >= extent.height - border) {
                r = g = b = 255;
            } else {
                bool right = x >= extent.width / 2, bottom = y >= extent.height / 2;
                r = (!right && !bottom) || (right && bottom) ? 220 : 0;
                g = (right && !bottom) || (right && bottom) ? 200 : 0;
                b = (!right && bottom) ? 230 : 0;
            }
            uint8_t* p = pixels + 4 * ((size_t)y * extent.width + x);
            p[0] = bgra ? b : r; p[1] = g; p[2] = bgra ? r : b; p[3] = 255;
        }
    }
}

static void destroyPattern(void) {
    if (device) vkDeviceWaitIdle(device);
    if (pattern) vkDestroyBuffer(device, pattern, NULL);
    if (patternMemory) { vkUnmapMemory(device, patternMemory); vkFreeMemory(device, patternMemory, NULL); }
    pattern = VK_NULL_HANDLE; patternMemory = VK_NULL_HANDLE;
}

static void makePattern(void) {
    destroyPattern();
    patternSize = (VkDeviceSize)extent.width * extent.height * 4;
    VkBufferCreateInfo info = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, NULL, 0, patternSize,
                               VK_BUFFER_USAGE_TRANSFER_SRC_BIT, VK_SHARING_MODE_EXCLUSIVE, 0, NULL};
    CHECK(vkCreateBuffer(device, &info, NULL, &pattern));
    VkMemoryRequirements requirements;
    vkGetBufferMemoryRequirements(device, pattern, &requirements);
    VkPhysicalDeviceMemoryProperties memory;
    vkGetPhysicalDeviceMemoryProperties(physical, &memory);
    uint32_t type = 0;
    const VkMemoryPropertyFlags wanted = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    while (type < memory.memoryTypeCount &&
           (!(requirements.memoryTypeBits & (1u << type)) || (memory.memoryTypes[type].propertyFlags & wanted) != wanted)) ++type;
    if (type == memory.memoryTypeCount) { fprintf(stderr, "resize-check: no host-visible memory\n"); exit(1); }
    VkMemoryAllocateInfo allocate = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, NULL, requirements.size, type};
    CHECK(vkAllocateMemory(device, &allocate, NULL, &patternMemory));
    CHECK(vkBindBufferMemory(device, pattern, patternMemory, 0));
    void* mapped;
    CHECK(vkMapMemory(device, patternMemory, 0, patternSize, 0, &mapped));
    // Stays mapped until the buffer goes: a remote driver may carry mapped memory's
    // contents to the GPU only at submission.
    writePattern(mapped, format == VK_FORMAT_B8G8R8A8_UNORM || format == VK_FORMAT_B8G8R8A8_SRGB);
    VkMappedMemoryRange range = {VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE, NULL, patternMemory, 0, VK_WHOLE_SIZE};
    CHECK(vkFlushMappedMemoryRanges(device, 1, &range));
}

static void createSwapchain(void) {
    VkSurfaceCapabilitiesKHR caps;
    CHECK(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical, surface, &caps));
    // The surface's own extent when it has one (its X11 window's size), else the window's
    // size when following it, else the size the program was started with.
    VkExtent2D wanted = options.follow ? (VkExtent2D){windowWidth, windowHeight} : (VkExtent2D){options.width, options.height};
    if (caps.currentExtent.width != UINT32_MAX) wanted = caps.currentExtent;
    if (wanted.width < caps.minImageExtent.width) wanted.width = caps.minImageExtent.width;
    if (wanted.height < caps.minImageExtent.height) wanted.height = caps.minImageExtent.height;
    if (wanted.width > caps.maxImageExtent.width) wanted.width = caps.maxImageExtent.width;
    if (wanted.height > caps.maxImageExtent.height) wanted.height = caps.maxImageExtent.height;
    VkSurfaceFormatKHR formats[64];
    uint32_t count = 64;
    VkResult listed = vkGetPhysicalDeviceSurfaceFormatsKHR(physical, surface, &count, formats);
    if ((listed != VK_SUCCESS && listed != VK_INCOMPLETE) || !count) { fprintf(stderr, "resize-check: no surface formats\n"); exit(1); }
    VkSurfaceFormatKHR chosen = formats[0];
    for (uint32_t i = 0; i < count; ++i)
        if (formats[i].format == VK_FORMAT_B8G8R8A8_UNORM || formats[i].format == VK_FORMAT_R8G8B8A8_UNORM) { chosen = formats[i]; break; }
    uint32_t minimum = caps.minImageCount + 1;
    if (caps.maxImageCount && minimum > caps.maxImageCount) minimum = caps.maxImageCount;
    VkSwapchainKHR old = swapchain;
    VkSwapchainCreateInfoKHR info = {VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR, NULL, 0, surface, minimum,
        chosen.format, chosen.colorSpace, wanted, 1, VK_IMAGE_USAGE_TRANSFER_DST_BIT, VK_SHARING_MODE_EXCLUSIVE,
        0, NULL, caps.currentTransform, VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR, VK_PRESENT_MODE_FIFO_KHR, VK_TRUE, old};
    CHECK(vkCreateSwapchainKHR(device, &info, NULL, &swapchain));
    if (old) vkDestroySwapchainKHR(device, old, NULL);
    extent = wanted; format = chosen.format;
    imageCount = 8;
    CHECK(vkGetSwapchainImagesKHR(device, swapchain, &imageCount, images));
    makePattern();
    printf("swapchain %ux%u in window %ux%u (current extent %ux%u, %ux%u to %ux%u)\n", extent.width, extent.height,
           windowWidth, windowHeight, caps.currentExtent.width, caps.currentExtent.height, caps.minImageExtent.width,
           caps.minImageExtent.height, caps.maxImageExtent.width, caps.maxImageExtent.height);
    fflush(stdout);
}

static void barrier(VkImage image, VkImageLayout from, VkImageLayout to, VkAccessFlags srcAccess, VkAccessFlags dstAccess) {
    VkImageMemoryBarrier b = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL, srcAccess, dstAccess, from, to,
        VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, image, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
    vkCmdPipelineBarrier(commands, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
                         0, 0, NULL, 0, NULL, 1, &b);
}

/// One frame: the pattern, with a black bar at a position that moves each frame.
static VkResult drawFrame(uint64_t frame) {
    CHECK(vkWaitForFences(device, 1, &done, VK_TRUE, UINT64_MAX));
    uint32_t index;
    VkResult result = vkAcquireNextImageKHR(device, swapchain, UINT64_MAX, acquired, VK_NULL_HANDLE, &index);
    if (result != VK_SUCCESS && result != VK_SUBOPTIMAL_KHR) return result;
    CHECK(vkResetFences(device, 1, &done));
    CHECK(vkResetCommandBuffer(commands, 0));
    VkCommandBufferBeginInfo begin = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, NULL,
                                      VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, NULL};
    CHECK(vkBeginCommandBuffer(commands, &begin));
    barrier(images[index], VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 0, VK_ACCESS_TRANSFER_WRITE_BIT);
    VkBufferImageCopy whole = {0, 0, 0, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {0, 0, 0}, {extent.width, extent.height, 1}};
    vkCmdCopyBufferToImage(commands, pattern, images[index], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &whole);
    // The moving bar: a column of the pattern's first row of pixels (white border) copied
    // across, 1/40 of the width wide.
    uint32_t bar = extent.width / 40 + 1;
    uint32_t x = (uint32_t)((frame * 4) % (extent.width - bar));
    VkBufferImageCopy column = {0, extent.width, 0, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
                                {(int32_t)x, (int32_t)(extent.height / 3), 0}, {bar, extent.height / 3, 1}};
    vkCmdCopyBufferToImage(commands, pattern, images[index], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &column);
    barrier(images[index], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, VK_ACCESS_TRANSFER_WRITE_BIT, 0);
    CHECK(vkEndCommandBuffer(commands));
    VkPipelineStageFlags stage = VK_PIPELINE_STAGE_TRANSFER_BIT;
    VkSubmitInfo submit = {VK_STRUCTURE_TYPE_SUBMIT_INFO, NULL, 1, &acquired, &stage, 1, &commands, 1, &rendered};
    CHECK(vkQueueSubmit(queue, 1, &submit, done));
    VkPresentInfoKHR present = {VK_STRUCTURE_TYPE_PRESENT_INFO_KHR, NULL, 1, &rendered, 1, &swapchain, &index, NULL};
    return vkQueuePresentKHR(queue, &present);
}

static void readEvents(bool* resized) {
    xcb_generic_event_t* event;
    while ((event = xcb_poll_for_event(xcb))) {
        if ((event->response_type & 0x7f) == XCB_CONFIGURE_NOTIFY) {
            xcb_configure_notify_event_t* configure = (xcb_configure_notify_event_t*)event;
            if (configure->window == toplevel &&
                (configure->width != windowWidth || configure->height != windowHeight)) {
                windowWidth = configure->width; windowHeight = configure->height;
                printf("window %ux%u\n", windowWidth, windowHeight);
                fflush(stdout);
                *resized = true;
            }
        }
        free(event);
    }
}

int main(int argc, char** argv) {
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--follow")) options.follow = true;
        else if (!strcmp(argv[i], "--child")) options.child = true;
        else if (!strcmp(argv[i], "--fullscreen")) options.fullscreen = true;
        else if (!strcmp(argv[i], "--size") && i + 1 < argc &&
                 sscanf(argv[++i], "%ux%u", &options.width, &options.height) == 2 && options.width && options.height) {}
        else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) options.seconds = atof(argv[++i]);
        else if (!strcmp(argv[i], "--child-size") && i + 1 < argc &&
                 sscanf(argv[++i], "%ux%u@%lf", &options.childWidth, &options.childHeight, &options.childAt) == 3 &&
                 options.childWidth && options.childHeight) options.child = true;
        else {
            fprintf(stderr, "usage: resize-check [--follow] [--child] [--fullscreen] [--size WxH] [--child-size WxH@S] [--seconds S]\n");
            return 2;
        }
    }
    openWindow();
    openDevice();
    createSwapchain();
    const double start = now(), end = start + options.seconds;
    bool childResized = false;
    for (uint64_t frame = 0; now() < end; ++frame) {
        bool resized = false;
        readEvents(&resized);
        if (!childResized && options.childWidth && now() - start >= options.childAt) {
            // The application keeps rendering at its own size inside a window that is now
            // larger (or smaller), as a Wine game does after the display changes.
            childResized = true;
            uint32_t size[] = {options.childWidth, options.childHeight};
            xcb_configure_window(xcb, child, XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT, size);
            xcb_flush(xcb);
            printf("child %ux%u\n", options.childWidth, options.childHeight);
            fflush(stdout);
        }
        if (resized && options.child && !childResized) {
            // Until --child-size, the child window follows its top-level, as a Win32
            // window's client area does.
            uint32_t size[] = {windowWidth, windowHeight};
            xcb_configure_window(xcb, child, XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT, size);
            xcb_flush(xcb);
        }
        if (resized && options.follow) {
            CHECK(vkDeviceWaitIdle(device));
            createSwapchain();
        }
        VkResult result = drawFrame(frame);
        if (result == VK_ERROR_OUT_OF_DATE_KHR || (result == VK_SUBOPTIMAL_KHR && options.follow)) {
            static double lastRecreate;
            if (now() - lastRecreate < 0.1) {
                // A driver that keeps refusing the extent: do not spin.
                struct timespec pause = {0, 100000000};
                nanosleep(&pause, NULL);
            }
            lastRecreate = now();
            printf("present %s: recreating\n", result == VK_SUBOPTIMAL_KHR ? "suboptimal" : "out of date");
            CHECK(vkDeviceWaitIdle(device));
            createSwapchain();
        } else if (result != VK_SUCCESS && result != VK_SUBOPTIMAL_KHR) {
            fprintf(stderr, "resize-check: present failed: %d\n", result);
            return 1;
        }
    }
    vkDeviceWaitIdle(device);
    destroyPattern();
    vkDestroySwapchainKHR(device, swapchain, NULL);
    vkDestroySurfaceKHR(instance, surface, NULL);
    vkDestroyFence(device, done, NULL);
    vkDestroySemaphore(device, acquired, NULL);
    vkDestroySemaphore(device, rendered, NULL);
    vkDestroyCommandPool(device, pool, NULL);
    vkDestroyDevice(device, NULL);
    vkDestroyInstance(instance, NULL);
    xcb_disconnect(xcb);
    return 0;
}
