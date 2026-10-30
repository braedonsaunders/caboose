// SPDX-License-Identifier: MIT
VkResult VkEncoder::vkFlushMappedMemoryRanges(VkDevice device, uint32_t count,
    const VkMappedMemoryRange* ranges, uint32_t doLock) {
#if defined(CABOOSE_GFXSTREAM_PRIVATE_INDEXED_WSI)
    if (!sResourceTracker->usingDirectMapping() &&
        !(sFeatureBits & VULKAN_STREAM_FEATURE_QUEUE_SUBMIT_WITH_COMMANDS_BIT)) {
        caboose::memory::FlushCallScope timing{count};
        const auto valid = timing.validate([&] {
            return mImpl->validation()->on_vkFlushMappedMemoryRanges(this, VK_SUCCESS, device, count, ranges);
        });
        if (valid != VK_SUCCESS) return static_cast<VkResult>(timing.finish(valid));
        // Hold the same encoder across serialization and every outstanding reply.
        // doLock==0 means the caller already owns its required encoder lock.
        struct Unlock { VkEncoder* encoder; bool held; ~Unlock() { if (held) encoder->unlock(); } };
        if (doLock) timing.lock([&] { this->lock(); });
        Unlock unlock{this, doLock != 0};
        auto stream = mImpl->stream();
        uint64_t packetBytes = 0;
        caboose::memory::FlushPacket packet{
            [&](const caboose::memory::FlushFragment* fragments, size_t size, uint64_t wire) {
                if (!caboose::memory::deferredReplies.reserve(this, stream, wire)) return -1;
                packetBytes = wire;
                std::array<VkMappedMemoryRange, caboose::memory::flushFragmentCapacity> parts{};
                uint64_t payload = 0;
                for (size_t i = 0; i < size; ++i) {
                    parts[i] = ranges[fragments[i].range];
                    parts[i].offset = fragments[i].offset;
                    parts[i].size = fragments[i].size;
                    payload += fragments[i].size;
                }
                return timing.send(payload, [&] {
                    return int(cabooseFlushMemoryChunk(device, uint32_t(size), parts.data(), 0, true));
                });
            }, [&](int& result) {
                return timing.receive(result, [&] {
                    caboose::memory::deferredReplies.add(this, 1, packetBytes);
                    result = VK_SUCCESS; return true;
                });
            }, [&] {
                timing.invalidate();
                stream->invalidate();
            }};
        struct Mapping { const uint8_t* base; uint64_t allocation; };
        caboose::memory::Reservation metadata{caboose::memory::processBudget};
        if (!metadata.add(sizeof(packet) + sizeof(timing) +
                          sizeof(VkMappedMemoryRange) * caboose::memory::flushFragmentCapacity +
                          sizeof(Mapping) * size_t(count)))
            return static_cast<VkResult>(timing.finish(VK_ERROR_OUT_OF_HOST_MEMORY));
        std::unique_ptr<Mapping[]> mappings(new (std::nothrow) Mapping[count]);
        if (!mappings) return static_cast<VkResult>(timing.finish(VK_ERROR_OUT_OF_HOST_MEMORY));
        const int result = caboose::memory::transact(false, count,
            [&](uint32_t i, caboose::memory::Range& out) {
                if (!sResourceTracker->cabooseMappedRange(device, ranges[i].memory, out)) return false;
                out.offset = ranges[i].offset; out.size = ranges[i].size;
                out.whole = ranges[i].size == VK_WHOLE_SIZE;
                mappings[i] = {out.base, out.allocation};
                return !ranges[i].pNext && ranges[i].sType == VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE;
            }, [&](uint32_t i, uint64_t offset, uint64_t size, uint8_t*) {
                return caboose::memory::flushShadow.emitChanged(
                    uint64_t(uintptr_t(ranges[i].memory)), mappings[i].base, mappings[i].allocation,
                    offset, size, [&](uint64_t changedOffset, uint64_t changedSize) {
                        return packet.push(i, changedOffset, changedSize);
                    });
            });
        if (result != caboose::memory::success) return static_cast<VkResult>(timing.finish(result));
        return static_cast<VkResult>(timing.finish(packet.finish()));
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
        for (uint32_t i = 0; i < count; ++i)
            caboose::memory::flushShadow.forget(uint64_t(uintptr_t(ranges[i].memory)));
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
