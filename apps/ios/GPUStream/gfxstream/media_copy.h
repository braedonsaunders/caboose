// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// The GPU half of a latch (docs/gpu-media.md, "Latch"): fill an application image on its
// queue from a VideoToolbox picture or from carried pixels. Independent of the decoder, so
// tests drive it on a plain MoltenVK device.
#pragma once
#ifndef VK_USE_PLATFORM_METAL_EXT
#define VK_USE_PLATFORM_METAL_EXT 1
#endif
#include "media_wire.h"
#include <CoreVideo/CoreVideo.h>
#include <vulkan/vulkan.h>
#include <memory>
#include <mutex>

namespace caboose::gpuv2::media {
// The entry points a latch copy uses.
struct VulkanFunctions {
    PFN_vkGetPhysicalDeviceMemoryProperties getPhysicalDeviceMemoryProperties = nullptr;
    PFN_vkCreateImage createImage = nullptr;
    PFN_vkDestroyImage destroyImage = nullptr;
    PFN_vkCreateBuffer createBuffer = nullptr;
    PFN_vkDestroyBuffer destroyBuffer = nullptr;
    PFN_vkGetBufferMemoryRequirements getBufferMemoryRequirements = nullptr;
    PFN_vkAllocateMemory allocateMemory = nullptr;
    PFN_vkFreeMemory freeMemory = nullptr;
    PFN_vkBindBufferMemory bindBufferMemory = nullptr;
    PFN_vkMapMemory mapMemory = nullptr;
    PFN_vkUnmapMemory unmapMemory = nullptr;
    PFN_vkCreateCommandPool createCommandPool = nullptr;
    PFN_vkDestroyCommandPool destroyCommandPool = nullptr;
    PFN_vkAllocateCommandBuffers allocateCommandBuffers = nullptr;
    PFN_vkBeginCommandBuffer beginCommandBuffer = nullptr;
    PFN_vkEndCommandBuffer endCommandBuffer = nullptr;
    PFN_vkCmdPipelineBarrier cmdPipelineBarrier = nullptr;
    PFN_vkCmdCopyImage cmdCopyImage = nullptr;
    PFN_vkCmdCopyBufferToImage cmdCopyBufferToImage = nullptr;
    PFN_vkCreateFence createFence = nullptr;
    PFN_vkDestroyFence destroyFence = nullptr;
    PFN_vkWaitForFences waitForFences = nullptr;
    PFN_vkQueueSubmit queueSubmit = nullptr;
    // Optional: the MTLDevice behind the Vulkan device. Without it the system default is used.
    PFN_vkExportMetalObjectsEXT exportMetalObjects = nullptr;
    bool complete() const;
};

// From any dispatch table with the Vulkan entry point names as members.
template <class Dispatch> VulkanFunctions functionsFrom(const Dispatch& d) {
    VulkanFunctions f;
    f.getPhysicalDeviceMemoryProperties = d.vkGetPhysicalDeviceMemoryProperties;
    f.createImage = d.vkCreateImage; f.destroyImage = d.vkDestroyImage;
    f.createBuffer = d.vkCreateBuffer; f.destroyBuffer = d.vkDestroyBuffer;
    f.getBufferMemoryRequirements = d.vkGetBufferMemoryRequirements;
    f.allocateMemory = d.vkAllocateMemory; f.freeMemory = d.vkFreeMemory;
    f.bindBufferMemory = d.vkBindBufferMemory; f.mapMemory = d.vkMapMemory; f.unmapMemory = d.vkUnmapMemory;
    f.createCommandPool = d.vkCreateCommandPool; f.destroyCommandPool = d.vkDestroyCommandPool;
    f.allocateCommandBuffers = d.vkAllocateCommandBuffers;
    f.beginCommandBuffer = d.vkBeginCommandBuffer; f.endCommandBuffer = d.vkEndCommandBuffer;
    f.cmdPipelineBarrier = d.vkCmdPipelineBarrier; f.cmdCopyImage = d.vkCmdCopyImage;
    f.cmdCopyBufferToImage = d.vkCmdCopyBufferToImage;
    f.createFence = d.vkCreateFence; f.destroyFence = d.vkDestroyFence; f.waitForFences = d.vkWaitForFences;
    f.queueSubmit = d.vkQueueSubmit;
    return f;
}

struct CopyTarget {
    VulkanFunctions vk;
    VkPhysicalDevice physicalDevice = VK_NULL_HANDLE;
    VkDevice device = VK_NULL_HANDLE;
    VkQueue queue = VK_NULL_HANDLE;
    uint32_t queueFamily = 0;
    std::mutex* queueMutex = nullptr;  // held around the submission when set
    VkImage image = VK_NULL_HANDLE;
    VkFormat format = VK_FORMAT_UNDEFINED;
    VkExtent2D extent{};
    uint32_t planes = 0;        // kPlaneLuma | kPlaneChroma: which surface planes the image holds
    bool metalObjects = false;  // VK_EXT_metal_objects is enabled on the device
};

// A submitted copy's resources, released after its fence signals.
class PendingCopy;
struct PendingCopyDeleter { void operator()(PendingCopy*) const; };
using Pending = std::unique_ptr<PendingCopy, PendingCopyDeleter>;

// Whether `format` can hold `planes` of a picture with `bytesPerSample` (1 or 2).
bool formatHolds(VkFormat format, uint32_t planes, uint32_t bytesPerSample);

// Records and submits the copy. On VK_SUCCESS *out holds the in-flight resources; hand
// them to Reclaimer with whatever must stay alive until the copy completes.
VkResult copyPicture(const CopyTarget& target, CVPixelBufferRef picture, Pending* out);
VkResult copyPixels(const CopyTarget& target, const LatchEntry& pixels, Pending* out);

// Waits for retired copies on its own thread, then releases their resources and, after
// them, what the caller kept alive with them (the decoder leases).
class Reclaimer {
public:
    static Reclaimer& instance();
    void retire(Pending pending, std::shared_ptr<void> keepAlive);
    // Returns once every retired copy has been released.
    void drain();
private:
    Reclaimer() = default;
    struct State;
    State& state();
};
}
