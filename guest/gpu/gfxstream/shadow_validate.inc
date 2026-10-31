    if (info.socketShadow) {
        if (!info.socketMapped || range.pNext || range.offset < info.socketMapOffset ||
            range.offset >= info.socketMapOffset + info.socketMapSize) return false;
        const VkDeviceSize end = info.socketMapOffset + info.socketMapSize;
        const VkDeviceSize length = range.size == VK_WHOLE_SIZE ? end - range.offset : range.size;
        if (!length || length > end - range.offset) return false;
        auto device = info_VkDevice.find(info.device);
        if (device == info_VkDevice.end()) return false;
        const VkDeviceSize atom = device->second.props.limits.nonCoherentAtomSize;
        if (!atom || range.offset % atom) return false;
        if (range.size == VK_WHOLE_SIZE)
            return end % atom == 0 || end == info.allocationSize;
        return length % atom == 0 || range.offset + length == info.allocationSize;
    }
