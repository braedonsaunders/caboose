// SPDX-License-Identifier: MIT
//
// ResourceTracker's part of the Direct3D 11 compatibility profile (d3d11_emulation.h):
// which of the features the host lacks, offering them, keeping them from the host at device
// creation, and the objects that stand in for null resources. Included by
// ResourceTracker.cpp.

namespace {

// The first memory type in `bits` that is device-local and not host-visible, else the
// first in `bits`; -1 if none.
int deviceLocalType(const VkPhysicalDeviceMemoryProperties& memory, uint32_t bits) {
    for (uint32_t i = 0; i < memory.memoryTypeCount; ++i) {
        VkMemoryPropertyFlags flags = memory.memoryTypes[i].propertyFlags;
        if ((bits & (1u << i)) && (flags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) &&
            !(flags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT))
            return int(i);
    }
    for (uint32_t i = 0; i < memory.memoryTypeCount; ++i)
        if (bits & (1u << i)) return int(i);
    return -1;
}

}  // namespace

bool ResourceTracker::cabooseHostHasRobustness2() const {
    return getHostDeviceExtensionIndex("VK_EXT_robustness2") != -1 ||
           getHostDeviceExtensionIndex("VK_KHR_robustness2") != -1;
}

void ResourceTracker::cabooseOfferD3D11CoreFeatures(VkPhysicalDeviceFeatures* features) {
    mCabooseHostGeometryShader.store(features->geometryShader ? 1 : 0, std::memory_order_relaxed);
    mCabooseHostCullDistance.store(features->shaderCullDistance ? 1 : 0, std::memory_order_relaxed);
    features->geometryShader = VK_TRUE;
    features->shaderCullDistance = VK_TRUE;
}

caboose::features::HeldFeatures ResourceTracker::cabooseHoldD3D11Features(VkPhysicalDeviceFeatures2* features) {
    caboose::features::HeldFeatures held;
    if (features && cabooseEmulatesDepthClipEnable()) {
        held.depthClip = vk_extract_struct<VkPhysicalDeviceDepthClipEnableFeaturesEXT>(
            features, VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DEPTH_CLIP_ENABLE_FEATURES_EXT);
    }
    if (features && !cabooseHostHasRobustness2()) {
        held.robustness2 = vk_extract_struct<VkPhysicalDeviceRobustness2FeaturesEXT>(
            features, VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT);
    }
    return held;
}

void ResourceTracker::cabooseOfferD3D11Features(VkPhysicalDeviceFeatures2* features,
                                                caboose::features::HeldFeatures held) {
    if (!features) return;
    if (held.depthClip) {
        held.depthClip->depthClipEnable = VK_TRUE;
        __vk_append_struct(features, held.depthClip);
    }
    if (held.robustness2) {
        // The host lacks the extension: the guest offers it with these two alone.
        held.robustness2->robustBufferAccess2 = VK_TRUE;
        held.robustness2->robustImageAccess2 = VK_FALSE;
        held.robustness2->nullDescriptor = VK_TRUE;
        __vk_append_struct(features, held.robustness2);
        mCabooseHostNullDescriptor.store(0, std::memory_order_relaxed);
        mCabooseHostRobustBufferAccess2.store(0, std::memory_order_relaxed);
    }
    // The host answered this structure itself: it has the extension.
    auto* robustness = vk_find_struct(features, PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT);
    if (robustness && !held.robustness2 && cabooseHostHasRobustness2()) {
        mCabooseHostNullDescriptor.store(robustness->nullDescriptor ? 1 : 0, std::memory_order_relaxed);
        mCabooseHostRobustBufferAccess2.store(robustness->robustBufferAccess2 ? 1 : 0,
                                              std::memory_order_relaxed);
        robustness->nullDescriptor = VK_TRUE;
        robustness->robustBufferAccess2 = VK_TRUE;
    }
}

void ResourceTracker::cabooseLearnHostFeatures(VkPhysicalDevice physicalDevice) {
    const bool robustness = cabooseHostHasRobustness2();
    if (!robustness) {
        mCabooseHostNullDescriptor.store(0, std::memory_order_relaxed);
        mCabooseHostRobustBufferAccess2.store(0, std::memory_order_relaxed);
    }
    if (mCabooseHostLogicOp.load(std::memory_order_relaxed) >= 0 &&
        mCabooseHostGeometryShader.load(std::memory_order_relaxed) >= 0 &&
        mCabooseHostCullDistance.load(std::memory_order_relaxed) >= 0 &&
        mCabooseHostNullDescriptor.load(std::memory_order_relaxed) >= 0)
        return;
    // The feature query records what the host has as it offers what it lacks.
    VkPhysicalDeviceRobustness2FeaturesEXT robustness2 = {
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT};
    VkPhysicalDeviceFeatures2 features = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
                                          robustness ? &robustness2 : nullptr};
    getThreadLocalEncoder()->vkGetPhysicalDeviceFeatures2(physicalDevice, &features, true /* do lock */);
}

