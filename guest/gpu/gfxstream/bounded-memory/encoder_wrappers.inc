// SPDX-License-Identifier: MIT
VkResult VkEncoder::vkFlushMappedMemoryRanges(VkDevice device, uint32_t count,
    const VkMappedMemoryRange* ranges, uint32_t doLock) {
#if defined(CABOOSE_GFXSTREAM_PRIVATE_INDEXED_WSI)
    if (!sResourceTracker->usingDirectMapping()) {
        const auto valid = mImpl->validation()->on_vkFlushMappedMemoryRanges(this, VK_SUCCESS, device, count, ranges);
        if (valid != VK_SUCCESS) return valid;
        return static_cast<VkResult>(caboose::memory::transact(false, count,
            [&](uint32_t i, caboose::memory::Range& out) {
                if (!sResourceTracker->cabooseMappedRange(device, ranges[i].memory, out)) return false;
                out.offset = ranges[i].offset; out.size = ranges[i].size;
                out.whole = ranges[i].size == VK_WHOLE_SIZE;
                return !ranges[i].pNext && ranges[i].sType == VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE;
            }, [&](uint32_t i, uint64_t offset, uint64_t size, uint8_t*) {
                VkMappedMemoryRange part = ranges[i]; part.offset = offset; part.size = size;
                return int(cabooseFlushMemoryChunk(device, 1, &part, doLock));
            }));
    }
#endif
    return cabooseFlushMemoryChunk(device, count, ranges, doLock);
}
VkResult VkEncoder::vkInvalidateMappedMemoryRanges(VkDevice device, uint32_t count,
    const VkMappedMemoryRange* ranges, uint32_t doLock) {
#if defined(CABOOSE_GFXSTREAM_PRIVATE_INDEXED_WSI)
    if (!sResourceTracker->usingDirectMapping()) {
        const auto valid = mImpl->validation()->on_vkInvalidateMappedMemoryRanges(this, VK_SUCCESS, device, count, ranges);
        if (valid != VK_SUCCESS) return valid;
        return static_cast<VkResult>(caboose::memory::transact(true, count,
            [&](uint32_t i, caboose::memory::Range& out) {
                if (!sResourceTracker->cabooseMappedRange(device, ranges[i].memory, out)) return false;
                out.offset = ranges[i].offset; out.size = ranges[i].size;
                out.whole = ranges[i].size == VK_WHOLE_SIZE;
                return !ranges[i].pNext && ranges[i].sType == VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE;
            }, [&](uint32_t i, uint64_t offset, uint64_t size, uint8_t* destination) {
                VkMappedMemoryRange part = ranges[i]; part.offset = offset; part.size = size;
                return int(cabooseInvalidateMemoryChunk(device, 1, &part, doLock, destination));
            }));
    }
#endif
    return cabooseInvalidateMemoryChunk(device, count, ranges, doLock, nullptr);
}
