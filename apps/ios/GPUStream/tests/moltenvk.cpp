// Exercises the actual pinned MoltenVK, not a fake proc table.
#include "moltenvk.h"
#include <cassert>
#include <cstring>
#include <iostream>
#include <thread>
#include <vector>
extern "C" VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetInstanceProcAddr(VkInstance, const char*);

int main()
{
    using caboose::gpu_stream::GetInstanceProcAddr;
    for (const auto* name : { "vkGetInstanceProcAddr", "vkCreateInstance", "vkDestroyInstance",
                             "vkEnumerateInstanceExtensionProperties", "vkEnumerateInstanceLayerProperties",
                             "vkEnumerateInstanceVersion", "vkEnumeratePhysicalDevices", "vkCabooseUnavailable" })
    {
        assert(bool(GetInstanceProcAddr(VK_NULL_HANDLE, name)) == bool(vkGetInstanceProcAddr(VK_NULL_HANDLE, name)));
    }
    assert(GetInstanceProcAddr(VK_NULL_HANDLE, nullptr) == nullptr);
    std::vector<std::thread> threads;
    for (int i = 0; i < 4; ++i)
    {
        threads.emplace_back([] {
            for (int iteration = 0; iteration < 5; ++iteration)
            {
                auto create = reinterpret_cast<PFN_vkCreateInstance>(GetInstanceProcAddr(VK_NULL_HANDLE, "vkCreateInstance"));
                VkApplicationInfo app{ VK_STRUCTURE_TYPE_APPLICATION_INFO };
                app.apiVersion = VK_API_VERSION_1_1;
                const char* extensions[] = { VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME };
                VkInstanceCreateInfo info{ VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
                info.pApplicationInfo = &app;
                info.flags = VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
                info.enabledExtensionCount = 1;
                info.ppEnabledExtensionNames = extensions;
                VkInstance instance = VK_NULL_HANDLE;
                assert(create(&info, nullptr, &instance) == VK_SUCCESS);
                auto enumerate = reinterpret_cast<PFN_vkEnumeratePhysicalDevices>(GetInstanceProcAddr(instance, "vkEnumeratePhysicalDevices"));
                assert(enumerate == reinterpret_cast<PFN_vkEnumeratePhysicalDevices>(vkGetInstanceProcAddr(instance, "vkEnumeratePhysicalDevices")));
                uint32_t count = 0;
                assert(enumerate(instance, &count, nullptr) == VK_SUCCESS && count > 0);
                std::vector<VkPhysicalDevice> physicals(count);
                assert(enumerate(instance, &count, physicals.data()) == VK_SUCCESS);
                float priority = 1;
                VkDeviceQueueCreateInfo queue{ VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO };
                queue.queueCount = 1;
                queue.pQueuePriorities = &priority;
                VkDeviceCreateInfo device_info{ VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO };
                device_info.queueCreateInfoCount = 1;
                device_info.pQueueCreateInfos = &queue;
                const char* device_extensions[] = { "VK_KHR_portability_subset" };
                device_info.enabledExtensionCount = 1;
                device_info.ppEnabledExtensionNames = device_extensions;
                auto create_device = reinterpret_cast<PFN_vkCreateDevice>(GetInstanceProcAddr(instance, "vkCreateDevice"));
                VkDevice device = VK_NULL_HANDLE;
                assert(create_device(physicals[0], &device_info, nullptr, &device) == VK_SUCCESS);
                auto device_proc = reinterpret_cast<PFN_vkGetDeviceProcAddr>(GetInstanceProcAddr(instance, "vkGetDeviceProcAddr"));
                assert(device_proc(device, "vkCabooseUnavailable") == nullptr);
                auto destroy_device = reinterpret_cast<PFN_vkDestroyDevice>(device_proc(device, "vkDestroyDevice"));
                assert(destroy_device == reinterpret_cast<PFN_vkDestroyDevice>(GetInstanceProcAddr(instance, "vkDestroyDevice")));
                destroy_device(device, nullptr);
                auto destroy = reinterpret_cast<PFN_vkDestroyInstance>(GetInstanceProcAddr(instance, "vkDestroyInstance"));
                assert(destroy);
                destroy(instance, nullptr);
            }
        });
    }
    for (auto& thread : threads) { thread.join(); }
    std::cout << "MoltenVK lookup semantics and 20 concurrent instance/device lifetimes: PASS\n";
}