void ResourceTracker::cabooseKeepOfferedFeatures(VkPhysicalDeviceFeatures* features) {
    if (mCabooseHostLogicOp.load(std::memory_order_relaxed) == 0) features->logicOp = VK_FALSE;
    if (mCabooseHostGeometryShader.load(std::memory_order_relaxed) == 0) features->geometryShader = VK_FALSE;
    if (mCabooseHostCullDistance.load(std::memory_order_relaxed) == 0) features->shaderCullDistance = VK_FALSE;
}

void ResourceTracker::cabooseKeepOfferedRobustness2(VkPhysicalDeviceRobustness2FeaturesEXT* features) {
    if (mCabooseHostNullDescriptor.load(std::memory_order_relaxed) == 0) features->nullDescriptor = VK_FALSE;
    if (mCabooseHostRobustBufferAccess2.load(std::memory_order_relaxed) == 0)
        features->robustBufferAccess2 = VK_FALSE;
}

bool ResourceTracker::cabooseEmulatesDepthClipEnable() const {
    return getHostDeviceExtensionIndex(caboose::features::kDepthClipEnable) == -1;
}

bool ResourceTracker::cabooseEmulatesNullDescriptor() const {
    return mCabooseHostNullDescriptor.load(std::memory_order_relaxed) == 0;
}

caboose::features::PipelineEmulation ResourceTracker::caboosePipelineEmulation() const {
    caboose::features::PipelineEmulation emulation;
    emulation.depthClip = cabooseEmulatesDepthClipEnable();
    emulation.geometryShader = mCabooseHostGeometryShader.load(std::memory_order_relaxed) == 0;
    emulation.cullDistance = mCabooseHostCullDistance.load(std::memory_order_relaxed) == 0;
    return emulation;
}

std::vector<uint32_t> ResourceTracker::cabooseShaderModuleCode(const VkShaderModuleCreateInfo* info) {
    if (!info || mCabooseHostCullDistance.load(std::memory_order_relaxed) != 0) return {};
    return caboose::features::withoutCullDistances(info->pCode, info->codeSize / 4);
}

