// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
//
// VK_LAYER_CABOOSE_executor_switch (README.md). A Vulkan device created on a CPU
// implementation while no phone executor was available is lost once one becomes
// available, in a process that recovers from device loss, so it recreates the device and
// finds the phone's GPU; any other process keeps its device and is recorded as running on
// the CPU until relaunched.
#include <vulkan/vk_layer.h>
#include <vulkan/vulkan.h>

#include <link.h>
#include <sys/stat.h>
#include <unistd.h>

#include "policy.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

using namespace caboose_switch;

// The executor's socket exists exactly while the broker has a ready executor.
class Executor {
public:
    Executor() {
        const char* path = std::getenv("CABOOSE_GFXSTREAM_SOCKET");
        if (path && *path) path_ = path;
    }
    bool configured() const { return !path_.empty(); }
    const std::string& path() const { return path_; }
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

std::string readFile(const char* path) {
    std::ifstream file(path, std::ios::binary);
    return std::string((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
}

// Whether this process moves to the phone when one attaches (policy.h), decided once.
bool processMoves() {
    static const bool moves = [] {
        std::string commandLine = readFile("/proc/self/cmdline");
        for (char& c : commandLine) if (c == '\0') c = ' ';
        std::vector<std::string> libraries;
        dl_iterate_phdr([](dl_phdr_info* info, size_t, void* out) {
            if (info->dlpi_name && *info->dlpi_name)
                static_cast<std::vector<std::string>*>(out)->emplace_back(info->dlpi_name);
            return 0;
        }, &libraries);
        return movesToPhone(std::getenv("CABOOSE_GPU_ON_LOSS"), commandLine, libraries);
    }();
    return moves;
}

// The process's placement record, beside the broker's socket where the running-apps list
// (and a Flatpak sandbox) sees it: present while the process keeps a CPU device after a
// phone attached.
class Placement {
public:
    void staying() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (written_ || !executor().configured()) return;
        written_ = true;
        const std::string& socket = executor().path();
        const std::string directory = socket.substr(0, socket.rfind('/')) + "/placement";
        mkdir(directory.c_str(), 0700);
        file_ = directory + "/" + std::to_string(getpid());
        const std::string temporary = directory + "/." + std::to_string(getpid()) + ".tmp";
        const std::string line = placementLine(startTicks(readFile("/proc/self/stat")));
        if (FILE* out = std::fopen(temporary.c_str(), "w")) {
            const bool complete = std::fwrite(line.data(), 1, line.size(), out) == line.size();
            if (std::fclose(out) == 0 && complete && std::rename(temporary.c_str(), file_.c_str()) == 0) {
                std::fprintf(stderr, "CABOOSE_GPU_EXECUTOR_SWITCH: a phone executor is available; this process "
                                     "stays on the CPU until relaunched\n");
                return;
            }
            std::remove(temporary.c_str());
        }
        file_.clear();
    }
    void gone() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!file_.empty()) std::remove(file_.c_str());
        file_.clear();
        written_ = false;
    }

private:
    std::mutex mutex_;
    bool written_ = false;
    std::string file_;
};
Placement& placement() {
    static Placement* instance = new Placement;  // never destroyed: calls may race exit
    return *instance;
}

// CABOOSE_GPU_EXECUTOR_SWITCH_TRACE=1: every instance, device and lookup the layer handles,
// with dispatch keys, on stderr (diagnosis of how a driver reaches it).
const char tracingCopy = 0;
bool tracing() {
    static const bool on = [] { const char* v = std::getenv("CABOOSE_GPU_EXECUTOR_SWITCH_TRACE"); return v && *v == '1'; }();
    return on;
}
// `copy` tells apart two copies of this library in one process (two manifest paths).
#define TRACE(format, ...) do { if (tracing()) std::fprintf(stderr, "CABOOSE_GPU_EXECUTOR_SWITCH_TRACE pid=%d copy=%p " format "\n", \
                                    int(getpid()), static_cast<const void*>(&tracingCopy), ##__VA_ARGS__); } while (0)

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
    PFN_vkGetDeviceQueue getQueue = nullptr;
    PFN_vkGetDeviceQueue2 getQueue2 = nullptr;
    // Created on a CPU implementation while no executor existed.
    bool switchable = false;
    // ... in a process that stays where it is when a phone attaches.
    bool staying = false;
    std::atomic<bool> lost{false};
};

