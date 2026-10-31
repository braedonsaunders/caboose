// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// Runs on a CPU Vulkan implementation (lavapipe) with the layer enabled; see README.md.
#include <vulkan/vulkan.h>

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <cassert>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>

static VkInstance instance;
static VkPhysicalDevice physical;

struct Device {
    VkDevice device = VK_NULL_HANDLE;
    VkQueue queue = VK_NULL_HANDLE;
    VkFence fence = VK_NULL_HANDLE;
    Device() {
        float priority = 1;
        VkDeviceQueueCreateInfo queueInfo{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
        queueInfo.queueCount = 1; queueInfo.pQueuePriorities = &priority;
        VkDeviceCreateInfo info{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
        info.queueCreateInfoCount = 1; info.pQueueCreateInfos = &queueInfo;
        assert(vkCreateDevice(physical, &info, nullptr, &device) == VK_SUCCESS);
        vkGetDeviceQueue(device, 0, 0, &queue);
        VkFenceCreateInfo fenceInfo{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
        assert(vkCreateFence(device, &fenceInfo, nullptr, &fence) == VK_SUCCESS);
    }
    VkResult frame() {
        vkResetFences(device, 1, &fence);
        VkResult result = vkQueueSubmit(queue, 0, nullptr, fence);
        if (result != VK_SUCCESS) return result;
        return vkWaitForFences(device, 1, &fence, VK_TRUE, UINT64_MAX);
    }
    ~Device() { vkDestroyFence(device, fence, nullptr); vkDestroyDevice(device, nullptr); }
};

int main() {
    const char* path = std::getenv("CABOOSE_GFXSTREAM_SOCKET");
    assert(path && *path);
    unlink(path);
    VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
    app.apiVersion = VK_API_VERSION_1_1;
    VkInstanceCreateInfo info{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    info.pApplicationInfo = &app;
    assert(vkCreateInstance(&info, nullptr, &instance) == VK_SUCCESS);
    uint32_t count = 1;
    assert(vkEnumeratePhysicalDevices(instance, &count, &physical) >= 0 && count == 1);
    VkPhysicalDeviceProperties properties;
    vkGetPhysicalDeviceProperties(physical, &properties);
    assert(properties.deviceType == VK_PHYSICAL_DEVICE_TYPE_CPU);

    // No executor: the CPU device works.
    auto* before = new Device;
    for (int i = 0; i < 20; ++i) assert(before->frame() == VK_SUCCESS);

    // An executor appears: within ~100 ms the device reports loss, and keeps reporting it.
    int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    sockaddr_un address{}; address.sun_family = AF_UNIX;
    std::strncpy(address.sun_path, path, sizeof(address.sun_path) - 1);
    assert(bind(listener, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0 && listen(listener, 1) == 0);
    const auto appeared = std::chrono::steady_clock::now();
    VkResult result = VK_SUCCESS;
    while ((result = before->frame()) == VK_SUCCESS) {
        assert(std::chrono::steady_clock::now() - appeared < std::chrono::milliseconds(500));
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    assert(result == VK_ERROR_DEVICE_LOST);
    assert(vkGetFenceStatus(before->device, before->fence) == VK_ERROR_DEVICE_LOST);
    assert(vkDeviceWaitIdle(before->device) == VK_ERROR_DEVICE_LOST);
    assert(vkQueueWaitIdle(before->queue) == VK_ERROR_DEVICE_LOST);
    delete before;

    // A CPU device created while the executor exists was chosen deliberately: it stays.
    auto* chosen = new Device;
    for (int i = 0; i < 20; ++i) assert(chosen->frame() == VK_SUCCESS);
    delete chosen;

    close(listener); unlink(path);
    vkDestroyInstance(instance, nullptr);
    std::puts("executor switch: CPU device lost when an executor appeared; a later device kept");
    return 0;
}
