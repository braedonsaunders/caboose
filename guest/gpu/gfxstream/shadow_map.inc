    if (deviceMemoryInfo.socketShadow) {
        if (deviceMemoryInfo.device != device || !ppData || deviceMemoryInfo.socketMapped ||
            offset >= deviceMemoryInfo.allocationSize ||
            (size != VK_WHOLE_SIZE && (!size || size > deviceMemoryInfo.allocationSize - offset)))
            return VK_ERROR_MEMORY_MAP_FAILED;
        deviceMemoryInfo.socketMapOffset = offset;
        deviceMemoryInfo.socketMapSize = size == VK_WHOLE_SIZE
            ? deviceMemoryInfo.allocationSize - offset : size;
        deviceMemoryInfo.socketMapped = true;
        *ppData = deviceMemoryInfo.ptr + offset;
        return VK_SUCCESS;
    }
