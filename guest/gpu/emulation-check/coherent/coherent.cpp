// SPDX-License-Identifier: AGPL-3.0-or-later
// Native coherent-memory litmus. No flush/invalidate calls are made.
#include <vulkan/vulkan.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

static void check(VkResult r, const char* call) {
    if (r != VK_SUCCESS) throw std::runtime_error(std::string(call) + ": " + std::to_string(r));
}
#define VK(call) check((call), #call)
struct State {
    VkInstance instance{}; VkDevice device{}; VkBuffer buffer{}; VkDeviceMemory memory{};
    VkCommandPool pool{}; VkFence fence{}; VkEvent event{}; void* mapped{};
    ~State() {
        if (device) {
            // The parent runner bounds teardown if a broken device hangs.
            if (event) vkSetEvent(device, event);
            vkDeviceWaitIdle(device);
            if (mapped) vkUnmapMemory(device, memory);
            if (event) vkDestroyEvent(device, event, nullptr);
            if (fence) vkDestroyFence(device, fence, nullptr);
            if (pool) vkDestroyCommandPool(device, pool, nullptr);
            if (buffer) vkDestroyBuffer(device, buffer, nullptr);
            if (memory) vkFreeMemory(device, memory, nullptr);
            vkDestroyDevice(device, nullptr);
        }
        if (instance) vkDestroyInstance(instance, nullptr);
    }
};

