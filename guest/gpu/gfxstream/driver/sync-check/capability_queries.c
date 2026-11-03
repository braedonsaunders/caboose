// SPDX-License-Identifier: MIT
// Independent process capability-discovery latency; use separate empty and warmed caches.
#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <vulkan/vulkan.h>
static uint64_t now(void) {
    struct timespec value; clock_gettime(CLOCK_MONOTONIC,&value);
    return (uint64_t)value.tv_sec*1000000+value.tv_nsec/1000;
}
static uint64_t hash=0xcbf29ce484222325ull;
static void word(uint64_t value) { for (int i=0;i<8;++i) { hash=(hash^(value&255))*0x100000001b3ull;value>>=8; } }
#define CHECK(expr) do { VkResult result=(expr); if (result!=VK_SUCCESS) { fprintf(stderr,"%s: %d\n",#expr,result); return 2; } } while(0)
int main(void) {
    uint64_t started=now();
    VkApplicationInfo app={VK_STRUCTURE_TYPE_APPLICATION_INFO}; app.apiVersion=VK_API_VERSION_1_3;
    VkInstanceCreateInfo ii={VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO}; ii.pApplicationInfo=&app;
    VkInstance instance; CHECK(vkCreateInstance(&ii,NULL,&instance));
    uint32_t count=1; VkPhysicalDevice physical;
    VkResult enumerated=vkEnumeratePhysicalDevices(instance,&count,&physical);
    if ((enumerated!=VK_SUCCESS && enumerated!=VK_INCOMPLETE) || !count) return 2;
    VkPhysicalDeviceProperties2 properties={VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2};
    vkGetPhysicalDeviceProperties2(physical,&properties);
    uint64_t ready=now();
    for (uint32_t format=1;format<=184;++format) {
        VkFormatProperties3 three={VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_3};
        VkFormatProperties2 value={VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2}; value.pNext=&three;
        vkGetPhysicalDeviceFormatProperties2(physical,(VkFormat)format,&value);
        word(format); word(value.formatProperties.linearTilingFeatures);
        word(value.formatProperties.optimalTilingFeatures); word(value.formatProperties.bufferFeatures);
        word(three.linearTilingFeatures); word(three.optimalTilingFeatures); word(three.bufferFeatures);
        VkPhysicalDeviceImageFormatInfo2 query={VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2};
        query.format=(VkFormat)format; query.type=VK_IMAGE_TYPE_2D; query.tiling=VK_IMAGE_TILING_OPTIMAL;
        query.usage=VK_IMAGE_USAGE_SAMPLED_BIT;
        VkImageFormatProperties2 answer={VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2};
        VkResult result=vkGetPhysicalDeviceImageFormatProperties2(physical,&query,&answer);
        if (result!=VK_SUCCESS && result!=VK_ERROR_FORMAT_NOT_SUPPORTED) return 2;
        word((uint32_t)result);
        if (result==VK_SUCCESS) {
            word(answer.imageFormatProperties.maxExtent.width); word(answer.imageFormatProperties.maxExtent.height);
            word(answer.imageFormatProperties.maxExtent.depth); word(answer.imageFormatProperties.maxMipLevels);
            word(answer.imageFormatProperties.maxArrayLayers); word(answer.imageFormatProperties.sampleCounts);
            word(answer.imageFormatProperties.maxResourceSize);
        }
    }
    uint64_t formatsDone=now();
    VkQueueFamilyProperties families[32]; count=32; vkGetPhysicalDeviceQueueFamilyProperties(physical,&count,families);
    uint32_t family=0; while (family<count && !(families[family].queueFlags&VK_QUEUE_GRAPHICS_BIT)) ++family;
    if (family==count) return 2;
    float priority=1; VkDeviceQueueCreateInfo qi={VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
    qi.queueFamilyIndex=family; qi.queueCount=1; qi.pQueuePriorities=&priority;
    VkDeviceCreateInfo di={VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO}; di.queueCreateInfoCount=1; di.pQueueCreateInfos=&qi;
    VkDevice device; CHECK(vkCreateDevice(physical,&di,NULL,&device));
    uint64_t deviceReady=now();
    VkDescriptorSetLayoutBinding bindings[16]={0};
    for (uint32_t i=0;i<16;++i) {
        bindings[i].binding=i; bindings[i].descriptorType=VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
        bindings[i].descriptorCount=1; bindings[i].stageFlags=VK_SHADER_STAGE_VERTEX_BIT;
        VkDescriptorSetLayoutCreateInfo layout={VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
        layout.bindingCount=i+1; layout.pBindings=bindings;
        VkDescriptorSetLayoutSupport support={VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_SUPPORT};
        vkGetDescriptorSetLayoutSupport(device,&layout,&support); word(support.supported);
    }
    uint64_t done=now();
    vkDestroyDevice(device,NULL); vkDestroyInstance(instance,NULL);
    printf("CABOOSE_CAPABILITY_QUERIES setup_ms=%.3f formats_ms=%.3f device_ms=%.3f descriptors_ms=%.3f total_ms=%.3f hash=%016llx formats=184 layouts=16\n",
           (ready-started)/1000.0,(formatsDone-ready)/1000.0,(deviceReady-formatsDone)/1000.0,
           (done-deviceReady)/1000.0,(done-started)/1000.0,(unsigned long long)hash);
    return 0;
}
