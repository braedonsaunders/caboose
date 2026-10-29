// MoltenVK's entry points with its unlocked process-wide initialization serialized; see moltenvk.h.
#include "moltenvk.h"

#include <cstring>
#include <mutex>

// MoltenVK, linked into the same image.
extern "C" VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetInstanceProcAddr(VkInstance instance, const char* name);

extern "C" VKAPI_ATTR VkResult VKAPI_CALL vkCreateDevice(VkPhysicalDevice, const VkDeviceCreateInfo*, const VkAllocationCallbacks*, VkDevice*);
extern "C" VKAPI_ATTR void VKAPI_CALL vkDestroyDevice(VkDevice, const VkAllocationCallbacks*);
extern "C" VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetDeviceProcAddr(VkDevice, const char*);

namespace caboose::gpu_stream {
namespace {

// Held for instance and device lifecycle calls that access process-wide state.
std::mutex instance_calls;

// Every MoltenVK call reads its configuration first, loading it from the environment the first
// time without a lock: the first call is made once, before any other through this file.
void InitializeOnce()
{
    static std::once_flag once;
    std::call_once(once, [] { vkGetInstanceProcAddr(VK_NULL_HANDLE, "vkGetInstanceProcAddr"); });
}

template <typename Function>
Function Global(const char* name)
{
    return reinterpret_cast<Function>(vkGetInstanceProcAddr(VK_NULL_HANDLE, name));
}

VKAPI_ATTR VkResult VKAPI_CALL CreateInstance(const VkInstanceCreateInfo*  create_info,
                                              const VkAllocationCallbacks* allocator,
                                              VkInstance*                  instance)
{
    static const auto create = Global<PFN_vkCreateInstance>("vkCreateInstance");
    std::lock_guard<std::mutex> lock(instance_calls);
    return create(create_info, allocator, instance);
}

VKAPI_ATTR void VKAPI_CALL DestroyInstance(VkInstance instance, const VkAllocationCallbacks* allocator)
{
    if (instance == VK_NULL_HANDLE)
    {
        return;
    }
    auto destroy = reinterpret_cast<PFN_vkDestroyInstance>(vkGetInstanceProcAddr(instance, "vkDestroyInstance"));
    std::lock_guard<std::mutex> lock(instance_calls);
    destroy(instance, allocator);
}

VKAPI_ATTR VkResult VKAPI_CALL EnumerateInstanceExtensionProperties(const char*            layer,
                                                                    uint32_t*              count,
                                                                    VkExtensionProperties* properties)
{
    static const auto enumerate =
        Global<PFN_vkEnumerateInstanceExtensionProperties>("vkEnumerateInstanceExtensionProperties");
    std::lock_guard<std::mutex> lock(instance_calls);
    return enumerate(layer, count, properties);
}

VKAPI_ATTR VkResult VKAPI_CALL EnumerateInstanceLayerProperties(uint32_t* count, VkLayerProperties* properties)
{
    static const auto enumerate = Global<PFN_vkEnumerateInstanceLayerProperties>("vkEnumerateInstanceLayerProperties");
    std::lock_guard<std::mutex> lock(instance_calls);
    return enumerate(count, properties);
}

VKAPI_ATTR VkResult VKAPI_CALL EnumerateInstanceVersion(uint32_t* version)
{
    static const auto enumerate = Global<PFN_vkEnumerateInstanceVersion>("vkEnumerateInstanceVersion");
    std::lock_guard<std::mutex> lock(instance_calls);
    return enumerate(version);
}

VKAPI_ATTR VkResult VKAPI_CALL CreateDevice(VkPhysicalDevice physical, const VkDeviceCreateInfo* info,
                                            const VkAllocationCallbacks* allocator, VkDevice* device)
{
    std::lock_guard<std::mutex> lock(instance_calls);
    return vkCreateDevice(physical, info, allocator, device);
}

VKAPI_ATTR void VKAPI_CALL DestroyDevice(VkDevice device, const VkAllocationCallbacks* allocator)
{
    std::lock_guard<std::mutex> lock(instance_calls);
    vkDestroyDevice(device, allocator);
}

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL GetDeviceProcAddr(VkDevice device, const char* name)
{
    if (name == nullptr) { return nullptr; }
    auto available = vkGetDeviceProcAddr(device, name);
    if (available == nullptr) { return nullptr; }
    if (std::strcmp(name, "vkDestroyDevice") == 0)
    {
        return reinterpret_cast<PFN_vkVoidFunction>(&DestroyDevice);
    }
    if (std::strcmp(name, "vkGetDeviceProcAddr") == 0)
    {
        return reinterpret_cast<PFN_vkVoidFunction>(&GetDeviceProcAddr);
    }
    return available;
}

} // namespace

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL GetInstanceProcAddr(VkInstance instance, const char* name)
{
    InitializeOnce();
    if (name == nullptr)
    {
        return nullptr;
    }
    const auto available = vkGetInstanceProcAddr(instance, name);
    if (available == nullptr)
    {
        return nullptr;
    }
    struct Serialized
    {
        const char*        name;
        PFN_vkVoidFunction function;
    };
    static const Serialized serialized[] = {
        { "vkGetInstanceProcAddr", reinterpret_cast<PFN_vkVoidFunction>(&GetInstanceProcAddr) },
        { "vkCreateDevice", reinterpret_cast<PFN_vkVoidFunction>(&CreateDevice) },
        { "vkDestroyDevice", reinterpret_cast<PFN_vkVoidFunction>(&DestroyDevice) },
        { "vkGetDeviceProcAddr", reinterpret_cast<PFN_vkVoidFunction>(&GetDeviceProcAddr) },
        { "vkCreateInstance", reinterpret_cast<PFN_vkVoidFunction>(&CreateInstance) },
        { "vkDestroyInstance", reinterpret_cast<PFN_vkVoidFunction>(&DestroyInstance) },
        { "vkEnumerateInstanceExtensionProperties",
          reinterpret_cast<PFN_vkVoidFunction>(&EnumerateInstanceExtensionProperties) },
        { "vkEnumerateInstanceLayerProperties", reinterpret_cast<PFN_vkVoidFunction>(&EnumerateInstanceLayerProperties) },
        { "vkEnumerateInstanceVersion", reinterpret_cast<PFN_vkVoidFunction>(&EnumerateInstanceVersion) },
    };
    for (const auto& entry : serialized)
    {
        if (std::strcmp(name, entry.name) == 0)
        {
            return entry.function;
        }
    }
    return available;
}

} // namespace caboose::gpu_stream
