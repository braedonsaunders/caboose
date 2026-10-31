// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
//
// VK_LAYER_CABOOSE_executor_switch (README.md). A Vulkan device created on a CPU
// implementation while no phone executor was available is lost once one becomes
// available, so the application recreates it and finds the phone's GPU.
#include <vulkan/vk_layer.h>
#include <vulkan/vulkan.h>

#include <sys/stat.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

namespace {

// The executor's socket exists exactly while the broker has a ready executor.
class Executor {
public:
    Executor() {
        const char* path = std::getenv("CABOOSE_GFXSTREAM_SOCKET");
        if (path && *path) path_ = path;
    }
    bool configured() const { return !path_.empty(); }
    bool available() {
        if (path_.empty()) return false;
        // At most one check per 100 ms: the calls asking are per-frame.
        const int64_t now = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count();
        int64_t last = checkedAt_.load(std::memory_order_relaxed);
        if (now - last < 100) return available_.load(std::memory_order_relaxed);
        checkedAt_.store(now, std::memory_order_relaxed);
        struct stat info;
        const bool present = stat(path_.c_str(), &info) == 0 && S_ISSOCK(info.st_mode);
        available_.store(present, std::memory_order_relaxed);
        return present;
    }

private:
    std::string path_;
    std::atomic<int64_t> checkedAt_{-1000};
    std::atomic<bool> available_{false};
};
Executor& executor() {
    static Executor* instance = new Executor;  // never destroyed: calls may race exit
    return *instance;
}

void* key(const void* dispatchable) { return *static_cast<void* const*>(dispatchable); }

struct InstanceData {
    PFN_vkGetInstanceProcAddr next = nullptr;
    PFN_vkDestroyInstance destroy = nullptr;
    PFN_vkCreateDevice createDevice = nullptr;
    PFN_vkGetPhysicalDeviceProperties properties = nullptr;
};

struct DeviceData {
    PFN_vkGetDeviceProcAddr next = nullptr;
    PFN_vkDestroyDevice destroy = nullptr;
    PFN_vkQueueSubmit queueSubmit = nullptr;
    PFN_vkQueueSubmit2 queueSubmit2 = nullptr;
    PFN_vkQueueSubmit2 queueSubmit2KHR = nullptr;
    PFN_vkQueuePresentKHR queuePresent = nullptr;
    PFN_vkAcquireNextImageKHR acquire = nullptr;
    PFN_vkAcquireNextImage2KHR acquire2 = nullptr;
    PFN_vkWaitForFences waitForFences = nullptr;
    PFN_vkGetFenceStatus fenceStatus = nullptr;
    PFN_vkWaitSemaphores waitSemaphores = nullptr;
    PFN_vkWaitSemaphores waitSemaphoresKHR = nullptr;
    PFN_vkDeviceWaitIdle deviceWaitIdle = nullptr;
    PFN_vkQueueWaitIdle queueWaitIdle = nullptr;
    // Created on a CPU implementation while no executor existed.
    bool switchable = false;
    std::atomic<bool> lost{false};
};

std::mutex mutex;
std::unordered_map<void*, std::unique_ptr<InstanceData>> instances;
std::unordered_map<void*, std::unique_ptr<DeviceData>> devices;

InstanceData* instanceData(const void* handle) {
    std::lock_guard<std::mutex> lock(mutex);
    auto found = instances.find(key(handle));
    return found == instances.end() ? nullptr : found->second.get();
}
DeviceData* deviceData(const void* handle) {
    std::lock_guard<std::mutex> lock(mutex);
    auto found = devices.find(key(handle));
    return found == devices.end() ? nullptr : found->second.get();
}

// True once the device must report loss: sticky, as device loss is.
bool lost(DeviceData& device) {
    if (device.lost.load(std::memory_order_relaxed)) return true;
    if (!device.switchable || !executor().available()) return false;
    if (!device.lost.exchange(true))
        std::fprintf(stderr, "CABOOSE_GPU_EXECUTOR_SWITCH: a phone executor is available; reporting device loss\n");
    return true;
}

template <class Info>
const VkLayerInstanceCreateInfo* instanceLink(const Info* info) {
    for (auto* next = static_cast<const VkBaseInStructure*>(info->pNext); next; next = next->pNext) {
        if (next->sType != VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO) continue;
        auto* link = reinterpret_cast<const VkLayerInstanceCreateInfo*>(next);
        if (link->function == VK_LAYER_LINK_INFO) return link;
    }
    return nullptr;
}
const VkLayerDeviceCreateInfo* deviceLink(const VkDeviceCreateInfo* info) {
    for (auto* next = static_cast<const VkBaseInStructure*>(info->pNext); next; next = next->pNext) {
        if (next->sType != VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO) continue;
        auto* link = reinterpret_cast<const VkLayerDeviceCreateInfo*>(next);
        if (link->function == VK_LAYER_LINK_INFO) return link;
    }
    return nullptr;
}

VKAPI_ATTR VkResult VKAPI_CALL CreateInstance(const VkInstanceCreateInfo* info, const VkAllocationCallbacks* allocator,
                                              VkInstance* instance) {
    auto* link = const_cast<VkLayerInstanceCreateInfo*>(instanceLink(info));
    if (!link || !link->u.pLayerInfo) return VK_ERROR_INITIALIZATION_FAILED;
    PFN_vkGetInstanceProcAddr next = link->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    link->u.pLayerInfo = link->u.pLayerInfo->pNext;
    auto create = reinterpret_cast<PFN_vkCreateInstance>(next(VK_NULL_HANDLE, "vkCreateInstance"));
    if (!create) return VK_ERROR_INITIALIZATION_FAILED;
    VkResult result = create(info, allocator, instance);
    if (result != VK_SUCCESS) return result;
    auto data = std::make_unique<InstanceData>();
    data->next = next;
    data->destroy = reinterpret_cast<PFN_vkDestroyInstance>(next(*instance, "vkDestroyInstance"));
    data->createDevice = reinterpret_cast<PFN_vkCreateDevice>(next(*instance, "vkCreateDevice"));
    data->properties =
        reinterpret_cast<PFN_vkGetPhysicalDeviceProperties>(next(*instance, "vkGetPhysicalDeviceProperties"));
    std::lock_guard<std::mutex> lock(mutex);
    instances[key(*instance)] = std::move(data);
    return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL DestroyInstance(VkInstance instance, const VkAllocationCallbacks* allocator) {
    if (!instance) return;
    PFN_vkDestroyInstance destroy = nullptr;
    {
        std::lock_guard<std::mutex> lock(mutex);
        auto found = instances.find(key(instance));
        if (found == instances.end()) return;
        destroy = found->second->destroy;
        instances.erase(found);
    }
    if (destroy) destroy(instance, allocator);
}

template <class F>
F load(PFN_vkGetDeviceProcAddr next, VkDevice device, const char* name) {
    return reinterpret_cast<F>(next(device, name));
}

VKAPI_ATTR VkResult VKAPI_CALL CreateDevice(VkPhysicalDevice physical, const VkDeviceCreateInfo* info,
                                            const VkAllocationCallbacks* allocator, VkDevice* device) {
    InstanceData* owner = instanceData(physical);
    auto* link = const_cast<VkLayerDeviceCreateInfo*>(deviceLink(info));
    if (!owner || !link || !link->u.pLayerInfo) return VK_ERROR_INITIALIZATION_FAILED;
    PFN_vkGetInstanceProcAddr nextInstance = link->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    PFN_vkGetDeviceProcAddr next = link->u.pLayerInfo->pfnNextGetDeviceProcAddr;
    link->u.pLayerInfo = link->u.pLayerInfo->pNext;
    auto create = reinterpret_cast<PFN_vkCreateDevice>(nextInstance(VK_NULL_HANDLE, "vkCreateDevice"));
    if (!create) create = owner->createDevice;
    if (!create) return VK_ERROR_INITIALIZATION_FAILED;
    VkPhysicalDeviceProperties properties{};
    if (owner->properties) owner->properties(physical, &properties);
    // Decided before creation: a device made while the executor existed stays where it is.
    const bool switchable = executor().configured() && properties.deviceType == VK_PHYSICAL_DEVICE_TYPE_CPU &&
                            !executor().available();
    VkResult result = create(physical, info, allocator, device);
    if (result != VK_SUCCESS) return result;
    auto data = std::make_unique<DeviceData>();
    data->next = next;
    data->switchable = switchable;
    data->destroy = load<PFN_vkDestroyDevice>(next, *device, "vkDestroyDevice");
    data->queueSubmit = load<PFN_vkQueueSubmit>(next, *device, "vkQueueSubmit");
    data->queueSubmit2 = load<PFN_vkQueueSubmit2>(next, *device, "vkQueueSubmit2");
    data->queueSubmit2KHR = load<PFN_vkQueueSubmit2>(next, *device, "vkQueueSubmit2KHR");
    data->queuePresent = load<PFN_vkQueuePresentKHR>(next, *device, "vkQueuePresentKHR");
    data->acquire = load<PFN_vkAcquireNextImageKHR>(next, *device, "vkAcquireNextImageKHR");
    data->acquire2 = load<PFN_vkAcquireNextImage2KHR>(next, *device, "vkAcquireNextImage2KHR");
    data->waitForFences = load<PFN_vkWaitForFences>(next, *device, "vkWaitForFences");
    data->fenceStatus = load<PFN_vkGetFenceStatus>(next, *device, "vkGetFenceStatus");
    data->waitSemaphores = load<PFN_vkWaitSemaphores>(next, *device, "vkWaitSemaphores");
    data->waitSemaphoresKHR = load<PFN_vkWaitSemaphores>(next, *device, "vkWaitSemaphoresKHR");
    data->deviceWaitIdle = load<PFN_vkDeviceWaitIdle>(next, *device, "vkDeviceWaitIdle");
    data->queueWaitIdle = load<PFN_vkQueueWaitIdle>(next, *device, "vkQueueWaitIdle");
    std::lock_guard<std::mutex> lock(mutex);
    devices[key(*device)] = std::move(data);
    return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL DestroyDevice(VkDevice device, const VkAllocationCallbacks* allocator) {
    if (!device) return;
    PFN_vkDestroyDevice destroy = nullptr;
    {
        std::lock_guard<std::mutex> lock(mutex);
        auto found = devices.find(key(device));
        if (found == devices.end()) return;
        destroy = found->second->destroy;
        devices.erase(found);
    }
    if (destroy) destroy(device, allocator);
}

// Each wrapped call reports loss, or goes to the next layer. Queues share their device's key.
#define FORWARD(handle, member, ...)                                        \
    DeviceData* data = deviceData(handle);                                  \
    if (!data || !data->member) return VK_ERROR_INITIALIZATION_FAILED;      \
    if (lost(*data)) return VK_ERROR_DEVICE_LOST;                           \
    return data->member(__VA_ARGS__)

VKAPI_ATTR VkResult VKAPI_CALL QueueSubmit(VkQueue queue, uint32_t count, const VkSubmitInfo* submits, VkFence fence) {
    FORWARD(queue, queueSubmit, queue, count, submits, fence);
}
VKAPI_ATTR VkResult VKAPI_CALL QueueSubmit2(VkQueue queue, uint32_t count, const VkSubmitInfo2* submits, VkFence fence) {
    FORWARD(queue, queueSubmit2, queue, count, submits, fence);
}
VKAPI_ATTR VkResult VKAPI_CALL QueueSubmit2KHR(VkQueue queue, uint32_t count, const VkSubmitInfo2* submits,
                                               VkFence fence) {
    FORWARD(queue, queueSubmit2KHR, queue, count, submits, fence);
}
VKAPI_ATTR VkResult VKAPI_CALL QueuePresentKHR(VkQueue queue, const VkPresentInfoKHR* info) {
    DeviceData* data = deviceData(queue);
    if (!data || !data->queuePresent) return VK_ERROR_INITIALIZATION_FAILED;
    if (lost(*data)) {
        if (info && info->pResults)
            for (uint32_t i = 0; i < info->swapchainCount; ++i) info->pResults[i] = VK_ERROR_DEVICE_LOST;
        return VK_ERROR_DEVICE_LOST;
    }
    return data->queuePresent(queue, info);
}
VKAPI_ATTR VkResult VKAPI_CALL AcquireNextImageKHR(VkDevice device, VkSwapchainKHR swapchain, uint64_t timeout,
                                                   VkSemaphore semaphore, VkFence fence, uint32_t* index) {
    FORWARD(device, acquire, device, swapchain, timeout, semaphore, fence, index);
}
VKAPI_ATTR VkResult VKAPI_CALL AcquireNextImage2KHR(VkDevice device, const VkAcquireNextImageInfoKHR* info,
                                                    uint32_t* index) {
    FORWARD(device, acquire2, device, info, index);
}
VKAPI_ATTR VkResult VKAPI_CALL WaitForFences(VkDevice device, uint32_t count, const VkFence* fences, VkBool32 all,
                                             uint64_t timeout) {
    FORWARD(device, waitForFences, device, count, fences, all, timeout);
}
VKAPI_ATTR VkResult VKAPI_CALL GetFenceStatus(VkDevice device, VkFence fence) {
    FORWARD(device, fenceStatus, device, fence);
}
VKAPI_ATTR VkResult VKAPI_CALL WaitSemaphores(VkDevice device, const VkSemaphoreWaitInfo* info, uint64_t timeout) {
    FORWARD(device, waitSemaphores, device, info, timeout);
}
VKAPI_ATTR VkResult VKAPI_CALL WaitSemaphoresKHR(VkDevice device, const VkSemaphoreWaitInfo* info, uint64_t timeout) {
    FORWARD(device, waitSemaphoresKHR, device, info, timeout);
}
VKAPI_ATTR VkResult VKAPI_CALL DeviceWaitIdle(VkDevice device) { FORWARD(device, deviceWaitIdle, device); }
VKAPI_ATTR VkResult VKAPI_CALL QueueWaitIdle(VkQueue queue) { FORWARD(queue, queueWaitIdle, queue); }
#undef FORWARD

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL GetDeviceProcAddr(VkDevice device, const char* name);

PFN_vkVoidFunction deviceFunction(const char* name) {
#define ENTRY(fn) \
    if (!std::strcmp(name, "vk" #fn)) return reinterpret_cast<PFN_vkVoidFunction>(fn)
    ENTRY(GetDeviceProcAddr);
    ENTRY(DestroyDevice);
    ENTRY(QueueSubmit);
    ENTRY(QueueSubmit2);
    ENTRY(QueueSubmit2KHR);
    ENTRY(QueuePresentKHR);
    ENTRY(AcquireNextImageKHR);
    ENTRY(AcquireNextImage2KHR);
    ENTRY(WaitForFences);
    ENTRY(GetFenceStatus);
    ENTRY(WaitSemaphores);
    ENTRY(WaitSemaphoresKHR);
    ENTRY(DeviceWaitIdle);
    ENTRY(QueueWaitIdle);
#undef ENTRY
    return nullptr;
}

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL GetDeviceProcAddr(VkDevice device, const char* name) {
    DeviceData* data = deviceData(device);
    if (!data) return nullptr;
    PFN_vkVoidFunction next = data->next(device, name);
    // Only functions the device has are wrapped; a missing one stays missing.
    if (!next) return nullptr;
    if (PFN_vkVoidFunction own = deviceFunction(name)) return own;
    return next;
}

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL GetInstanceProcAddr(VkInstance instance, const char* name) {
    if (!std::strcmp(name, "vkGetInstanceProcAddr")) return reinterpret_cast<PFN_vkVoidFunction>(GetInstanceProcAddr);
    if (!std::strcmp(name, "vkCreateInstance")) return reinterpret_cast<PFN_vkVoidFunction>(CreateInstance);
    if (!instance) return nullptr;
    if (!std::strcmp(name, "vkDestroyInstance")) return reinterpret_cast<PFN_vkVoidFunction>(DestroyInstance);
    if (!std::strcmp(name, "vkCreateDevice")) return reinterpret_cast<PFN_vkVoidFunction>(CreateDevice);
    InstanceData* data = instanceData(instance);
    if (!data) return nullptr;
    PFN_vkVoidFunction next = data->next(instance, name);
    if (!next) return nullptr;
    if (PFN_vkVoidFunction own = deviceFunction(name)) return own;
    return next;
}

}  // namespace

extern "C" {
__attribute__((visibility("default"))) VKAPI_ATTR VkResult VKAPI_CALL
vkNegotiateLoaderLayerInterfaceVersion(VkNegotiateLayerInterface* interface) {
    if (!interface || interface->sType != LAYER_NEGOTIATE_INTERFACE_STRUCT) return VK_ERROR_INITIALIZATION_FAILED;
    if (interface->loaderLayerInterfaceVersion < 2) return VK_ERROR_INITIALIZATION_FAILED;
    interface->loaderLayerInterfaceVersion = 2;
    interface->pfnGetInstanceProcAddr = GetInstanceProcAddr;
    interface->pfnGetDeviceProcAddr = GetDeviceProcAddr;
    interface->pfnGetPhysicalDeviceProcAddr = nullptr;
    return VK_SUCCESS;
}
}
