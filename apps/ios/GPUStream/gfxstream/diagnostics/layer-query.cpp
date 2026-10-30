// SPDX-License-Identifier: Apache-2.0
// Direct real-provider layer-query regression; run each case in a fresh process.
#include <vulkan/vulkan.h>
#include <dlfcn.h>
#include <cstdio>
#include <cstring>
#include <vector>

int main(int argc, char** argv) {
    if (argc != 3 && argc != 4) {
        std::fprintf(stderr, "usage: layer-query PROVIDER_DYLIB null|empty|unknown|known [device]\n");
        return 2;
    }
    // Call this exact provider, not a loader that may normalize layer names.
    void* provider = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!provider) { std::fprintf(stderr, "provider load failed\n"); return 1; }
    const auto query = reinterpret_cast<PFN_vkEnumerateInstanceExtensionProperties>(
        dlsym(provider, "vkEnumerateInstanceExtensionProperties"));
    const auto layers = reinterpret_cast<PFN_vkEnumerateInstanceLayerProperties>(
        dlsym(provider, "vkEnumerateInstanceLayerProperties"));
    if (!query || !layers) { std::fprintf(stderr, "provider exports missing\n"); return 1; }
    const bool deviceQuery = argc == 4;
    if (deviceQuery && std::strcmp(argv[3], "device")) return 2;
    VkInstance instance = VK_NULL_HANDLE;
    VkPhysicalDevice physical = VK_NULL_HANDLE;
    PFN_vkDestroyInstance destroy = nullptr;
    PFN_vkEnumerateDeviceExtensionProperties deviceExtensions = nullptr;
    if (deviceQuery) {
        const auto create = reinterpret_cast<PFN_vkCreateInstance>(dlsym(provider, "vkCreateInstance"));
        const auto enumerate = reinterpret_cast<PFN_vkEnumeratePhysicalDevices>(dlsym(provider, "vkEnumeratePhysicalDevices"));
        destroy = reinterpret_cast<PFN_vkDestroyInstance>(dlsym(provider, "vkDestroyInstance"));
        deviceExtensions = reinterpret_cast<PFN_vkEnumerateDeviceExtensionProperties>(dlsym(provider, "vkEnumerateDeviceExtensionProperties"));
        if (!create || !enumerate || !destroy || !deviceExtensions) return 1;
        uint32_t extensionCount = 0;
        if (query(nullptr, &extensionCount, nullptr) != VK_SUCCESS || extensionCount > 4096) return 1;
        std::vector<VkExtensionProperties> extensions(extensionCount);
        if (query(nullptr, &extensionCount, extensions.data()) != VK_SUCCESS) return 1;
        bool portability = false;
        for (const auto& extension : extensions)
            portability |= !std::strcmp(extension.extensionName, VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);
        const char* portabilityName = VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME;
        VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO}; app.apiVersion = VK_API_VERSION_1_0;
        VkInstanceCreateInfo info{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO}; info.pApplicationInfo = &app;
        if (portability) {
            info.flags = VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
            info.enabledExtensionCount = 1; info.ppEnabledExtensionNames = &portabilityName;
        }
        if (create(&info, nullptr, &instance) != VK_SUCCESS) return 1;
        uint32_t count = 0;
        if (enumerate(instance, &count, nullptr) != VK_SUCCESS || !count || count > 4096) { destroy(instance, nullptr); return 1; }
        std::vector<VkPhysicalDevice> devices(count);
        if (enumerate(instance, &count, devices.data()) != VK_SUCCESS || !count) { destroy(instance, nullptr); return 1; }
        physical = devices[0];
    }
    struct InstanceScope {
        VkInstance handle; PFN_vkDestroyInstance destroy;
        ~InstanceScope() { if (handle && destroy) destroy(handle, nullptr); }
    } instanceScope{instance, destroy};
    const auto selectedQuery = [&](const char* layer, uint32_t* count, VkExtensionProperties* properties) {
        return deviceQuery ? deviceExtensions(physical, layer, count, properties) : query(layer, count, properties);
    };
    const char* name = nullptr;
    bool expectMissing = false;
    std::vector<VkLayerProperties> actualLayers;
    if (!std::strcmp(argv[2], "empty")) { name = ""; expectMissing = true; }
    else if (!std::strcmp(argv[2], "unknown")) {
        name = "VK_LAYER_CABOOSE_intentionally_absent_layer_query_control";
        expectMissing = true;
    } else if (!std::strcmp(argv[2], "known")) {
        uint32_t count = 0;
        if (layers(&count, nullptr) != VK_SUCCESS || count == 0 || count > 4096) {
            std::fprintf(stderr, "actual provider layer unavailable\n"); return 77;
        }
        actualLayers.resize(count);
        if (layers(&count, actualLayers.data()) != VK_SUCCESS || count == 0) return 1;
        name = actualLayers[0].layerName;
    } else if (std::strcmp(argv[2], "null")) return 2;
    uint32_t count = 0;
    const VkResult first = selectedQuery(name, &count, nullptr);
    std::printf("case=%s count_result=%d count=%u\n", argv[2], first, count);
    std::fflush(stdout);
    if (expectMissing) {
        VkExtensionProperties entry;
        std::memset(&entry, 0xa5, sizeof(entry));
        const VkExtensionProperties before = entry;
        uint32_t capacity = 1;
        const VkResult second = selectedQuery(name, &capacity, &entry);
        std::printf("properties_result=%d\n", second);
        return first == VK_ERROR_LAYER_NOT_PRESENT && second == VK_ERROR_LAYER_NOT_PRESENT &&
               count == 0 && capacity == 1 && !std::memcmp(&entry, &before, sizeof(entry)) ? 0 : 1;
    }
    if (first != VK_SUCCESS || count > 4096) return 1;
    std::vector<VkExtensionProperties> properties(count);
    uint32_t returned = count;
    const VkResult second = selectedQuery(name, &returned, properties.empty() ? nullptr : properties.data());
    std::printf("properties_result=%d returned=%u\n", second, returned);
    if (second != VK_SUCCESS || returned != count) return 1;
    for (const auto& property : properties) {
        if (!std::memchr(property.extensionName, '\0', sizeof(property.extensionName)) ||
            !property.extensionName[0]) return 1;
    }
    // Keep the selected provider loaded through process exit.
    return 0;
}