void ResourceTracker::cabooseCreateNullObjects(VkPhysicalDevice physicalDevice, VkDevice device,
                                               const std::vector<VkQueue>& queues,
                                               const std::vector<uint32_t>& families) {
    VkEncoder* enc = getThreadLocalEncoder();
    // A queue that can clear an image.
    uint32_t familyCount = 0;
    enc->vkGetPhysicalDeviceQueueFamilyProperties(physicalDevice, &familyCount, nullptr, true /* do lock */);
    std::vector<VkQueueFamilyProperties> familyProperties(familyCount);
    enc->vkGetPhysicalDeviceQueueFamilyProperties(physicalDevice, &familyCount, familyProperties.data(),
                                                  true /* do lock */);
    VkQueue queue = VK_NULL_HANDLE;
    uint32_t family = 0;
    for (size_t i = 0; i < queues.size() && !queue; ++i) {
        if (families[i] < familyCount &&
            (familyProperties[families[i]].queueFlags & (VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT))) {
            queue = queues[i];
            family = families[i];
        }
    }
    if (!queue) {
        mesa_logw("caboose: no graphics or compute queue: null descriptors stay null");
        return;
    }
    VkPhysicalDeviceMemoryProperties memory{};
    enc->vkGetPhysicalDeviceMemoryProperties(physicalDevice, &memory, true /* do lock */);

    CabooseNullDevice null;
    auto fail = [&](const char* what) {
        mesa_logw("caboose: %s failed: null descriptors stay null", what);
        cabooseReleaseNullObjects(enc, device, null);
    };
    auto allocate = [&](const VkMemoryRequirements& requirements, VkDeviceMemory* out) {
        int type = deviceLocalType(memory, requirements.memoryTypeBits);
        if (type < 0) return VK_ERROR_OUT_OF_DEVICE_MEMORY;
        VkMemoryAllocateInfo info = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, nullptr, requirements.size,
                                     uint32_t(type)};
        return enc->vkAllocateMemory(device, &info, nullptr, out, true /* do lock */);
    };

    VkBufferCreateInfo bufferInfo = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
    bufferInfo.size = caboose::features::kNullBufferSize;
    bufferInfo.usage = VK_BUFFER_USAGE_UNIFORM_TEXEL_BUFFER_BIT | VK_BUFFER_USAGE_STORAGE_TEXEL_BUFFER_BIT |
                       VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT |
                       VK_BUFFER_USAGE_INDEX_BUFFER_BIT | VK_BUFFER_USAGE_VERTEX_BUFFER_BIT |
                       VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    bufferInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    if (enc->vkCreateBuffer(device, &bufferInfo, nullptr, &null.objects.buffer, true /* do lock */) != VK_SUCCESS)
        return fail("the null buffer");
    VkMemoryRequirements requirements{};
    enc->vkGetBufferMemoryRequirements(device, null.objects.buffer, &requirements, true /* do lock */);
    if (allocate(requirements, &null.bufferMemory) != VK_SUCCESS ||
        enc->vkBindBufferMemory(device, null.objects.buffer, null.bufferMemory, 0, true /* do lock */) != VK_SUCCESS)
        return fail("the null buffer's memory");
    VkBufferViewCreateInfo viewInfo = {VK_STRUCTURE_TYPE_BUFFER_VIEW_CREATE_INFO};
    viewInfo.buffer = null.objects.buffer;
    viewInfo.format = caboose::features::kNullFormat;
    viewInfo.range = VK_WHOLE_SIZE;
    if (enc->vkCreateBufferView(device, &viewInfo, nullptr, &null.objects.bufferView, true /* do lock */) != VK_SUCCESS)
        return fail("the null buffer view");

    VkImageCreateInfo imageInfo = {VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
    imageInfo.imageType = VK_IMAGE_TYPE_2D;
    imageInfo.format = caboose::features::kNullFormat;
    imageInfo.extent = {1, 1, 1};
    imageInfo.mipLevels = 1;
    imageInfo.arrayLayers = 1;
    imageInfo.samples = VK_SAMPLE_COUNT_1_BIT;
    imageInfo.tiling = VK_IMAGE_TILING_OPTIMAL;
    imageInfo.usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    imageInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    imageInfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    if (enc->vkCreateImage(device, &imageInfo, nullptr, &null.image, true /* do lock */) != VK_SUCCESS)
        return fail("the null image");
    enc->vkGetImageMemoryRequirements(device, null.image, &requirements, true /* do lock */);
    if (allocate(requirements, &null.imageMemory) != VK_SUCCESS ||
        enc->vkBindImageMemory(device, null.image, null.imageMemory, 0, true /* do lock */) != VK_SUCCESS)
        return fail("the null image's memory");
    const VkImageSubresourceRange color = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    VkImageViewCreateInfo imageViewInfo = {VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};
    imageViewInfo.image = null.image;
    imageViewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D;
    imageViewInfo.format = caboose::features::kNullFormat;
    imageViewInfo.subresourceRange = color;
    if (enc->vkCreateImageView(device, &imageViewInfo, nullptr, &null.objects.imageView, true /* do lock */) != VK_SUCCESS)
        return fail("the null image view");

    // Clear both to zero, and leave the image in the general layout its descriptors name.
    VkCommandPoolCreateInfo poolInfo = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, nullptr, 0, family};
    VkCommandPool pool = VK_NULL_HANDLE;
    if (enc->vkCreateCommandPool(device, &poolInfo, nullptr, &pool, true /* do lock */) != VK_SUCCESS)
        return fail("the null objects' command pool");
    VkCommandBufferAllocateInfo allocateInfo = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, nullptr, pool,
                                                VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1};
    VkCommandBuffer commandBuffer = VK_NULL_HANDLE;
    VkResult cleared = on_vkAllocateCommandBuffers(enc, VK_SUCCESS, device, &allocateInfo, &commandBuffer);
    if (cleared == VK_SUCCESS) {
        addToCommandPool(pool, 1, &commandBuffer);
        VkEncoder* cbEnc = getCommandBufferEncoder(commandBuffer);
        VkCommandBufferBeginInfo begin = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, nullptr,
                                          VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
        cleared = on_vkBeginCommandBuffer(cbEnc, VK_SUCCESS, commandBuffer, &begin);
    }
    if (cleared == VK_SUCCESS) {
        VkEncoder* cbEnc = getCommandBufferEncoder(commandBuffer);
        cbEnc->vkCmdFillBuffer(commandBuffer, null.objects.buffer, 0, VK_WHOLE_SIZE, 0, true /* do lock */);
        VkImageMemoryBarrier toTransfer = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
        toTransfer.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        toTransfer.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        toTransfer.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        toTransfer.srcQueueFamilyIndex = toTransfer.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        toTransfer.image = null.image;
        toTransfer.subresourceRange = color;
        on_vkCmdPipelineBarrier(cbEnc, commandBuffer, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                                VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, 1, &toTransfer);
        VkClearColorValue zero = {};
        cbEnc->vkCmdClearColorImage(commandBuffer, null.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &zero, 1,
                                    &color, true /* do lock */);
        VkBufferMemoryBarrier bufferDone = {VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER};
        bufferDone.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        bufferDone.dstAccessMask = VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT;
        bufferDone.srcQueueFamilyIndex = bufferDone.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        bufferDone.buffer = null.objects.buffer;
        bufferDone.size = VK_WHOLE_SIZE;
        VkImageMemoryBarrier toGeneral = toTransfer;
        toGeneral.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        toGeneral.dstAccessMask = VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT;
        toGeneral.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        toGeneral.newLayout = VK_IMAGE_LAYOUT_GENERAL;
        on_vkCmdPipelineBarrier(cbEnc, commandBuffer, VK_PIPELINE_STAGE_TRANSFER_BIT,
                                VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, nullptr, 1, &bufferDone, 1, &toGeneral);
        cleared = on_vkEndCommandBuffer(cbEnc, VK_SUCCESS, commandBuffer);
    }
    if (cleared == VK_SUCCESS) {
        VkSubmitInfo submit = {VK_STRUCTURE_TYPE_SUBMIT_INFO};
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &commandBuffer;
        VkEncoder* queueEnc = getQueueEncoder(queue);
        cleared = on_vkQueueSubmit(queueEnc, VK_SUCCESS, queue, 1, &submit, VK_NULL_HANDLE);
        if (cleared == VK_SUCCESS) cleared = on_vkQueueWaitIdle(queueEnc, VK_SUCCESS, queue);
    }
    if (commandBuffer) enc->vkFreeCommandBuffers(device, pool, 1, &commandBuffer, true /* do lock */);
    enc->vkDestroyCommandPool(device, pool, nullptr, true /* do lock */);
    if (cleared != VK_SUCCESS) return fail("clearing the null objects");

    std::lock_guard<std::recursive_mutex> lock(mLock);
    mCabooseNullObjects[device] = null;
}

