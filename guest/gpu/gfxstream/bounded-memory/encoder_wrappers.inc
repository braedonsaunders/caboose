// SPDX-License-Identifier: MIT
VkResult VkEncoder::vkFlushMappedMemoryRanges(VkDevice device, uint32_t count,
    const VkMappedMemoryRange* ranges, uint32_t doLock) {
#if defined(CABOOSE_GFXSTREAM_PRIVATE_INDEXED_WSI)
    if (!sResourceTracker->usingDirectMapping() &&
        !(sFeatureBits & VULKAN_STREAM_FEATURE_QUEUE_SUBMIT_WITH_COMMANDS_BIT)) {
        const auto valid = mImpl->validation()->on_vkFlushMappedMemoryRanges(this, VK_SUCCESS, device, count, ranges);
        if (valid != VK_SUCCESS) return valid;
        // Hold the same encoder across serialization and every outstanding reply.
        // doLock==0 means the caller already owns its required encoder lock.
        struct Unlock { VkEncoder* encoder; bool held; ~Unlock() { if (held) encoder->unlock(); } };
        if (doLock) this->lock();
        Unlock unlock{this, doLock != 0};
        caboose::memory::FlushCallScope timing{count};
        auto stream = mImpl->stream();
        caboose::memory::FlushWindow window{
            [&](unsigned i, unsigned long long offset, unsigned long long size) {
                VkMappedMemoryRange part = ranges[i]; part.offset = offset; part.size = size;
                return timing.send(size, [&] {
                    return int(cabooseFlushMemoryChunk(device, 1, &part, 0, true));
                });
            }, [&](int& result) {
                return timing.receive(result, [&] {
                    VkResult actual = VK_SUCCESS;
                    if (!stream->tryRead(&actual, sizeof(actual))) return false;
                    result = int(actual); return true;
                });
            }, [&] {
                timing.invalidate();
                stream->invalidate();
            }};
        caboose::memory::Reservation metadata{caboose::memory::processBudget};
        if (!metadata.add(sizeof(window))) return static_cast<VkResult>(timing.finish(VK_ERROR_OUT_OF_HOST_MEMORY));
        const int result = caboose::memory::transact(false, count,
            [&](uint32_t i, caboose::memory::Range& out) {
                if (!sResourceTracker->cabooseMappedRange(device, ranges[i].memory, out)) return false;
                out.offset = ranges[i].offset; out.size = ranges[i].size;
                out.whole = ranges[i].size == VK_WHOLE_SIZE;
                return !ranges[i].pNext && ranges[i].sType == VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE;
            }, [&](uint32_t i, uint64_t offset, uint64_t size, uint8_t*) {
                return window.push(i, offset, size);
            });
        if (result != caboose::memory::success) return static_cast<VkResult>(timing.finish(result));
        return static_cast<VkResult>(timing.finish(window.finish()));
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
