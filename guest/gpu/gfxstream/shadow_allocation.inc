    // Experimental socket path: explicit flush/invalidate only. Vulkan instance
    // creation remains gated until coherent mappings and session loss are handled.
    if (std::getenv("CABOOSE_GFXSTREAM_SOCKET") && requestedMemoryIsHostVisible) {
        if (pAllocateInfo->pNext || pAllocator ||
            pAllocateInfo->memoryTypeIndex >= physicalDeviceMemoryProps.memoryTypeCount ||
            (physicalDeviceMemoryProps.memoryTypes[pAllocateInfo->memoryTypeIndex].propertyFlags &
             VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) {
            return VK_ERROR_FEATURE_NOT_PRESENT;
        }
        if (!pAllocateInfo->allocationSize || pAllocateInfo->allocationSize > SIZE_MAX) {
            return VK_ERROR_OUT_OF_HOST_MEMORY;
        }
        size_t alignment;
        {
            std::lock_guard<std::recursive_mutex> lock(mLock);
            auto deviceInfo = info_VkDevice.find(device);
            if (deviceInfo == info_VkDevice.end()) return VK_ERROR_DEVICE_LOST;
            alignment = std::max<size_t>(sizeof(void*), deviceInfo->second.props.limits.minMemoryMapAlignment);
        }
        // posix_memalign requires a power of two and pointer-sized minimum.
        if ((alignment & (alignment - 1)) != 0) return VK_ERROR_INITIALIZATION_FAILED;
        void* allocation = nullptr;
        if (posix_memalign(&allocation, alignment, static_cast<size_t>(pAllocateInfo->allocationSize)))
            return VK_ERROR_OUT_OF_HOST_MEMORY;
        auto raw = static_cast<uint8_t*>(allocation);
        std::shared_ptr<uint8_t> shadow;
        try {
            shadow = std::shared_ptr<uint8_t>(raw, std::free);
        } catch (const std::bad_alloc&) {
            // shared_ptr invokes its deleter on construction failure.
            return VK_ERROR_OUT_OF_HOST_MEMORY;
        }
        VkDeviceMemory memory = VK_NULL_HANDLE;
        VkResult result = enc->vkAllocateMemory(device, pAllocateInfo, nullptr, &memory, true);
        if (result != VK_SUCCESS) return result;
        try {
            std::lock_guard<std::recursive_mutex> lock(mLock);
            auto& info = info_VkDeviceMemory[memory];
            info.device = device;
            info.allocationSize = pAllocateInfo->allocationSize;
            info.memoryTypeIndex = pAllocateInfo->memoryTypeIndex;
            info.ptr = shadow.get();
            info.socketShadow = std::move(shadow);
        } catch (const std::bad_alloc&) {
            enc->vkFreeMemory(device, memory, nullptr, true);
            return VK_ERROR_OUT_OF_HOST_MEMORY;
        }
        *pMemory = memory;
        return VK_SUCCESS;
    }