void ResourceTracker::cabooseReleaseNullObjects(VkEncoder* enc, VkDevice device, const CabooseNullDevice& null) {
    if (null.objects.imageView) enc->vkDestroyImageView(device, null.objects.imageView, nullptr, true /* do lock */);
    if (null.image) enc->vkDestroyImage(device, null.image, nullptr, true /* do lock */);
    if (null.imageMemory) enc->vkFreeMemory(device, null.imageMemory, nullptr, true /* do lock */);
    if (null.objects.bufferView)
        enc->vkDestroyBufferView(device, null.objects.bufferView, nullptr, true /* do lock */);
    if (null.objects.buffer) enc->vkDestroyBuffer(device, null.objects.buffer, nullptr, true /* do lock */);
    if (null.bufferMemory) enc->vkFreeMemory(device, null.bufferMemory, nullptr, true /* do lock */);
}

void ResourceTracker::cabooseDestroyNullObjects(VkDevice device) {
    CabooseNullDevice null;
    {
        std::lock_guard<std::recursive_mutex> lock(mLock);
        auto found = mCabooseNullObjects.find(device);
        if (found == mCabooseNullObjects.end()) return;
        null = found->second;
        mCabooseNullObjects.erase(found);
    }
    cabooseReleaseNullObjects(getThreadLocalEncoder(), device, null);
}

caboose::features::NullObjects ResourceTracker::cabooseNullObjects(VkDevice device) {
    std::lock_guard<std::recursive_mutex> lock(mLock);
    auto found = mCabooseNullObjects.find(device);
    return found == mCabooseNullObjects.end() ? caboose::features::NullObjects() : found->second.objects;
}

caboose::features::NullObjects ResourceTracker::cabooseCommandBufferNullObjects(VkCommandBuffer commandBuffer) {
    struct goldfish_VkCommandBuffer* cb = as_goldfish_VkCommandBuffer(commandBuffer);
    return cb ? cabooseNullObjects(cb->device) : caboose::features::NullObjects();
}
