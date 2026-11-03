// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
//
// Checks dma-buf export on a CPU implementation presented as a GPU (README.md, "Dma-bufs
// without the phone"), on a machine with a vgem node and lavapipe, through the layer:
// memory allocated for dma-buf export is exported, the descriptor is a dma-buf, and bytes
// written through its own mapping read back through vkMapMemory. Prints PASS or FAIL.
#include <vulkan/vulkan.h>

#include <sys/mman.h>
#include <unistd.h>

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "routing.h"

static int fail(const char* what, int code) {
    std::printf("FAIL %s (%d)\n", what, code);
    return 1;
}

int main() {
    VkApplicationInfo app{};
    app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.apiVersion = VK_API_VERSION_1_1;
    VkInstanceCreateInfo instanceInfo{};
    instanceInfo.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    instanceInfo.pApplicationInfo = &app;
    VkInstance instance;
    if (VkResult r = vkCreateInstance(&instanceInfo, nullptr, &instance)) return fail("vkCreateInstance", r);
    uint32_t count = 0;
    vkEnumeratePhysicalDevices(instance, &count, nullptr);
    std::vector<VkPhysicalDevice> physicals(count);
    vkEnumeratePhysicalDevices(instance, &count, physicals.data());
    VkPhysicalDevice physical = VK_NULL_HANDLE;
    for (auto candidate : physicals) {
        VkPhysicalDeviceProperties props;
        vkGetPhysicalDeviceProperties(candidate, &props);
        if (!std::strcmp(props.deviceName, caboose_routing::kNoPhoneName)) physical = candidate;
    }
    if (!physical) return fail("no device presented as the CPU fallback", 0);
    const char* extensions[] = {VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME, VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME};
    const float priority = 1.0f;
    VkDeviceQueueCreateInfo queueInfo{};
    queueInfo.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    queueInfo.queueCount = 1;
    queueInfo.pQueuePriorities = &priority;
    VkDeviceCreateInfo deviceInfo{};
    deviceInfo.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    deviceInfo.queueCreateInfoCount = 1;
    deviceInfo.pQueueCreateInfos = &queueInfo;
    deviceInfo.enabledExtensionCount = 2;
    deviceInfo.ppEnabledExtensionNames = extensions;
    VkDevice device;
    if (VkResult r = vkCreateDevice(physical, &deviceInfo, nullptr, &device)) return fail("vkCreateDevice", r);
    VkPhysicalDeviceMemoryProperties memoryProps;
    vkGetPhysicalDeviceMemoryProperties(physical, &memoryProps);
    uint32_t type = UINT32_MAX;
    for (uint32_t i = 0; i < memoryProps.memoryTypeCount && type == UINT32_MAX; ++i)
        if (memoryProps.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) type = i;
    if (type == UINT32_MAX) return fail("no host-visible memory type", 0);
    const VkDeviceSize size = 1 << 20;
    VkExportMemoryAllocateInfo exportInfo{};
    exportInfo.sType = VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO;
    exportInfo.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
    VkMemoryAllocateInfo allocate{};
    allocate.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    allocate.pNext = &exportInfo;
    allocate.allocationSize = size;
    allocate.memoryTypeIndex = type;
    VkDeviceMemory memory;
    if (VkResult r = vkAllocateMemory(device, &allocate, nullptr, &memory)) return fail("vkAllocateMemory", r);
    auto getFd = reinterpret_cast<PFN_vkGetMemoryFdKHR>(vkGetDeviceProcAddr(device, "vkGetMemoryFdKHR"));
    VkMemoryGetFdInfoKHR fdInfo{};
    fdInfo.sType = VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR;
    fdInfo.memory = memory;
    fdInfo.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
    int fd = -1;
    if (VkResult r = getFd(device, &fdInfo, &fd)) return fail("vkGetMemoryFdKHR", r);
    char link[256] = {};
    const std::string self = "/proc/self/fd/" + std::to_string(fd);
    if (readlink(self.c_str(), link, sizeof(link) - 1) < 0 || std::strncmp(link, "/dmabuf:", 8))
        return fail(("not a dma-buf: " + std::string(link)).c_str(), 0);
    auto* direct = static_cast<unsigned char*>(mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0));
    if (direct == MAP_FAILED) return fail("mmap of the dma-buf", 0);
    for (VkDeviceSize i = 0; i < size; ++i) direct[i] = static_cast<unsigned char>(i * 7 + 1);
    void* mapped = nullptr;
    if (VkResult r = vkMapMemory(device, memory, 0, size, 0, &mapped)) return fail("vkMapMemory", r);
    const bool same = std::memcmp(mapped, direct, size) == 0;
    vkUnmapMemory(device, memory);
    munmap(direct, size);
    close(fd);
    vkFreeMemory(device, memory, nullptr);
    vkDestroyDevice(device, nullptr);
    vkDestroyInstance(instance, nullptr);
    if (!same) return fail("bytes written through the dma-buf differ through vkMapMemory", 0);
    std::printf("PASS dma-buf export on the CPU fallback: %s, 1 MiB shared\n", link);
    return 0;
}
