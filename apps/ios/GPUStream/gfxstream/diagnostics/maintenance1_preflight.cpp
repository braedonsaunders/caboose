// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// Same-provider extension/feature/device-creation probe. No surface or presentation.
#define VK_USE_PLATFORM_METAL_EXT 1
#include <vulkan/vulkan.h>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <vector>

namespace {
bool contains(const std::vector<VkExtensionProperties>& entries, const char* name) {
    for (const auto& entry : entries) if (std::strcmp(entry.extensionName, name) == 0) return true;
    return false;
}
template <typename F> bool enumerate(F fn, std::vector<VkExtensionProperties>* out, const char* label) {
    uint32_t count = 0;
    VkResult r = fn(&count, nullptr);
    std::printf("%s_count_result=%d count=%u\n", label, r, count);
    if (r != VK_SUCCESS || count > 4096) return false;
    out->resize(count);
    if (!count) return true;
    r = fn(&count, out->data());
    std::printf("%s_values_result=%d count=%u\n", label, r, count);
    if (r != VK_SUCCESS || count > out->size()) return false;
    out->resize(count); return true;
}
}
int main(int argc, char** argv) {
    if (argc != 2) return 2;
    void* library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) { std::fprintf(stderr, "provider_open_failed: %s\n", dlerror()); return 1; }
    auto get = reinterpret_cast<PFN_vkGetInstanceProcAddr>(dlsym(library, "vkGetInstanceProcAddr"));
    if (!get) { std::fprintf(stderr, "provider_missing_get_instance_proc_addr\n"); return 1; }
    auto enumerateVersion = reinterpret_cast<PFN_vkEnumerateInstanceVersion>(get(VK_NULL_HANDLE, "vkEnumerateInstanceVersion"));
    auto enumerateInstance = reinterpret_cast<PFN_vkEnumerateInstanceExtensionProperties>(get(VK_NULL_HANDLE, "vkEnumerateInstanceExtensionProperties"));
    auto createInstance = reinterpret_cast<PFN_vkCreateInstance>(get(VK_NULL_HANDLE, "vkCreateInstance"));
    if (!enumerateVersion || !enumerateInstance || !createInstance) { std::puts("UNSUPPORTED missing Vulkan 1.1 entrypoints"); return 77; }
    uint32_t version = 0;
    VkResult r = enumerateVersion(&version);
    std::printf("instance_version_result=%d version=%u\n", r, version);
    if (r != VK_SUCCESS) return 1;
    if (version < VK_API_VERSION_1_1) { std::puts("UNSUPPORTED Vulkan 1.1"); return 77; }
    std::vector<VkExtensionProperties> instanceExtensions;
    if (!enumerate([&](uint32_t* c, VkExtensionProperties* p) { return enumerateInstance(nullptr, c, p); },
                   &instanceExtensions, "instance_extensions")) return 1;
    const char* required[] = {VK_KHR_SURFACE_EXTENSION_NAME, VK_EXT_METAL_SURFACE_EXTENSION_NAME,
                              VK_KHR_GET_SURFACE_CAPABILITIES_2_EXTENSION_NAME};
    for (auto* name : required) {
        std::printf("instance_extension %s=%d\n", name, contains(instanceExtensions, name));
        if (!contains(instanceExtensions, name)) { std::puts("UNSUPPORTED required instance extension"); return 77; }
    }
    const bool instanceKhr = contains(instanceExtensions, VK_KHR_SURFACE_MAINTENANCE_1_EXTENSION_NAME);
    const bool instanceExt = contains(instanceExtensions, VK_EXT_SURFACE_MAINTENANCE_1_EXTENSION_NAME);
    std::printf("instance_surface_maintenance_khr=%d ext=%d\n", instanceKhr, instanceExt);
    if (!instanceKhr && !instanceExt) { std::puts("UNSUPPORTED surface maintenance extension"); return 77; }
    std::vector<const char*> enabled(required, required + 3);
    if (instanceKhr) enabled.push_back(VK_KHR_SURFACE_MAINTENANCE_1_EXTENSION_NAME);
    if (instanceExt) enabled.push_back(VK_EXT_SURFACE_MAINTENANCE_1_EXTENSION_NAME);
    VkInstanceCreateFlags flags = 0;
    if (contains(instanceExtensions, VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)) {
        enabled.push_back(VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);
        flags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
    }
    VkApplicationInfo app{}; app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.pApplicationName = "Caboose maintenance1 preflight"; app.apiVersion = VK_API_VERSION_1_1;
    VkInstanceCreateInfo ci{}; ci.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    ci.flags = flags; ci.pApplicationInfo = &app; ci.enabledExtensionCount = static_cast<uint32_t>(enabled.size());
    ci.ppEnabledExtensionNames = enabled.data();
    VkInstance instance = VK_NULL_HANDLE;
    r = createInstance(&ci, nullptr, &instance);
    std::printf("create_instance_result=%d\n", r);
    if (r != VK_SUCCESS) return 1;
    auto destroyInstance = reinterpret_cast<PFN_vkDestroyInstance>(get(instance, "vkDestroyInstance"));
    auto physicals = reinterpret_cast<PFN_vkEnumeratePhysicalDevices>(get(instance, "vkEnumeratePhysicalDevices"));
    auto properties = reinterpret_cast<PFN_vkGetPhysicalDeviceProperties>(get(instance, "vkGetPhysicalDeviceProperties"));
    auto deviceExtensions = reinterpret_cast<PFN_vkEnumerateDeviceExtensionProperties>(get(instance, "vkEnumerateDeviceExtensionProperties"));
    auto features = reinterpret_cast<PFN_vkGetPhysicalDeviceFeatures2>(get(instance, "vkGetPhysicalDeviceFeatures2"));
    auto queues = reinterpret_cast<PFN_vkGetPhysicalDeviceQueueFamilyProperties>(get(instance, "vkGetPhysicalDeviceQueueFamilyProperties"));
    auto createDevice = reinterpret_cast<PFN_vkCreateDevice>(get(instance, "vkCreateDevice"));
    auto getDevice = reinterpret_cast<PFN_vkGetDeviceProcAddr>(get(instance, "vkGetDeviceProcAddr"));
    if (!destroyInstance || !physicals || !properties || !deviceExtensions || !features || !queues || !createDevice || !getDevice) {
        std::puts("UNSUPPORTED missing instance/device entrypoints");
        if (destroyInstance) destroyInstance(instance, nullptr);
        return 77;
    }
    uint32_t count = 0;
    r = physicals(instance, &count, nullptr);
    std::printf("physical_count_result=%d count=%u\n", r, count);
    if (r != VK_SUCCESS || count > 256) { destroyInstance(instance, nullptr); return 1; }
    if (!count) { std::puts("UNSUPPORTED no physical device"); destroyInstance(instance, nullptr); return 77; }
    std::vector<VkPhysicalDevice> devices(count);
    r = physicals(instance, &count, devices.data());
    std::printf("physical_values_result=%d count=%u\n", r, count);
    if (r != VK_SUCCESS || count > devices.size()) { destroyInstance(instance, nullptr); return 1; }
    devices.resize(count);
    int outcome = 77;
    for (VkPhysicalDevice physical : devices) {
        VkPhysicalDeviceProperties props{}; properties(physical, &props);
        std::printf("physical_device=%s vendor=%u device=%u api=%u\n", props.deviceName, props.vendorID, props.deviceID, props.apiVersion);
        std::vector<VkExtensionProperties> supported;
        if (!enumerate([&](uint32_t* c, VkExtensionProperties* p) { return deviceExtensions(physical, nullptr, c, p); },
                       &supported, "device_extensions")) { outcome = 1; break; }
        const bool swapchain = contains(supported, VK_KHR_SWAPCHAIN_EXTENSION_NAME);
        const bool deviceKhr = contains(supported, VK_KHR_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME);
        const bool deviceExt = contains(supported, VK_EXT_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME);
        std::printf("device_swapchain=%d maintenance_khr=%d maintenance_ext=%d\n", swapchain, deviceKhr, deviceExt);
        const char* chosen = instanceKhr && deviceKhr ? VK_KHR_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME :
                             instanceExt && deviceExt ? VK_EXT_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME : nullptr;
        if (!swapchain || !chosen) continue;
        VkPhysicalDeviceSwapchainMaintenance1FeaturesKHR maintenance{};
        maintenance.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SWAPCHAIN_MAINTENANCE_1_FEATURES_KHR;
        VkPhysicalDeviceFeatures2 queried{}; queried.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2; queried.pNext = &maintenance;
        features(physical, &queried);
        std::printf("swapchain_maintenance1_feature=%u selected=%s\n", maintenance.swapchainMaintenance1, chosen);
        if (!maintenance.swapchainMaintenance1) continue;
        uint32_t familyCount = 0; queues(physical, &familyCount, nullptr);
        if (!familyCount || familyCount > 4096) continue;
        std::vector<VkQueueFamilyProperties> families(familyCount); queues(physical, &familyCount, families.data());
        uint32_t family = 0;
        while (family < familyCount && !families[family].queueCount) ++family;
        if (family == familyCount) continue;
        float priority = 1;
        VkDeviceQueueCreateInfo qi{}; qi.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
        qi.queueFamilyIndex = family; qi.queueCount = 1; qi.pQueuePriorities = &priority;
        const char* names[] = {VK_KHR_SWAPCHAIN_EXTENSION_NAME, chosen, "VK_KHR_portability_subset"};
        uint32_t nameCount = contains(supported, names[2]) ? 3 : 2;
        maintenance.pNext = nullptr; maintenance.swapchainMaintenance1 = VK_TRUE;
        VkDeviceCreateInfo di{}; di.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
        di.pNext = &maintenance; di.queueCreateInfoCount = 1; di.pQueueCreateInfos = &qi;
        di.enabledExtensionCount = nameCount; di.ppEnabledExtensionNames = names;
        VkDevice device = VK_NULL_HANDLE; r = createDevice(physical, &di, nullptr, &device);
        std::printf("create_device_result=%d queue_family=%u\n", r, family);
        if (r != VK_SUCCESS) { outcome = 1; break; }
        auto destroyDevice = reinterpret_cast<PFN_vkDestroyDevice>(getDevice(device, "vkDestroyDevice"));
        const char* releaseName = std::strcmp(chosen, VK_KHR_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME) == 0 ?
            "vkReleaseSwapchainImagesKHR" : "vkReleaseSwapchainImagesEXT";
        auto release = getDevice(device, releaseName);
        std::printf("enabled_device=%s release_entrypoint=%d\n", chosen, release != nullptr);
        if (!destroyDevice) { std::puts("device_destroy_entrypoint_missing"); return 1; }
        destroyDevice(device, nullptr);
        outcome = release ? 0 : 1;
        break;
    }
    destroyInstance(instance, nullptr);
    if (outcome == 77) std::puts("UNSUPPORTED no matching physical extension/feature/queue");
    else if (!outcome) std::puts("PASS real device enabled maintenance1 (no surface/presentation)");
    return outcome;
}