// Never destroyed: a driver may call the layer from its own exit-time cleanup, after this
// library's static destructors have run.
std::mutex& mutex = *new std::mutex;
std::unordered_map<void*, std::unique_ptr<InstanceData>>& instances = *new std::unordered_map<void*, std::unique_ptr<InstanceData>>;
std::unordered_map<void*, std::unique_ptr<DeviceData>>& devices = *new std::unordered_map<void*, std::unique_ptr<DeviceData>>;
// Queues by handle. A driver that takes vkGetDeviceQueue from vkGetDeviceProcAddr (Zink)
// calls it past the loader's trampoline, which is what writes the device's dispatch pointer
// into a queue: such a queue keeps the ICD's placeholder (ICD_LOADER_MAGIC), the same for
// every queue, so it cannot be found by dispatch key.
std::unordered_map<const void*, DeviceData*>& queues = *new std::unordered_map<const void*, DeviceData*>;

InstanceData* instanceData(const void* handle) {
    std::lock_guard<std::mutex> lock(mutex);
    auto found = instances.find(key(handle));
    return found == instances.end() ? nullptr : found->second.get();
}
DeviceData* deviceData(const void* handle) {
    std::lock_guard<std::mutex> lock(mutex);
    auto found = devices.find(key(handle));
    if (found != devices.end()) return found->second.get();
    auto queue = queues.find(handle);
    return queue == queues.end() ? nullptr : queue->second;
}
// Instance-level lookups of the wrapped device functions return the next layer's
// dispatching trampolines, which serve any device. A device this layer did not see created
// (a driver that reaches it through vkGetInstanceProcAddr, past this layer's vkCreateDevice)
// is served through them, unmanaged, instead of failing.
std::mutex& fallbackMutex = *new std::mutex;
std::unordered_map<std::string, PFN_vkVoidFunction>& fallbacks = *new std::unordered_map<std::string, PFN_vkVoidFunction>;
void rememberFallback(const char* name, PFN_vkVoidFunction next) {
    std::lock_guard<std::mutex> lock(fallbackMutex);
    fallbacks.emplace(name, next);
}
template <class F>
F fallback(const char* name) {
    std::lock_guard<std::mutex> lock(fallbackMutex);
    auto found = fallbacks.find(name);
    return found == fallbacks.end() ? nullptr : reinterpret_cast<F>(found->second);
}
// Said once, by name: such a device does not move to the phone.
void unknownDevice(const char* call) {
    TRACE("unknown device for %s", call);
    static std::atomic<bool> said{false};
    if (!said.exchange(true))
        std::fprintf(stderr, "CABOOSE_GPU_EXECUTOR_SWITCH: %s on a device or queue this layer did not create; "
                             "served unmanaged\n", call);
}

