// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
//
// VK_LAYER_CABOOSE_gpu_routing (README.md): lists the phone's GPU first among physical
// devices, so applications that take the first device render on it, and hides it from
// Steam's pipeline pre-compiler.
#include <vulkan/vk_layer.h>
#include <vulkan/vulkan.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "routing.h"

namespace {

using namespace caboose_routing;

void* key(const void* dispatchable) { return *static_cast<void* const*>(dispatchable); }

struct InstanceData {
    PFN_vkGetInstanceProcAddr next = nullptr;
    PFN_vkDestroyInstance destroy = nullptr;
    PFN_vkEnumeratePhysicalDevices enumerate = nullptr;
    PFN_vkEnumeratePhysicalDeviceGroups groups = nullptr;
    PFN_vkEnumeratePhysicalDeviceGroups groupsKHR = nullptr;
    PFN_vkGetPhysicalDeviceProperties properties = nullptr;
    PFN_vkGetPhysicalDeviceProperties2 properties2 = nullptr;
    PFN_vkGetPhysicalDeviceProperties2 properties2KHR = nullptr;
    PFN_vkCreateDevice createDevice = nullptr;
};

struct DeviceData {
    PFN_vkGetDeviceProcAddr next = nullptr;
    PFN_vkDestroyDevice destroy = nullptr;
};

std::mutex mutex;
std::unordered_map<void*, std::unique_ptr<InstanceData>> instances;
std::unordered_map<void*, std::unique_ptr<DeviceData>> devices;
// CPU implementations presented as GPUs (kNoPhoneName): physical devices are never destroyed
// before their instance, and a handle once presented stays presented, as apps decided on it.
std::unordered_set<VkPhysicalDevice> presented;

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

std::string commandLine() {
    std::ifstream file("/proc/self/cmdline", std::ios::binary);
    std::string text((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
    for (char& c : text)
        if (c == '\0') c = ' ';
    return text;
}

template <class Info>
VkLayerInstanceCreateInfo* instanceLink(const Info* info) {
    for (auto* next = static_cast<const VkBaseInStructure*>(info->pNext); next; next = next->pNext) {
        if (next->sType != VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO) continue;
        auto* link = reinterpret_cast<const VkLayerInstanceCreateInfo*>(next);
        if (link->function == VK_LAYER_LINK_INFO) return const_cast<VkLayerInstanceCreateInfo*>(link);
    }
    return nullptr;
}
VkLayerDeviceCreateInfo* deviceLink(const VkDeviceCreateInfo* info) {
    for (auto* next = static_cast<const VkBaseInStructure*>(info->pNext); next; next = next->pNext) {
        if (next->sType != VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO) continue;
        auto* link = reinterpret_cast<const VkLayerDeviceCreateInfo*>(next);
        if (link->function == VK_LAYER_LINK_INFO) return const_cast<VkLayerDeviceCreateInfo*>(link);
    }
    return nullptr;
}

VKAPI_ATTR VkResult VKAPI_CALL CreateInstance(const VkInstanceCreateInfo* info, const VkAllocationCallbacks* allocator,
                                              VkInstance* instance) {
    auto* link = instanceLink(info);
    if (!link || !link->u.pLayerInfo) return VK_ERROR_INITIALIZATION_FAILED;
    PFN_vkGetInstanceProcAddr next = link->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    link->u.pLayerInfo = link->u.pLayerInfo->pNext;
    auto create = reinterpret_cast<PFN_vkCreateInstance>(next(VK_NULL_HANDLE, "vkCreateInstance"));
    if (!create) return VK_ERROR_INITIALIZATION_FAILED;
    VkResult result = create(info, allocator, instance);
    if (result != VK_SUCCESS) return result;
    auto data = std::make_unique<InstanceData>();
    data->next = next;
    auto load = [&](const char* name) { return next(*instance, name); };
    data->destroy = reinterpret_cast<PFN_vkDestroyInstance>(load("vkDestroyInstance"));
    data->enumerate = reinterpret_cast<PFN_vkEnumeratePhysicalDevices>(load("vkEnumeratePhysicalDevices"));
    data->groups = reinterpret_cast<PFN_vkEnumeratePhysicalDeviceGroups>(load("vkEnumeratePhysicalDeviceGroups"));
    data->groupsKHR = reinterpret_cast<PFN_vkEnumeratePhysicalDeviceGroups>(load("vkEnumeratePhysicalDeviceGroupsKHR"));
    data->properties = reinterpret_cast<PFN_vkGetPhysicalDeviceProperties>(load("vkGetPhysicalDeviceProperties"));
    data->properties2 = reinterpret_cast<PFN_vkGetPhysicalDeviceProperties2>(load("vkGetPhysicalDeviceProperties2"));
    data->properties2KHR = reinterpret_cast<PFN_vkGetPhysicalDeviceProperties2>(load("vkGetPhysicalDeviceProperties2KHR"));
    data->createDevice = reinterpret_cast<PFN_vkCreateDevice>(load("vkCreateDevice"));
    std::lock_guard<std::mutex> lock(mutex);
    instances[key(*instance)] = std::move(data);
    return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL DestroyInstance(VkInstance instance, const VkAllocationCallbacks* allocator) {
    InstanceData* data = instanceData(instance);
    if (!data) return;
    PFN_vkDestroyInstance destroy = data->destroy;
    {
        std::lock_guard<std::mutex> lock(mutex);
        instances.erase(key(instance));
    }
    destroy(instance, allocator);
}

bool processHidesPhone() {
    static const bool hides = hidesPhone(commandLine());
    return hides;
}

int deviceRank(InstanceData& data, VkPhysicalDevice device) {
    VkPhysicalDeviceProperties properties{};
    data.properties(device, &properties);
    if (properties.vendorID == kPhoneVendor && processHidesPhone()) return kHidden;
    return rank(properties.vendorID, properties.deviceType);
}

// Records the CPU implementations among `devices` to present as GPUs, judged against every
// device listed (`listed`, default `ranks`).
void present(const VkPhysicalDevice* devices, const std::vector<int>& ranks, const std::vector<int>& listed) {
    if (!presentsCpuAsGpu(listed, processHidesPhone())) return;
    std::lock_guard<std::mutex> lock(mutex);
    for (size_t i = 0; i < ranks.size(); ++i)
        if (ranks[i] == rank(0, kCpu)) presented.insert(devices[i]);
}
void present(const VkPhysicalDevice* devices, const std::vector<int>& ranks) { present(devices, ranks, ranks); }

bool isPresented(VkPhysicalDevice device) {
    std::lock_guard<std::mutex> lock(mutex);
    return presented.count(device) != 0;
}

constexpr VkDriverId kNoPhoneDriverID = VK_DRIVER_ID_MESA_GFXSTREAM;

void presentAsGpu(VkPhysicalDeviceProperties& properties) {
    properties.deviceType = VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU;
    std::snprintf(properties.deviceName, sizeof(properties.deviceName), "%s", kNoPhoneName);
}

VKAPI_ATTR void VKAPI_CALL GetPhysicalDeviceProperties(VkPhysicalDevice device, VkPhysicalDeviceProperties* out) {
    InstanceData* data = instanceData(device);
    if (!data || !data->properties) return;
    data->properties(device, out);
    if (out && isPresented(device)) presentAsGpu(*out);
}
// The driver's name and ID too: renderer strings carry the name (ANGLE's, so Chromium's), and
// Steam judges its web views' GPU acceleration by the ID (lavapipe's turns it off for good).
// The ID is gfxstream's, which Zink keys no workarounds on; it then treats lavapipe as an
// ordinary GPU (no lavapipe-specific optimisations, and signed vertex-buffer offsets offered
// where device-address commands are).
void properties2(PFN_vkGetPhysicalDeviceProperties2 next, VkPhysicalDevice device, VkPhysicalDeviceProperties2* out) {
    if (!next) return;
    next(device, out);
    if (!out || !isPresented(device)) return;
    presentAsGpu(out->properties);
    for (auto* item = static_cast<VkBaseOutStructure*>(out->pNext); item; item = item->pNext) {
        if (item->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES) {
            auto* driver = reinterpret_cast<VkPhysicalDeviceDriverProperties*>(item);
            std::snprintf(driver->driverName, VK_MAX_DRIVER_NAME_SIZE, "%s", kNoPhoneDriverName);
            driver->driverID = kNoPhoneDriverID;
        }
        if (item->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_PROPERTIES) {
            auto* v12 = reinterpret_cast<VkPhysicalDeviceVulkan12Properties*>(item);
            std::snprintf(v12->driverName, VK_MAX_DRIVER_NAME_SIZE, "%s", kNoPhoneDriverName);
            v12->driverID = kNoPhoneDriverID;
        }
    }
}
VKAPI_ATTR void VKAPI_CALL GetPhysicalDeviceProperties2(VkPhysicalDevice device, VkPhysicalDeviceProperties2* out) {
    InstanceData* data = instanceData(device);
    if (data) properties2(data->properties2, device, out);
}
VKAPI_ATTR void VKAPI_CALL GetPhysicalDeviceProperties2KHR(VkPhysicalDevice device, VkPhysicalDeviceProperties2* out) {
    InstanceData* data = instanceData(device);
    if (data) properties2(data->properties2KHR ? data->properties2KHR : data->properties2, device, out);
}

// Drops the hidden devices from `all` and their ranks.
template <class T>
void dropHidden(std::vector<T>& all, std::vector<int>& ranks) {
    size_t kept = 0;
    for (size_t i = 0; i < all.size(); ++i) {
        if (ranks[i] == kHidden) continue;
        all[kept] = all[i];
        ranks[kept++] = ranks[i];
    }
    all.resize(kept);
    ranks.resize(kept);
}

// Copies `all` in routing order into the caller's array, with the enumeration contract.
template <class T>
VkResult answer(std::vector<T>& all, const std::vector<int>& ranks, uint32_t* count, T* out) {
    if (!out) {
        *count = static_cast<uint32_t>(all.size());
        return VK_SUCCESS;
    }
    auto indexes = order(ranks);
    uint32_t copied = std::min<uint32_t>(*count, static_cast<uint32_t>(all.size()));
    for (uint32_t i = 0; i < copied; ++i) out[i] = all[indexes[i]];
    *count = copied;
    return copied < all.size() ? VK_INCOMPLETE : VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL EnumeratePhysicalDevices(VkInstance instance, uint32_t* count, VkPhysicalDevice* out) {
    InstanceData* data = instanceData(instance);
    if (!data) return VK_ERROR_INITIALIZATION_FAILED;
    uint32_t total = 0;
    VkResult result = data->enumerate(instance, &total, nullptr);
    if (result != VK_SUCCESS) return result;
    std::vector<VkPhysicalDevice> all(total);
    result = data->enumerate(instance, &total, all.data());
    if (result != VK_SUCCESS && result != VK_INCOMPLETE) return result;
    all.resize(total);
    std::vector<int> ranks;
    for (auto device : all) ranks.push_back(deviceRank(*data, device));
    present(all.data(), ranks);
    hideCpuBesidePhone(ranks);
    dropHidden(all, ranks);
    return answer(all, ranks, count, out);
}

VkResult enumerateGroups(PFN_vkEnumeratePhysicalDeviceGroups next, InstanceData& data, VkInstance instance,
                         uint32_t* count, VkPhysicalDeviceGroupProperties* out) {
    if (!next) return VK_ERROR_INITIALIZATION_FAILED;
    uint32_t total = 0;
    VkResult result = next(instance, &total, nullptr);
    if (result != VK_SUCCESS) return result;
    std::vector<VkPhysicalDeviceGroupProperties> all(total);
    for (auto& group : all) group.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_GROUP_PROPERTIES;
    result = next(instance, &total, all.data());
    if (result != VK_SUCCESS && result != VK_INCOMPLETE) return result;
    all.resize(total);
    std::vector<int> ranks;
    for (auto& group : all) ranks.push_back(group.physicalDeviceCount ? deviceRank(data, group.physicalDevices[0]) : 5);
    for (size_t i = 0; i < all.size(); ++i)
        if (all[i].physicalDeviceCount) present(&all[i].physicalDevices[0], {ranks[i]}, ranks);
    hideCpuBesidePhone(ranks);
    dropHidden(all, ranks);
    total = static_cast<uint32_t>(all.size());
    if (!out) {
        *count = total;
        return VK_SUCCESS;
    }
    // The caller's structures keep their own pNext chains.
    auto indexes = order(ranks);
    uint32_t copied = std::min(*count, total);
    for (uint32_t i = 0; i < copied; ++i) {
        void* chain = out[i].pNext;
        out[i] = all[indexes[i]];
        out[i].pNext = chain;
    }
    *count = copied;
    return copied < total ? VK_INCOMPLETE : VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL EnumeratePhysicalDeviceGroups(VkInstance instance, uint32_t* count,
                                                             VkPhysicalDeviceGroupProperties* out) {
    InstanceData* data = instanceData(instance);
    return data ? enumerateGroups(data->groups, *data, instance, count, out) : VK_ERROR_INITIALIZATION_FAILED;
}
VKAPI_ATTR VkResult VKAPI_CALL EnumeratePhysicalDeviceGroupsKHR(VkInstance instance, uint32_t* count,
                                                                VkPhysicalDeviceGroupProperties* out) {
    InstanceData* data = instanceData(instance);
    return data ? enumerateGroups(data->groupsKHR, *data, instance, count, out) : VK_ERROR_INITIALIZATION_FAILED;
}

VKAPI_ATTR VkResult VKAPI_CALL CreateDevice(VkPhysicalDevice physical, const VkDeviceCreateInfo* info,
                                            const VkAllocationCallbacks* allocator, VkDevice* device) {
    InstanceData* instance = instanceData(physical);
    auto* link = deviceLink(info);
    if (!instance || !link || !link->u.pLayerInfo) return VK_ERROR_INITIALIZATION_FAILED;
    PFN_vkGetDeviceProcAddr next = link->u.pLayerInfo->pfnNextGetDeviceProcAddr;
    link->u.pLayerInfo = link->u.pLayerInfo->pNext;
    VkResult result = instance->createDevice(physical, info, allocator, device);
    if (result != VK_SUCCESS) return result;
    auto data = std::make_unique<DeviceData>();
    data->next = next;
    data->destroy = reinterpret_cast<PFN_vkDestroyDevice>(next(*device, "vkDestroyDevice"));
    std::lock_guard<std::mutex> lock(mutex);
    devices[key(*device)] = std::move(data);
    return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL DestroyDevice(VkDevice device, const VkAllocationCallbacks* allocator) {
    DeviceData* data = deviceData(device);
    if (!data) return;
    PFN_vkDestroyDevice destroy = data->destroy;
    {
        std::lock_guard<std::mutex> lock(mutex);
        devices.erase(key(device));
    }
    destroy(device, allocator);
}

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL GetInstanceProcAddr(VkInstance instance, const char* name);
VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL GetDeviceProcAddr(VkDevice device, const char* name);

PFN_vkVoidFunction own(const char* name) {
#define ENTRY(f) \
    if (!std::strcmp(name, "vk" #f)) return reinterpret_cast<PFN_vkVoidFunction>(f)
    ENTRY(GetInstanceProcAddr);
    ENTRY(GetDeviceProcAddr);
    ENTRY(CreateInstance);
    ENTRY(DestroyInstance);
    ENTRY(EnumeratePhysicalDevices);
    ENTRY(EnumeratePhysicalDeviceGroups);
    ENTRY(EnumeratePhysicalDeviceGroupsKHR);
    ENTRY(GetPhysicalDeviceProperties);
    ENTRY(GetPhysicalDeviceProperties2);
    ENTRY(GetPhysicalDeviceProperties2KHR);
    ENTRY(CreateDevice);
    ENTRY(DestroyDevice);
#undef ENTRY
    return nullptr;
}

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL GetInstanceProcAddr(VkInstance instance, const char* name) {
    if (PFN_vkVoidFunction function = own(name)) return function;
    InstanceData* data = instance ? instanceData(instance) : nullptr;
    return data ? data->next(instance, name) : nullptr;
}

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL GetDeviceProcAddr(VkDevice device, const char* name) {
    if (!std::strcmp(name, "vkGetDeviceProcAddr")) return reinterpret_cast<PFN_vkVoidFunction>(GetDeviceProcAddr);
    if (!std::strcmp(name, "vkDestroyDevice")) return reinterpret_cast<PFN_vkVoidFunction>(DestroyDevice);
    DeviceData* data = deviceData(device);
    return data ? data->next(device, name) : nullptr;
}

}  // namespace

extern "C" {
__attribute__((visibility("default"))) VKAPI_ATTR VkResult VKAPI_CALL
vkNegotiateLoaderLayerInterfaceVersion(VkNegotiateLayerInterface* interface) {
    if (!interface || interface->sType != LAYER_NEGOTIATE_INTERFACE_STRUCT) return VK_ERROR_INITIALIZATION_FAILED;
    if (interface->loaderLayerInterfaceVersion > 2) interface->loaderLayerInterfaceVersion = 2;
    interface->pfnGetInstanceProcAddr = GetInstanceProcAddr;
    interface->pfnGetDeviceProcAddr = GetDeviceProcAddr;
    interface->pfnGetPhysicalDeviceProcAddr = nullptr;
    return VK_SUCCESS;
}
}
