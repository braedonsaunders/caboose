// SPDX-License-Identifier: MIT
// Ordinary loader calls with a deliberately nonexistent private broker endpoint.
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <vulkan/vulkan.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    const char *socket = getenv("CABOOSE_GFXSTREAM_SOCKET");
    struct stat st;
    if (!socket || !*socket || lstat(socket, &st) == 0 || errno != ENOENT) {
        fputs("requires an explicitly nonexistent broker endpoint\n", stderr);
        return 2;
    }
    void *icd = dlopen("/icd/libvulkan_gfxstream.so", RTLD_NOW | RTLD_LOCAL);
    if (!icd) { fprintf(stderr, "exact ICD: %s\n", dlerror()); return 3; }
    PFN_vkGetInstanceProcAddr icd_get =
        (PFN_vkGetInstanceProcAddr)dlsym(icd, "vk_icdGetInstanceProcAddr");
    typedef VkResult (VKAPI_PTR *Negotiate)(uint32_t *);
    Negotiate negotiate = (Negotiate)dlsym(icd, "vk_icdNegotiateLoaderICDInterfaceVersion");
    uint32_t interface_version = 7;
    if (!icd_get || !negotiate || negotiate(&interface_version) != VK_SUCCESS ||
        !interface_version || interface_version > 7 || !icd_get(VK_NULL_HANDLE, "vkCreateInstance")) {
        fputs("exact ICD loader exports unavailable\n", stderr); return 3;
    }
    printf("exact_icd_loaded=1 negotiated_interface=%u\n", interface_version);
    void *loader = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!loader) { fprintf(stderr, "loader: %s\n", dlerror()); return 3; }
    PFN_vkGetInstanceProcAddr get = (PFN_vkGetInstanceProcAddr)dlsym(loader, "vkGetInstanceProcAddr");
    if (!get) return 3;
    PFN_vkEnumerateInstanceExtensionProperties enumerate =
        (PFN_vkEnumerateInstanceExtensionProperties)get(VK_NULL_HANDLE, "vkEnumerateInstanceExtensionProperties");
    PFN_vkCreateInstance create = (PFN_vkCreateInstance)get(VK_NULL_HANDLE, "vkCreateInstance");
    if (!enumerate || !create) return 3;
    uint32_t count = 0;
    VkResult result = enumerate(NULL, &count, NULL);
    printf("instance_extension_count_result=%d count=%u\n", result, count);
    if (result == VK_SUCCESS) {
        if (count > 1024) return 4;
        VkExtensionProperties *properties = calloc(count ? count : 1, sizeof(*properties));
        if (!properties) return 4;
        result = enumerate(NULL, &count, properties);
        printf("instance_extension_list_result=%d count=%u\n", result, count);
        if (result == VK_SUCCESS || result == VK_INCOMPLETE)
            for (uint32_t i = 0; i < count; ++i)
                printf("extension=%s version=%u\n", properties[i].extensionName, properties[i].specVersion);
        free(properties);
    }
    if (get(VK_NULL_HANDLE, "vkCreateSwapchainKHR") || get(VK_NULL_HANDLE, "vkQueuePresentKHR")) {
        fputs("unexpected global device entrypoint\n", stderr); return 5;
    }
    VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "Caboose generic loader negative check", .apiVersion = VK_API_VERSION_1_1 };
    VkInstanceCreateInfo info = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
    VkInstance instance = VK_NULL_HANDLE;
    result = create(&info, NULL, &instance);
    printf("create_instance_result=%d instance_created=%d\n", result, result == VK_SUCCESS);
    if (result == VK_SUCCESS) {
        PFN_vkDestroyInstance destroy = (PFN_vkDestroyInstance)get(instance, "vkDestroyInstance");
        if (destroy) destroy(instance, NULL);
        fputs("unexpected success without a broker handshake\n", stderr); return 6;
    }
    if (result >= 0) return 6;
    dlclose(loader);
    dlclose(icd);
    puts("PASS: no instance or device established without the private handshake");
    return 0;
}