// True once the device must report loss: sticky, as device loss is.
bool lost(DeviceData& device) {
    if (device.lost.load(std::memory_order_relaxed)) return true;
    if (!device.switchable || !executor().available()) return false;
    if (device.staying) {
        placement().staying();
        return false;
    }
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
    TRACE("CreateInstance instance=%p key=%p", static_cast<void*>(*instance), key(*instance));
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
    TRACE("CreateDevice physical=%p key=%p owner=%d link=%d", static_cast<void*>(physical), key(physical), owner != nullptr,
          link && link->u.pLayerInfo);
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
    const bool switchable = executor().configured() &&
                            cpuImplementation(properties.vendorID, properties.deviceType) && !executor().available();
    VkResult result = create(physical, info, allocator, device);
    if (result != VK_SUCCESS) return result;
    auto data = std::make_unique<DeviceData>();
    data->next = next;
    data->switchable = switchable;
    data->staying = switchable && !processMoves();
    TRACE("CreateDevice device=%p key=%p vendor=0x%x type=%d switchable=%d staying=%d", static_cast<void*>(*device),
          key(*device), properties.vendorID, int(properties.deviceType), switchable, data->staying);
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
    data->getQueue = load<PFN_vkGetDeviceQueue>(next, *device, "vkGetDeviceQueue");
    data->getQueue2 = load<PFN_vkGetDeviceQueue2>(next, *device, "vkGetDeviceQueue2");
    std::lock_guard<std::mutex> lock(mutex);
    devices[key(*device)] = std::move(data);
    return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL DestroyDevice(VkDevice device, const VkAllocationCallbacks* allocator) {
    if (!device) return;
    TRACE("DestroyDevice device=%p key=%p", static_cast<void*>(device), key(device));
    PFN_vkDestroyDevice destroy = nullptr;
    {
        std::lock_guard<std::mutex> lock(mutex);
        auto found = devices.find(key(device));
        if (found == devices.end()) return;
        destroy = found->second->destroy;
        for (auto queue = queues.begin(); queue != queues.end();)
            queue = queue->second == found->second.get() ? queues.erase(queue) : std::next(queue);
        devices.erase(found);
        bool anyStaying = false;
        for (const auto& entry : devices) anyStaying |= entry.second->staying;
        if (!anyStaying) placement().gone();
    }
    if (destroy) destroy(device, allocator);
}

// Each wrapped call reports loss, or goes to the next layer. Queues share their device's key.
#define FORWARD(handle, member, name, ...)                                  \
    DeviceData* data = deviceData(handle);                                  \
    if (!data) {                                                            \
        TRACE("unknown handle=%p key=%p for %s devices=%zu queues=%zu", static_cast<const void*>(handle), \
              handle ? key(handle) : nullptr, #member, devices.size(), queues.size()); \
        unknownDevice(#member);                                             \
        auto next = fallback<decltype(DeviceData::member)>(name);           \
        return next ? next(__VA_ARGS__) : VK_ERROR_INITIALIZATION_FAILED;   \
    }                                                                       \
    if (!data->member) return VK_ERROR_INITIALIZATION_FAILED;               \
    if (lost(*data)) return VK_ERROR_DEVICE_LOST;                           \
    return data->member(__VA_ARGS__)

VKAPI_ATTR VkResult VKAPI_CALL QueueSubmit(VkQueue queue, uint32_t count, const VkSubmitInfo* submits, VkFence fence) {
    FORWARD(queue, queueSubmit, "vkQueueSubmit", queue, count, submits, fence);
}
VKAPI_ATTR VkResult VKAPI_CALL QueueSubmit2(VkQueue queue, uint32_t count, const VkSubmitInfo2* submits, VkFence fence) {
    FORWARD(queue, queueSubmit2, "vkQueueSubmit2", queue, count, submits, fence);
}
VKAPI_ATTR VkResult VKAPI_CALL QueueSubmit2KHR(VkQueue queue, uint32_t count, const VkSubmitInfo2* submits,
                                               VkFence fence) {
    FORWARD(queue, queueSubmit2KHR, "vkQueueSubmit2KHR", queue, count, submits, fence);
}
void rememberQueue(DeviceData* data, VkQueue queue) {
    if (!queue) return;
    std::lock_guard<std::mutex> lock(mutex);
    queues[queue] = data;
}
VKAPI_ATTR void VKAPI_CALL GetDeviceQueue(VkDevice device, uint32_t family, uint32_t index, VkQueue* queue) {
    DeviceData* data = deviceData(device);
    if (!data) {
        unknownDevice("getQueue");
        if (auto next = fallback<PFN_vkGetDeviceQueue>("vkGetDeviceQueue")) next(device, family, index, queue);
        return;
    }
    if (!data->getQueue) return;
    data->getQueue(device, family, index, queue);
    if (queue) TRACE("GetDeviceQueue device=%p key=%p -> queue=%p key=%p", static_cast<void*>(device), key(device),
                     static_cast<void*>(*queue), *queue ? key(*queue) : nullptr);
    if (queue) rememberQueue(data, *queue);
}
VKAPI_ATTR void VKAPI_CALL GetDeviceQueue2(VkDevice device, const VkDeviceQueueInfo2* info, VkQueue* queue) {
    DeviceData* data = deviceData(device);
    if (!data) {
        unknownDevice("getQueue2");
        if (auto next = fallback<PFN_vkGetDeviceQueue2>("vkGetDeviceQueue2")) next(device, info, queue);
        return;
    }
    if (!data->getQueue2) return;
    data->getQueue2(device, info, queue);
    if (queue) TRACE("GetDeviceQueue2 device=%p key=%p -> queue=%p key=%p", static_cast<void*>(device), key(device),
                     static_cast<void*>(*queue), *queue ? key(*queue) : nullptr);
    if (queue) rememberQueue(data, *queue);
}
VKAPI_ATTR VkResult VKAPI_CALL QueuePresentKHR(VkQueue queue, const VkPresentInfoKHR* info) {
    DeviceData* data = deviceData(queue);
    if (!data) {
        unknownDevice("queuePresent");
        auto next = fallback<PFN_vkQueuePresentKHR>("vkQueuePresentKHR");
        return next ? next(queue, info) : VK_ERROR_INITIALIZATION_FAILED;
    }
    if (!data->queuePresent) return VK_ERROR_INITIALIZATION_FAILED;
    if (lost(*data)) {
        if (info && info->pResults)
            for (uint32_t i = 0; i < info->swapchainCount; ++i) info->pResults[i] = VK_ERROR_DEVICE_LOST;
        return VK_ERROR_DEVICE_LOST;
    }
    return data->queuePresent(queue, info);
}
VKAPI_ATTR VkResult VKAPI_CALL AcquireNextImageKHR(VkDevice device, VkSwapchainKHR swapchain, uint64_t timeout,
                                                   VkSemaphore semaphore, VkFence fence, uint32_t* index) {
    FORWARD(device, acquire, "vkAcquireNextImageKHR", device, swapchain, timeout, semaphore, fence, index);
}
VKAPI_ATTR VkResult VKAPI_CALL AcquireNextImage2KHR(VkDevice device, const VkAcquireNextImageInfoKHR* info,
                                                    uint32_t* index) {
    FORWARD(device, acquire2, "vkAcquireNextImage2KHR", device, info, index);
}
VKAPI_ATTR VkResult VKAPI_CALL WaitForFences(VkDevice device, uint32_t count, const VkFence* fences, VkBool32 all,
                                             uint64_t timeout) {
    FORWARD(device, waitForFences, "vkWaitForFences", device, count, fences, all, timeout);
}
VKAPI_ATTR VkResult VKAPI_CALL GetFenceStatus(VkDevice device, VkFence fence) {
    FORWARD(device, fenceStatus, "vkGetFenceStatus", device, fence);
}
VKAPI_ATTR VkResult VKAPI_CALL WaitSemaphores(VkDevice device, const VkSemaphoreWaitInfo* info, uint64_t timeout) {
    FORWARD(device, waitSemaphores, "vkWaitSemaphores", device, info, timeout);
}
VKAPI_ATTR VkResult VKAPI_CALL WaitSemaphoresKHR(VkDevice device, const VkSemaphoreWaitInfo* info, uint64_t timeout) {
    FORWARD(device, waitSemaphoresKHR, "vkWaitSemaphoresKHR", device, info, timeout);
}
VKAPI_ATTR VkResult VKAPI_CALL DeviceWaitIdle(VkDevice device) { FORWARD(device, deviceWaitIdle, "vkDeviceWaitIdle", device); }
VKAPI_ATTR VkResult VKAPI_CALL QueueWaitIdle(VkQueue queue) { FORWARD(queue, queueWaitIdle, "vkQueueWaitIdle", queue); }
#undef FORWARD

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL GetDeviceProcAddr(VkDevice device, const char* name);

PFN_vkVoidFunction deviceFunction(const char* name) {
#define ENTRY(fn) \
    if (!std::strcmp(name, "vk" #fn)) return reinterpret_cast<PFN_vkVoidFunction>(fn)
    ENTRY(GetDeviceProcAddr);
    ENTRY(DestroyDevice);
    ENTRY(GetDeviceQueue);
    ENTRY(GetDeviceQueue2);
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
    if (deviceFunction(name)) TRACE("GetDeviceProcAddr device=%p key=%p %s known=%d", static_cast<void*>(device),
                                    key(device), name, data != nullptr);
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
    if (PFN_vkVoidFunction own = deviceFunction(name)) {
        TRACE("GetInstanceProcAddr instance=%p %s", static_cast<void*>(instance), name);
        rememberFallback(name, next);
        return own;
    }
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