int main(int argc, char** argv) {
    if (argc != 2) { std::fprintf(stderr, "usage: coherent UINT32_SEED\n"); return 2; }
    char* end = nullptr; unsigned long long n = std::strtoull(argv[1], &end, 10);
    if (!*argv[1] || *end || n > UINT32_MAX) return 2;
    uint32_t seed = static_cast<uint32_t>(n);
    try {
        State s;
        VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO}; app.apiVersion = VK_API_VERSION_1_0;
        VkInstanceCreateInfo ci{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO}; ci.pApplicationInfo = &app;
        VkResult instanceResult = vkCreateInstance(&ci, nullptr, &s.instance);
        if (instanceResult == VK_ERROR_INCOMPATIBLE_DRIVER) {
            std::printf("{\"status\":\"UNSUPPORTED\",\"reason\":\"instance rejected\",\"result\":%d}\n", instanceResult); return 77;
        }
        VK(instanceResult);
        uint32_t count=0; VK(vkEnumeratePhysicalDevices(s.instance, &count, nullptr));
        if (!count) { std::puts("{\"status\":\"UNSUPPORTED\",\"reason\":\"no device\"}"); return 77; }
        std::vector<VkPhysicalDevice> devices(count); VK(vkEnumeratePhysicalDevices(s.instance, &count, devices.data()));
        VkPhysicalDevice physical=devices[0];
        VkPhysicalDeviceProperties properties{}; vkGetPhysicalDeviceProperties(physical, &properties);
        uint32_t familyCount=0; vkGetPhysicalDeviceQueueFamilyProperties(physical, &familyCount, nullptr);
        std::vector<VkQueueFamilyProperties> families(familyCount);
        vkGetPhysicalDeviceQueueFamilyProperties(physical, &familyCount, families.data());
        uint32_t family=0; while (family<familyCount && !(families[family].queueFlags & VK_QUEUE_TRANSFER_BIT)) ++family;
        if (family==familyCount) { std::puts("{\"status\":\"UNSUPPORTED\",\"reason\":\"no transfer queue\"}"); return 77; }
        float priority=1; VkDeviceQueueCreateInfo qi{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
        qi.queueFamilyIndex=family; qi.queueCount=1; qi.pQueuePriorities=&priority;
        VkDeviceCreateInfo di{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO}; di.queueCreateInfoCount=1; di.pQueueCreateInfos=&qi;
        VK(vkCreateDevice(physical, &di, nullptr, &s.device));
        VkQueue queue{}; vkGetDeviceQueue(s.device, family, 0, &queue);
        VkBufferCreateInfo bi{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO}; bi.size=12288;
        bi.usage=VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT; bi.sharingMode=VK_SHARING_MODE_EXCLUSIVE;
        VK(vkCreateBuffer(s.device, &bi, nullptr, &s.buffer));
        VkMemoryRequirements req{}; vkGetBufferMemoryRequirements(s.device, s.buffer, &req);
        VkPhysicalDeviceMemoryProperties props{}; vkGetPhysicalDeviceMemoryProperties(physical, &props);
        uint32_t type=0; while (type<props.memoryTypeCount) {
            auto flags=props.memoryTypes[type].propertyFlags;
            if ((req.memoryTypeBits & (1u<<type)) && (flags & (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) == (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) break;
            ++type;
        }
        if (type==props.memoryTypeCount) { std::puts("{\"status\":\"UNSUPPORTED\",\"reason\":\"no host coherent type\"}"); return 77; }
        VkMemoryAllocateInfo ai{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO}; ai.allocationSize=req.size; ai.memoryTypeIndex=type;
        VK(vkAllocateMemory(s.device, &ai, nullptr, &s.memory)); VK(vkBindBufferMemory(s.device, s.buffer, s.memory, 0));
        VK(vkMapMemory(s.device, s.memory, 0, VK_WHOLE_SIZE, 0, &s.mapped));
        auto bytes=static_cast<uint8_t*>(s.mapped); std::memset(bytes, 0xa5, 12288);
        std::memcpy(bytes, &seed, 4);
        VkCommandPoolCreateInfo pi{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO}; pi.queueFamilyIndex=family;
        VK(vkCreateCommandPool(s.device, &pi, nullptr, &s.pool));
        VkCommandBufferAllocateInfo ca{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO}; ca.commandPool=s.pool; ca.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY; ca.commandBufferCount=1;
        VkCommandBuffer cmd{}; VK(vkAllocateCommandBuffers(s.device, &ca, &cmd));
        VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO}; VK(vkBeginCommandBuffer(cmd, &begin));
        // A -> B proves host writes are available to the GPU at submit.
        VkBufferCopy copy{0,4096,4}; vkCmdCopyBuffer(cmd,s.buffer,s.buffer,1,&copy);
        VkMemoryBarrier toHost{VK_STRUCTURE_TYPE_MEMORY_BARRIER}; toHost.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT; toHost.dstAccessMask=VK_ACCESS_HOST_READ_BIT;
        vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,1,&toHost,0,nullptr,0,nullptr);
        VK(vkEndCommandBuffer(cmd)); VkFenceCreateInfo fi{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO}; VK(vkCreateFence(s.device,&fi,nullptr,&s.fence));
        VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO}; submit.commandBufferCount=1; submit.pCommandBuffers=&cmd;
        VK(vkQueueSubmit(queue,1,&submit,s.fence)); VK(vkWaitForFences(s.device,1,&s.fence,VK_TRUE,5000000000ULL));
        uint32_t value=0; std::memcpy(&value,bytes+4096,4); if(value!=seed) throw std::runtime_error("host-to-device result mismatch");
        VK(vkResetFences(s.device,1,&s.fence)); VK(vkResetCommandPool(s.device,s.pool,0));
        VkEventCreateInfo ei{VK_STRUCTURE_TYPE_EVENT_CREATE_INFO}; VK(vkCreateEvent(s.device,&ei,nullptr,&s.event));
        VK(vkBeginCommandBuffer(cmd,&begin));
        vkCmdWaitEvents(cmd,1,&s.event,VK_PIPELINE_STAGE_HOST_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,nullptr,0,nullptr,0,nullptr);
        uint32_t gpuWord=seed ^ 0x6d2b79f5u;
        // GPU writes B and a word at offset 4, sharing a page with CPU word A.
        vkCmdFillBuffer(cmd,s.buffer,4096,4,gpuWord); vkCmdFillBuffer(cmd,s.buffer,4,4,gpuWord);
        vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,1,&toHost,0,nullptr,0,nullptr);
        VK(vkEndCommandBuffer(cmd)); VK(vkQueueSubmit(queue,1,&submit,s.fence));
        VkResult poll=vkGetFenceStatus(s.device,s.fence);
        if (poll!=VK_NOT_READY) throw std::runtime_error("unsignaled event did not keep fence pending");
        VkResult timed=vkWaitForFences(s.device,1,&s.fence,VK_TRUE,1000000);
        if (timed!=VK_TIMEOUT) throw std::runtime_error("unsignaled event wait did not time out");
        uint32_t cpuWord=seed ^ 0xa17c42e9u; std::memcpy(bytes,&cpuWord,4);
        VK(vkSetEvent(s.device,s.event)); VK(vkWaitForFences(s.device,1,&s.fence,VK_TRUE,5000000000ULL));
        VK(vkGetFenceStatus(s.device,s.fence));
        uint32_t cpuRead=0, samePage=0, gpuRead=0;
        std::memcpy(&cpuRead,bytes,4); std::memcpy(&samePage,bytes+4,4); std::memcpy(&gpuRead,bytes+4096,4);
        if(cpuRead!=cpuWord || samePage!=gpuWord || gpuRead!=gpuWord) throw std::runtime_error("disjoint coherent update mismatch");
        for (size_t i=8;i<4096;i++) if(bytes[i]!=0xa5) throw std::runtime_error("same-page guard changed");
        for (size_t i=4100;i<12288;i++) if(bytes[i]!=0xa5) throw std::runtime_error("other guard changed");
        VK(vkResetFences(s.device,1,&s.fence)); VK(vkResetCommandPool(s.device,s.pool,0));
        VK(vkBeginCommandBuffer(cmd,&begin));
        VkBufferCopy secondCopy{0,8192,4}; vkCmdCopyBuffer(cmd,s.buffer,s.buffer,1,&secondCopy);
        vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,1,&toHost,0,nullptr,0,nullptr);
        VK(vkEndCommandBuffer(cmd)); VK(vkQueueSubmit(queue,1,&submit,s.fence));
        VK(vkWaitForFences(s.device,1,&s.fence,VK_TRUE,5000000000ULL));
        uint32_t finalRead=0; std::memcpy(&finalRead,bytes+8192,4);
        if (finalRead!=cpuWord) throw std::runtime_error("subsequent GPU read of CPU update mismatch");
        std::printf("{\"status\":\"PASS\",\"seed\":%u,\"memory_type\":%u,\"memory_flags\":%u,\"cpu_word\":%u,\"gpu_word\":%u,\"poll_not_ready\":true,\"timeout\":true}\n",seed,type,props.memoryTypes[type].propertyFlags,cpuRead,gpuRead);
        return 0;
    } catch (const std::exception& e) { std::fprintf(stderr,"coherent litmus: %s\n",e.what()); return 1; }
}
