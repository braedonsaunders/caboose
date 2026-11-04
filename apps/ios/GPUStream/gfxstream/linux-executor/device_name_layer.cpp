// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// An implicit Vulkan layer for the Linux executor only: it reports the device's name as
// CABOOSE_EXECUTOR_DEVICE_NAME. Lavapipe's own name ("llvmpipe (LLVM ...)") reaches the
// guest's GL renderer string through Zink, and Chromium's software rendering list disables
// GPU acceleration for any renderer naming llvmpipe, so CEF and Chromium on a seat served by
// this executor would fall back to software rendering, unlike on the phone (README.md).
#include <vulkan/vk_layer.h>
#include <vulkan/vulkan.h>

#include <cstdlib>
#include <cstring>
#include <mutex>
#include <unordered_map>

namespace {

struct InstanceTable {
    PFN_vkGetInstanceProcAddr next = nullptr;
    PFN_vkDestroyInstance destroy = nullptr;
    PFN_vkEnumeratePhysicalDevices enumerate = nullptr;
    PFN_vkGetPhysicalDeviceProperties properties = nullptr;
    PFN_vkGetPhysicalDeviceProperties2 properties2 = nullptr;
    PFN_vkGetPhysicalDeviceProperties2 properties2Khr = nullptr;
};

std::mutex lock;
std::unordered_map<VkInstance, InstanceTable> instances;
std::unordered_map<VkPhysicalDevice, VkInstance> devices;
// Devices pass through: each device's next vkGetDeviceProcAddr.
std::unordered_map<VkDevice, PFN_vkGetDeviceProcAddr> logical;

InstanceTable* tableOf(VkPhysicalDevice device) {
    std::lock_guard<std::mutex> guard(lock);
    auto owner = devices.find(device);
    if (owner == devices.end()) return nullptr;
    auto table = instances.find(owner->second);
    return table == instances.end() ? nullptr : &table->second;
}

void rename(VkPhysicalDeviceProperties* properties) {
    const char* name = std::getenv("CABOOSE_EXECUTOR_DEVICE_NAME");
    if (!properties || !name || !*name) return;
    std::strncpy(properties->deviceName, name, VK_MAX_PHYSICAL_DEVICE_NAME_SIZE - 1);
    properties->deviceName[VK_MAX_PHYSICAL_DEVICE_NAME_SIZE - 1] = '\0';
}

VKAPI_ATTR void VKAPI_CALL GetPhysicalDeviceProperties(VkPhysicalDevice device, VkPhysicalDeviceProperties* out) {
    if (auto* table = tableOf(device); table && table->properties) table->properties(device, out);
    rename(out);
}

VKAPI_ATTR void VKAPI_CALL GetPhysicalDeviceProperties2(VkPhysicalDevice device, VkPhysicalDeviceProperties2* out) {
    auto* table = tableOf(device);
    if (table && table->properties2) table->properties2(device, out);
    else if (table && table->properties2Khr) table->properties2Khr(device, out);
    if (out) rename(&out->properties);
}

VKAPI_ATTR VkResult VKAPI_CALL EnumeratePhysicalDevices(VkInstance instance, uint32_t* count, VkPhysicalDevice* out) {
    PFN_vkEnumeratePhysicalDevices next;
    {
        std::lock_guard<std::mutex> guard(lock);
        next = instances[instance].enumerate;
    }
    const VkResult result = next(instance, count, out);
    if (out && (result == VK_SUCCESS || result == VK_INCOMPLETE)) {
        std::lock_guard<std::mutex> guard(lock);
        for (uint32_t i = 0; i < *count; ++i) devices[out[i]] = instance;
    }
    return result;
}

VKAPI_ATTR void VKAPI_CALL DestroyInstance(VkInstance instance, const VkAllocationCallbacks* allocator) {
    PFN_vkDestroyInstance next = nullptr;
    {
        std::lock_guard<std::mutex> guard(lock);
        auto found = instances.find(instance);
        if (found != instances.end()) next = found->second.destroy;
        for (auto it = devices.begin(); it != devices.end();) it = it->second == instance ? devices.erase(it) : std::next(it);
        instances.erase(instance);
    }
    if (next) next(instance, allocator);
}

VKAPI_ATTR VkResult VKAPI_CALL CreateInstance(const VkInstanceCreateInfo* info, const VkAllocationCallbacks* allocator,
                                              VkInstance* instance) {
    auto* chain = static_cast<VkLayerInstanceCreateInfo*>(const_cast<void*>(info->pNext));
    while (chain && !(chain->sType == VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO && chain->function == VK_LAYER_LINK_INFO))
        chain = static_cast<VkLayerInstanceCreateInfo*>(const_cast<void*>(chain->pNext));
    if (!chain) return VK_ERROR_INITIALIZATION_FAILED;
    const PFN_vkGetInstanceProcAddr next = chain->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    chain->u.pLayerInfo = chain->u.pLayerInfo->pNext;
    auto create = reinterpret_cast<PFN_vkCreateInstance>(next(VK_NULL_HANDLE, "vkCreateInstance"));
    const VkResult result = create(info, allocator, instance);
    if (result != VK_SUCCESS) return result;
    InstanceTable table;
    table.next = next;
    table.destroy = reinterpret_cast<PFN_vkDestroyInstance>(next(*instance, "vkDestroyInstance"));
    table.enumerate = reinterpret_cast<PFN_vkEnumeratePhysicalDevices>(next(*instance, "vkEnumeratePhysicalDevices"));
    table.properties = reinterpret_cast<PFN_vkGetPhysicalDeviceProperties>(next(*instance, "vkGetPhysicalDeviceProperties"));
    table.properties2 = reinterpret_cast<PFN_vkGetPhysicalDeviceProperties2>(next(*instance, "vkGetPhysicalDeviceProperties2"));
    table.properties2Khr = reinterpret_cast<PFN_vkGetPhysicalDeviceProperties2>(next(*instance, "vkGetPhysicalDeviceProperties2KHR"));
    std::lock_guard<std::mutex> guard(lock);
    instances[*instance] = table;
    return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL CreateDevice(VkPhysicalDevice physical, const VkDeviceCreateInfo* info,
                                            const VkAllocationCallbacks* allocator, VkDevice* device) {
    auto* chain = static_cast<VkLayerDeviceCreateInfo*>(const_cast<void*>(info->pNext));
    while (chain && !(chain->sType == VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO && chain->function == VK_LAYER_LINK_INFO))
        chain = static_cast<VkLayerDeviceCreateInfo*>(const_cast<void*>(chain->pNext));
    if (!chain) return VK_ERROR_INITIALIZATION_FAILED;
    const PFN_vkGetInstanceProcAddr nextInstance = chain->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    const PFN_vkGetDeviceProcAddr nextDevice = chain->u.pLayerInfo->pfnNextGetDeviceProcAddr;
    chain->u.pLayerInfo = chain->u.pLayerInfo->pNext;
    VkInstance instance = VK_NULL_HANDLE;
    {
        std::lock_guard<std::mutex> guard(lock);
        auto owner = devices.find(physical);
        if (owner != devices.end()) instance = owner->second;
    }
    auto create = reinterpret_cast<PFN_vkCreateDevice>(nextInstance(instance, "vkCreateDevice"));
    if (!create) return VK_ERROR_INITIALIZATION_FAILED;
    const VkResult result = create(physical, info, allocator, device);
    if (result == VK_SUCCESS) {
        std::lock_guard<std::mutex> guard(lock);
        logical[*device] = nextDevice;
    }
    return result;
}

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL GetDeviceProcAddr(VkDevice device, const char* name) {
    PFN_vkGetDeviceProcAddr next = nullptr;
    {
        std::lock_guard<std::mutex> guard(lock);
        auto found = logical.find(device);
        if (found != logical.end()) next = found->second;
    }
    return next ? next(device, name) : nullptr;
}

}  // namespace

extern "C" VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL caboose_device_name_GetInstanceProcAddr(VkInstance instance, const char* name) {
    if (!std::strcmp(name, "vkGetInstanceProcAddr")) return reinterpret_cast<PFN_vkVoidFunction>(caboose_device_name_GetInstanceProcAddr);
    if (!std::strcmp(name, "vkCreateInstance")) return reinterpret_cast<PFN_vkVoidFunction>(CreateInstance);
    if (!std::strcmp(name, "vkCreateDevice")) return reinterpret_cast<PFN_vkVoidFunction>(CreateDevice);
    if (!std::strcmp(name, "vkGetDeviceProcAddr")) return reinterpret_cast<PFN_vkVoidFunction>(GetDeviceProcAddr);
    if (!std::strcmp(name, "vkDestroyInstance")) return reinterpret_cast<PFN_vkVoidFunction>(DestroyInstance);
    if (!std::strcmp(name, "vkEnumeratePhysicalDevices")) return reinterpret_cast<PFN_vkVoidFunction>(EnumeratePhysicalDevices);
    if (!std::strcmp(name, "vkGetPhysicalDeviceProperties")) return reinterpret_cast<PFN_vkVoidFunction>(GetPhysicalDeviceProperties);
    if (!std::strcmp(name, "vkGetPhysicalDeviceProperties2") || !std::strcmp(name, "vkGetPhysicalDeviceProperties2KHR"))
        return reinterpret_cast<PFN_vkVoidFunction>(GetPhysicalDeviceProperties2);
    if (!instance) return nullptr;
    PFN_vkGetInstanceProcAddr next;
    {
        std::lock_guard<std::mutex> guard(lock);
        auto found = instances.find(instance);
        if (found == instances.end()) return nullptr;
        next = found->second.next;
    }
    return next(instance, name);
}

extern "C" VKAPI_ATTR VkResult VKAPI_CALL caboose_device_name_NegotiateLoaderLayerInterfaceVersion(VkNegotiateLayerInterface* version) {
    if (!version || version->sType != LAYER_NEGOTIATE_INTERFACE_STRUCT) return VK_ERROR_INITIALIZATION_FAILED;
    if (version->loaderLayerInterfaceVersion > 2) version->loaderLayerInterfaceVersion = 2;
    version->pfnGetInstanceProcAddr = caboose_device_name_GetInstanceProcAddr;
    version->pfnGetDeviceProcAddr = GetDeviceProcAddr;
    version->pfnGetPhysicalDeviceProcAddr = nullptr;
    return VK_SUCCESS;
}
