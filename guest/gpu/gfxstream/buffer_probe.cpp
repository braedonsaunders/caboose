// SPDX-License-Identifier: MIT
// Private diagnostic. Uses Mesa's generated encoder and non-direct shadow path;
// does not expose an ICD or claim coherent-memory support.
#include "SocketStream.h"
#include "ResourceTracker.h"
#include "VkEncoder.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#define CHECK(call) do { VkResult r_ = (call); if (r_ != VK_SUCCESS) { \
    std::fprintf(stderr, "%s returned %d\n", #call, r_); return 1; } } while (0)

int main(int argc, char** argv) {
    if (argc != 3) { std::fprintf(stderr, "usage: buffer_probe SOCKET UINT32_CHALLENGE\n"); return 2; }
    char* end = nullptr;
    unsigned long parsed = std::strtoul(argv[2], &end, 10);
    if (!*argv[2] || *end || parsed > UINT32_MAX) return 2;
    uint32_t challenge = static_cast<uint32_t>(parsed);
    if (setenv("CABOOSE_GFXSTREAM_SOCKET", argv[1], 1) != 0) return 1;
    auto* tracker = gfxstream::vk::ResourceTracker::get();
    if (tracker->getStreamFeatures() != 0 || tracker->usingDirectMapping()) return 1;
    auto* stream = new CabooseSocketStream(1024 * 1024);
    if (stream->connect(argv[1]) != 0) { std::perror("socket handshake"); stream->decRef(); return 1; }
    const uint32_t flags = 0;
    if (stream->writeFully(&flags, sizeof(flags)) != 0) { stream->decRef(); return 1; }
    {
        gfxstream::vk::VkEncoder enc(stream);
        VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
        app.pApplicationName = "Caboose private buffer probe";
        app.apiVersion = VK_API_VERSION_1_0;
        VkInstanceCreateInfo instanceInfo{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
        instanceInfo.pApplicationInfo = &app;
        VkInstance instance = VK_NULL_HANDLE;
        CHECK(enc.vkCreateInstance(&instanceInfo, nullptr, &instance, true));
        CHECK(tracker->on_vkCreateInstance(&enc, VK_SUCCESS, &instanceInfo, nullptr, &instance));
        uint32_t count = 0;
        CHECK(enc.vkEnumeratePhysicalDevices(instance, &count, nullptr, true));
        if (!count || count > 64) { std::fprintf(stderr, "invalid physical device count\n"); return 1; }
        std::vector<VkPhysicalDevice> devices(count);
        CHECK(enc.vkEnumeratePhysicalDevices(instance, &count, devices.data(), true));
        VkPhysicalDevice physical = devices[0];
        uint32_t familyCount = 0;
        enc.vkGetPhysicalDeviceQueueFamilyProperties(physical, &familyCount, nullptr, true);
        if (!familyCount || familyCount > 128) return 1;
        std::vector<VkQueueFamilyProperties> families(familyCount);
        enc.vkGetPhysicalDeviceQueueFamilyProperties(physical, &familyCount, families.data(), true);
        uint32_t family = 0;
        while (family < familyCount && !(families[family].queueFlags & VK_QUEUE_TRANSFER_BIT)) ++family;
        if (family == familyCount) { std::fprintf(stderr, "no transfer queue\n"); return 77; }
        float priority = 1.0f;
        VkDeviceQueueCreateInfo queueInfo{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
        queueInfo.queueFamilyIndex = family; queueInfo.queueCount = 1; queueInfo.pQueuePriorities = &priority;
        VkDeviceCreateInfo deviceInfo{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
        deviceInfo.queueCreateInfoCount = 1; deviceInfo.pQueueCreateInfos = &queueInfo;
        VkDevice device = VK_NULL_HANDLE;
        CHECK(enc.vkCreateDevice(physical, &deviceInfo, nullptr, &device, true));
        CHECK(tracker->on_vkCreateDevice(&enc, VK_SUCCESS, physical, &deviceInfo, nullptr, &device));
        VkQueue queue = VK_NULL_HANDLE;
        enc.vkGetDeviceQueue(device, family, 0, &queue, true);
        VkBufferCreateInfo bufferInfo{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
        bufferInfo.size = 16; bufferInfo.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
        bufferInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        VkBuffer buffer = VK_NULL_HANDLE;
        CHECK(enc.vkCreateBuffer(device, &bufferInfo, nullptr, &buffer, true));
        VkMemoryRequirements req{};
        enc.vkGetBufferMemoryRequirements(device, buffer, &req, true);
        if (!req.size || req.size > 65536) { std::fprintf(stderr, "unsupported allocation size\n"); return 77; }
        VkPhysicalDeviceMemoryProperties props{};
        enc.vkGetPhysicalDeviceMemoryProperties(physical, &props, true);
        std::fprintf(stderr, "memoryTypeBits=0x%08x memoryTypeCount=%u\n", req.memoryTypeBits, props.memoryTypeCount);
        for (uint32_t i = 0; i < props.memoryTypeCount; ++i)
            std::fprintf(stderr, "memoryType[%u]=0x%08x\n", i, props.memoryTypes[i].propertyFlags);
        uint32_t type = 0;
        while (type < props.memoryTypeCount) {
            auto bits = props.memoryTypes[type].propertyFlags;
            if ((req.memoryTypeBits & (1u << type)) && (bits & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) &&
                !(bits & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) break;
            ++type;
        }
        if (type == props.memoryTypeCount) { std::fprintf(stderr, "no guest-advertised noncoherent host-visible type\n"); return 77; }
        VkMemoryAllocateInfo alloc{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
        alloc.allocationSize = req.size; alloc.memoryTypeIndex = type;
        VkDeviceMemory memory = VK_NULL_HANDLE;
        CHECK(tracker->on_vkAllocateMemory(&enc, VK_SUCCESS, device, &alloc, nullptr, &memory));
        CHECK(enc.vkBindBufferMemory(device, buffer, memory, 0, true));
        void* mapped = nullptr;
        CHECK(enc.vkMapMemory(device, memory, 0, VK_WHOLE_SIZE, 0, &mapped, true));
        uint32_t initial[4] = {challenge ^ 0xffffffffu, challenge ^ 0xffffffffu,
                               challenge ^ 0xffffffffu, challenge ^ 0xffffffffu};
        std::memcpy(mapped, initial, sizeof(initial));
        VkMappedMemoryRange range{VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE};
        range.memory = memory; range.offset = 0; range.size = VK_WHOLE_SIZE;
        CHECK(enc.vkFlushMappedMemoryRanges(device, 1, &range, true));
        VkCommandPoolCreateInfo poolInfo{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
        poolInfo.queueFamilyIndex = family;
        VkCommandPool pool = VK_NULL_HANDLE;
        CHECK(enc.vkCreateCommandPool(device, &poolInfo, nullptr, &pool, true));
        VkCommandBufferAllocateInfo commandInfo{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
        commandInfo.commandPool = pool; commandInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; commandInfo.commandBufferCount = 1;
        VkCommandBuffer command = VK_NULL_HANDLE;
        CHECK(enc.vkAllocateCommandBuffers(device, &commandInfo, &command, true));
        VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
        begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        CHECK(enc.vkBeginCommandBuffer(command, &begin, true));
        enc.vkCmdFillBuffer(command, buffer, 0, 16, challenge, true);
        VkMemoryBarrier barrier{VK_STRUCTURE_TYPE_MEMORY_BARRIER};
        barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT; barrier.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
        enc.vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
                                 0, 1, &barrier, 0, nullptr, 0, nullptr, true);
        CHECK(enc.vkEndCommandBuffer(command, true));
        VkFenceCreateInfo fenceInfo{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
        VkFence fence = VK_NULL_HANDLE;
        CHECK(enc.vkCreateFence(device, &fenceInfo, nullptr, &fence, true));
        VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
        submit.commandBufferCount = 1; submit.pCommandBuffers = &command;
        CHECK(enc.vkQueueSubmit(queue, 1, &submit, fence, true));
        CHECK(enc.vkWaitForFences(device, 1, &fence, VK_TRUE, 5000000000ULL, true));
        CHECK(enc.vkInvalidateMappedMemoryRanges(device, 1, &range, true));
        uint32_t observed[4]; std::memcpy(observed, mapped, sizeof(observed));
        for (auto word : observed) if (word != challenge) { std::fprintf(stderr, "GPU readback mismatch\n"); return 1; }
        enc.vkUnmapMemory(device, memory, true);
        enc.vkDestroyFence(device, fence, nullptr, true);
        enc.vkDestroyCommandPool(device, pool, nullptr, true);
        enc.vkDestroyBuffer(device, buffer, nullptr, true);
        tracker->on_vkFreeMemory(&enc, device, memory, nullptr);
        enc.vkDestroyDevice(device, nullptr, true);
        enc.vkDestroyInstance(instance, nullptr, true);
        std::printf("{\"challenge\":%u,\"observed\":[%u,%u,%u,%u],\"memory_type\":%u,\"memory_flags\":%u}\n",
                    challenge, observed[0], observed[1], observed[2], observed[3], type,
                    props.memoryTypes[type].propertyFlags);
    }
    stream->decRef();
    return 0;
}
