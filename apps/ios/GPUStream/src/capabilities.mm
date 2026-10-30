#include "caboose_gpu_stream.h"
#include <vulkan/vulkan.h>
#import <Foundation/Foundation.h>

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

extern "C" VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetInstanceProcAddr(VkInstance instance, const char* name);

namespace {

template<typename T> T Proc(VkInstance instance, const char* name)
{
    auto proc = reinterpret_cast<T>(vkGetInstanceProcAddr(instance, name));
    if (!proc) { throw std::runtime_error(std::string("Missing Vulkan entry point: ") + name); }
    return proc;
}

void Check(VkResult result, const char* operation)
{
    if (result != VK_SUCCESS) {
        throw std::runtime_error(std::string(operation) + ": VkResult " + std::to_string(result));
    }
}

template<typename T, typename F> std::vector<T> Enumerate(F call, const char* operation)
{
    for (int attempt = 0; attempt < 3; ++attempt) {
        uint32_t count = 0;
        Check(call(&count, nullptr), operation);
        std::vector<T> items(count);
        if (!count) { return items; }
        VkResult result = call(&count, items.data());
        if (result == VK_INCOMPLETE) { continue; }
        Check(result, operation);
        items.resize(count);
        return items;
    }
    throw std::runtime_error(std::string(operation) + ": enumeration did not stabilize");
}

struct Instance {
    VkInstance handle = VK_NULL_HANDLE;
    ~Instance()
    {
        if (handle) {
            auto destroy = reinterpret_cast<PFN_vkDestroyInstance>(vkGetInstanceProcAddr(handle, "vkDestroyInstance"));
            if (destroy) { destroy(handle, nullptr); }
        }
    }
};

NSString* Text(const char* value) { return [NSString stringWithUTF8String:value] ?: @""; }

NSDictionary* Query()
{
    auto enumerateExtensions = Proc<PFN_vkEnumerateInstanceExtensionProperties>(VK_NULL_HANDLE, "vkEnumerateInstanceExtensionProperties");
    auto extensions = Enumerate<VkExtensionProperties>([&](uint32_t* count, VkExtensionProperties* out) {
        return enumerateExtensions(nullptr, count, out);
    }, "vkEnumerateInstanceExtensionProperties");
    const bool portability = std::any_of(extensions.begin(), extensions.end(), [](const auto& e) {
        return std::strcmp(e.extensionName, VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME) == 0;
    });
    const char* enabledExtension = VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME;
    VkApplicationInfo app{ VK_STRUCTURE_TYPE_APPLICATION_INFO };
    app.pApplicationName = "Caboose GPU capability query";
    app.apiVersion = VK_API_VERSION_1_0;
    VkInstanceCreateInfo create{ VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
    create.pApplicationInfo = &app;
    create.flags = portability ? VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR : 0;
    create.enabledExtensionCount = portability ? 1 : 0;
    create.ppEnabledExtensionNames = portability ? &enabledExtension : nullptr;
    Instance instance;
    Check(Proc<PFN_vkCreateInstance>(VK_NULL_HANDLE, "vkCreateInstance")(&create, nullptr, &instance.handle), "vkCreateInstance");
    auto enumerateDevices = Proc<PFN_vkEnumeratePhysicalDevices>(instance.handle, "vkEnumeratePhysicalDevices");
    auto devices = Enumerate<VkPhysicalDevice>([&](uint32_t* count, VkPhysicalDevice* out) {
        return enumerateDevices(instance.handle, count, out);
    }, "vkEnumeratePhysicalDevices");
    if (devices.empty()) { throw std::runtime_error("MoltenVK reports no physical devices"); }
    auto getProperties = Proc<PFN_vkGetPhysicalDeviceProperties>(instance.handle, "vkGetPhysicalDeviceProperties");
    auto getFeatures = Proc<PFN_vkGetPhysicalDeviceFeatures>(instance.handle, "vkGetPhysicalDeviceFeatures");
    auto getFormats = Proc<PFN_vkGetPhysicalDeviceFormatProperties>(instance.handle, "vkGetPhysicalDeviceFormatProperties");
    auto getImageFormats = Proc<PFN_vkGetPhysicalDeviceImageFormatProperties>(instance.handle, "vkGetPhysicalDeviceImageFormatProperties");
    auto getExtensions = Proc<PFN_vkEnumerateDeviceExtensionProperties>(instance.handle, "vkEnumerateDeviceExtensionProperties");
    NSMutableArray* reports = [NSMutableArray array];
    for (VkPhysicalDevice device : devices) {
        VkPhysicalDeviceProperties properties{};
        VkPhysicalDeviceFeatures features{};
        getProperties(device, &properties);
        getFeatures(device, &features);
        NSMutableDictionary* featureReport = [NSMutableDictionary dictionary];
#define FEATURE(name) featureReport[@#name] = @(features.name != VK_FALSE)
        FEATURE(robustBufferAccess); FEATURE(fullDrawIndexUint32); FEATURE(imageCubeArray);
        FEATURE(independentBlend); FEATURE(geometryShader); FEATURE(tessellationShader);
        FEATURE(sampleRateShading); FEATURE(dualSrcBlend); FEATURE(logicOp);
        FEATURE(multiDrawIndirect); FEATURE(drawIndirectFirstInstance); FEATURE(depthClamp);
        FEATURE(depthBiasClamp); FEATURE(fillModeNonSolid); FEATURE(depthBounds);
        FEATURE(wideLines); FEATURE(largePoints); FEATURE(alphaToOne); FEATURE(multiViewport);
        FEATURE(samplerAnisotropy); FEATURE(textureCompressionETC2); FEATURE(textureCompressionASTC_LDR);
        FEATURE(textureCompressionBC); FEATURE(occlusionQueryPrecise); FEATURE(pipelineStatisticsQuery);
        FEATURE(vertexPipelineStoresAndAtomics); FEATURE(fragmentStoresAndAtomics);
        FEATURE(shaderTessellationAndGeometryPointSize); FEATURE(shaderImageGatherExtended);
        FEATURE(shaderStorageImageExtendedFormats); FEATURE(shaderStorageImageMultisample);
        FEATURE(shaderStorageImageReadWithoutFormat); FEATURE(shaderStorageImageWriteWithoutFormat);
        FEATURE(shaderUniformBufferArrayDynamicIndexing); FEATURE(shaderSampledImageArrayDynamicIndexing);
        FEATURE(shaderStorageBufferArrayDynamicIndexing); FEATURE(shaderStorageImageArrayDynamicIndexing);
        FEATURE(shaderClipDistance); FEATURE(shaderCullDistance); FEATURE(shaderFloat64);
        FEATURE(shaderInt64); FEATURE(shaderInt16); FEATURE(shaderResourceResidency); FEATURE(shaderResourceMinLod);
        FEATURE(sparseBinding); FEATURE(sparseResidencyBuffer); FEATURE(sparseResidencyImage2D);
        FEATURE(sparseResidencyImage3D); FEATURE(sparseResidency2Samples); FEATURE(sparseResidency4Samples);
        FEATURE(sparseResidency8Samples); FEATURE(sparseResidency16Samples); FEATURE(sparseResidencyAliased);
        FEATURE(variableMultisampleRate); FEATURE(inheritedQueries);
#undef FEATURE
        const auto& limits = properties.limits;
        NSMutableDictionary* limitReport = [NSMutableDictionary dictionary];
#define LIMIT(name) limitReport[@#name] = @(limits.name)
        LIMIT(maxImageDimension2D); LIMIT(maxImageDimension3D); LIMIT(maxImageArrayLayers);
        LIMIT(maxUniformBufferRange); LIMIT(maxStorageBufferRange); LIMIT(maxPushConstantsSize);
        LIMIT(maxBoundDescriptorSets); LIMIT(maxPerStageDescriptorSamplers);
        LIMIT(maxPerStageDescriptorSampledImages); LIMIT(maxPerStageDescriptorStorageImages);
        LIMIT(maxPerStageDescriptorStorageBuffers); LIMIT(maxPerStageResources);
        LIMIT(maxVertexInputAttributes); LIMIT(maxVertexOutputComponents);
        LIMIT(maxGeometryShaderInvocations); LIMIT(maxGeometryInputComponents);
        LIMIT(maxGeometryOutputComponents); LIMIT(maxGeometryOutputVertices); LIMIT(maxGeometryTotalOutputComponents);
        LIMIT(maxFragmentInputComponents); LIMIT(maxColorAttachments);
        LIMIT(maxClipDistances); LIMIT(maxCullDistances); LIMIT(maxCombinedClipAndCullDistances);
        LIMIT(maxComputeSharedMemorySize); LIMIT(maxComputeWorkGroupInvocations);
        LIMIT(framebufferColorSampleCounts); LIMIT(framebufferDepthSampleCounts);
        LIMIT(minUniformBufferOffsetAlignment); LIMIT(minStorageBufferOffsetAlignment);
        LIMIT(nonCoherentAtomSize); LIMIT(timestampPeriod);
#undef LIMIT
        limitReport[@"maxComputeWorkGroupCount"] = @[@(limits.maxComputeWorkGroupCount[0]), @(limits.maxComputeWorkGroupCount[1]), @(limits.maxComputeWorkGroupCount[2])];
        limitReport[@"maxComputeWorkGroupSize"] = @[@(limits.maxComputeWorkGroupSize[0]), @(limits.maxComputeWorkGroupSize[1]), @(limits.maxComputeWorkGroupSize[2])];
        NSMutableArray* formats = [NSMutableArray array];
        // The Vulkan core BC enum values are contiguous, including both BC1 RGB and RGBA.
        for (int value = VK_FORMAT_BC1_RGB_UNORM_BLOCK; value <= VK_FORMAT_BC7_SRGB_BLOCK; ++value) {
            VkFormat format = static_cast<VkFormat>(value);
            VkFormatProperties flags{};
            VkImageFormatProperties image{};
            getFormats(device, format, &flags);
            VkResult result = getImageFormats(device, format, VK_IMAGE_TYPE_2D, VK_IMAGE_TILING_OPTIMAL,
                                              VK_IMAGE_USAGE_SAMPLED_BIT, 0, &image);
            [formats addObject:@{
                @"format": @(value), @"linearTilingFeatures": @(flags.linearTilingFeatures),
                @"optimalTilingFeatures": @(flags.optimalTilingFeatures), @"bufferFeatures": @(flags.bufferFeatures),
                @"sampledOptimal": @((flags.optimalTilingFeatures & VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT) != 0),
                @"sampledImage2DResult": @(result), @"maxExtent": @[@(image.maxExtent.width), @(image.maxExtent.height), @(image.maxExtent.depth)],
                @"maxMipLevels": @(image.maxMipLevels), @"maxArrayLayers": @(image.maxArrayLayers),
                @"sampleCounts": @(image.sampleCounts), @"maxResourceSize": @(image.maxResourceSize)
            }];
        }
        auto deviceExtensions = Enumerate<VkExtensionProperties>([&](uint32_t* count, VkExtensionProperties* out) {
            return getExtensions(device, nullptr, count, out);
        }, "vkEnumerateDeviceExtensionProperties");
        NSMutableDictionary* extensionReport = [NSMutableDictionary dictionary];
        for (const auto& e : deviceExtensions) { extensionReport[Text(e.extensionName)] = @(e.specVersion); }
        [reports addObject:@{
            @"name": Text(properties.deviceName), @"vendorID": @(properties.vendorID), @"deviceID": @(properties.deviceID),
            @"deviceType": @(properties.deviceType), @"apiVersion": @(properties.apiVersion), @"driverVersion": @(properties.driverVersion),
            @"features": featureReport, @"limits": limitReport, @"bcFormats": formats, @"extensions": extensionReport
        }];
    }
    return @{@"schemaVersion": @1, @"source": @"linked MoltenVK", @"devices": reports};
}
} // namespace

extern "C" char* cgpu_device_capabilities_json(void)
{
    @autoreleasepool {
        NSDictionary* report;
        try { report = Query(); }
        catch (const std::exception& error) { report = @{@"schemaVersion": @1, @"error": Text(error.what())}; }
        catch (...) { report = @{@"schemaVersion": @1, @"error": @"Unknown capability query failure"}; }
        NSError* error = nil;
        NSData* data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:&error];
        if (!data) { return strdup("{\"schemaVersion\":1,\"error\":\"Capability JSON serialization failed\"}"); }
        auto result = static_cast<char*>(std::malloc(data.length + 1));
        if (!result) { return nullptr; }
        std::memcpy(result, data.bytes, data.length);
        result[data.length] = '\0';
        return result;
    }
}

extern "C" void cgpu_device_capabilities_free(char* json) { std::free(json); }
