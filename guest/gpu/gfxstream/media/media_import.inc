// SPDX-License-Identifier: MIT
// Imported dmabufs on the Caboose socket transport: ResourceTracker members
// and helpers, included once by ResourceTracker.cpp inside gfxstream::vk.
// The pure decisions are in media_import.h; docs/gpu-media.md is the contract.
// LINEAR dma-bufs only: phone-resident (REMOTE) ones are caboose-dmabuf/'s.
// ResourceTracker.cpp includes <fcntl.h>, <sys/mman.h>, <sys/stat.h>, <unistd.h>,
// <cerrno>, <cstring> and <initializer_list> for it.

namespace {

caboose::media::PlaneFormat caboosePlaneFormat(VkFormat format) {
    using caboose::media::PlaneFormat;
    switch (format) {
    case VK_FORMAT_G8_B8R8_2PLANE_420_UNORM: return PlaneFormat::twoPlane8;
    case VK_FORMAT_G10X6_B10X6R10X6_2PLANE_420_UNORM_3PACK16:
    case VK_FORMAT_G16_B16R16_2PLANE_420_UNORM: return PlaneFormat::twoPlane16;
    case VK_FORMAT_R8_UNORM: return PlaneFormat::luma8;
    case VK_FORMAT_R16_UNORM: return PlaneFormat::luma16;
    case VK_FORMAT_R8G8_UNORM: return PlaneFormat::chroma8;
    case VK_FORMAT_R16G16_UNORM: return PlaneFormat::chroma16;
    default: return PlaneFormat::unsupported;
    }
}

uint32_t cabooseFormatPlaneCount(VkFormat format) {
    switch (format) {
    case VK_FORMAT_G8_B8R8_2PLANE_420_UNORM:
    case VK_FORMAT_G8_B8R8_2PLANE_422_UNORM:
    case VK_FORMAT_G10X6_B10X6R10X6_2PLANE_420_UNORM_3PACK16:
    case VK_FORMAT_G10X6_B10X6R10X6_2PLANE_422_UNORM_3PACK16:
    case VK_FORMAT_G12X4_B12X4R12X4_2PLANE_420_UNORM_3PACK16:
    case VK_FORMAT_G12X4_B12X4R12X4_2PLANE_422_UNORM_3PACK16:
    case VK_FORMAT_G16_B16R16_2PLANE_420_UNORM:
    case VK_FORMAT_G16_B16R16_2PLANE_422_UNORM:
    case VK_FORMAT_G8_B8R8_2PLANE_444_UNORM:
    case VK_FORMAT_G10X6_B10X6R10X6_2PLANE_444_UNORM_3PACK16:
    case VK_FORMAT_G12X4_B12X4R12X4_2PLANE_444_UNORM_3PACK16:
    case VK_FORMAT_G16_B16R16_2PLANE_444_UNORM: return 2;
    case VK_FORMAT_G8_B8_R8_3PLANE_420_UNORM:
    case VK_FORMAT_G8_B8_R8_3PLANE_422_UNORM:
    case VK_FORMAT_G8_B8_R8_3PLANE_444_UNORM:
    case VK_FORMAT_G10X6_B10X6_R10X6_3PLANE_420_UNORM_3PACK16:
    case VK_FORMAT_G16_B16_R16_3PLANE_420_UNORM: return 3;
    default: return 1;
    }
}


// A LINEAR entry for a format that phone-decoded video imports (docs/gpu-media.md):
// the image behind it is an optimal image on the device, so it has the device's
// optimal features, never disjoint (a dma-buf import is one allocation).
bool cabooseLinearModifier(VkFormat format, VkFormatFeatureFlags optimal,
                           VkDrmFormatModifierPropertiesEXT* out) {
    const VkFormatFeatureFlags features = optimal & ~VK_FORMAT_FEATURE_DISJOINT_BIT;
    if (caboosePlaneFormat(format) == caboose::media::PlaneFormat::unsupported || !features) return false;
    *out = {DRM_FORMAT_MOD_LINEAR, cabooseFormatPlaneCount(format), features};
    return true;
}

}  // namespace

// The memory types an imported dmabuf may use: device-local, never one the
// driver would map (host-visible), lazily allocated or protected.
uint32_t ResourceTracker::cabooseImportMemoryTypeBits(void* context, VkDevice device, uint32_t candidates) {
    const VkPhysicalDeviceMemoryProperties& props =
        getPhysicalDeviceMemoryProperties(context, device, VK_NULL_HANDLE);
    uint32_t bits = 0;
    for (uint32_t i = 0; i < props.memoryTypeCount && i < 32; ++i) {
        const VkMemoryPropertyFlags flags = props.memoryTypes[i].propertyFlags;
        if ((candidates & (1u << i)) && (flags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) &&
            !(flags & (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_LAZILY_ALLOCATED_BIT |
                       VK_MEMORY_PROPERTY_PROTECTED_BIT)))
            bits |= 1u << i;
    }
    if (bits) return bits;
    // Unified memory with no device-only type: any device-local one will do, since
    // the driver never maps memory that stands for a dmabuf.
    for (uint32_t i = 0; i < props.memoryTypeCount && i < 32; ++i) {
        const VkMemoryPropertyFlags flags = props.memoryTypes[i].propertyFlags;
        if ((candidates & (1u << i)) && (flags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) &&
            !(flags & (VK_MEMORY_PROPERTY_LAZILY_ALLOCATED_BIT | VK_MEMORY_PROPERTY_PROTECTED_BIT)))
            bits |= 1u << i;
    }
    return bits;
}

VkResult ResourceTracker::cabooseAllocateImportedMemory(VkEncoder* enc, VkDevice device,
                                                        const VkMemoryAllocateInfo* pAllocateInfo,
                                                        const VkAllocationCallbacks* pAllocator,
                                                        VkDeviceMemory* pMemory) {
    const VkImportMemoryFdInfoKHR* importFd = vk_find_struct_const(pAllocateInfo, IMPORT_MEMORY_FD_INFO_KHR);
    const VkMemoryDedicatedAllocateInfo* dedicated =
        vk_find_struct_const(pAllocateInfo, MEMORY_DEDICATED_ALLOCATE_INFO);
    // The device has no dmabufs: only an image created over one can stand for it.
    const auto reject = [&](const char* reason) {
        fprintf(stderr, "CABOOSE_DMABUF_IMPORT_REJECT reason=%s linear=1 size=%llu type=%u\n", reason,
                (unsigned long long)pAllocateInfo->allocationSize, pAllocateInfo->memoryTypeIndex);
        return VK_ERROR_INVALID_EXTERNAL_HANDLE;
    };
    if (!importFd || importFd->fd < 0 || !dedicated || dedicated->image == VK_NULL_HANDLE ||
        dedicated->buffer != VK_NULL_HANDLE)
        return reject("not-dedicated-image");
    struct stat st;
    if (fstat(importFd->fd, &st) != 0) return reject("fstat");
    const off_t end = lseek(importFd->fd, 0, SEEK_END);
    if (end <= 0) return reject("size");
    const size_t size = static_cast<size_t>(end);

    uint32_t typeBits = 0;
    {
        std::lock_guard<ResourceTracker::TrackerMutex> lock(mLock);
        auto it = info_VkImage.find(dedicated->image);
        if (it == info_VkImage.end() || !it->second.cabooseDmabuf || it->second.device != device)
            return reject("image");
        typeBits = it->second.cabooseMemoryTypeBits;
    }
    VkMemoryDedicatedAllocateInfo hostDedicated = vk_make_orphan_copy(*dedicated);
    VkMemoryAllocateInfo hostInfo = vk_make_orphan_copy(*pAllocateInfo);
    vk_struct_chain_iterator chain = vk_make_chain_iterator(&hostInfo);
    vk_append_struct(&chain, &hostDedicated);
    // Never a host-visible type: the device memory holds what latches put there.
    if (!(typeBits & (1u << hostInfo.memoryTypeIndex))) {
        if (!typeBits) return reject("memory-type");
        hostInfo.memoryTypeIndex = static_cast<uint32_t>(__builtin_ctz(typeBits));
    }

    VkResult res = enc->vkAllocateMemory(device, &hostInfo, pAllocator, pMemory, true /* do lock */);
    if (res != VK_SUCCESS) return res;

    // A dmabuf that cannot be mapped is still imported; the device image keeps
    // whatever it last received (nothing, for such a buffer).
    void* map = mmap(nullptr, size, PROT_READ, MAP_SHARED, importFd->fd, 0);
    if (map == MAP_FAILED) {
        mesa_logw("caboose: dmabuf of %zu bytes cannot be mapped: %s", size, strerror(errno));
        map = nullptr;
    }
    // Per the specification the implementation now owns the descriptor; it is
    // closed when the memory is freed.
    setDeviceMemoryInfo(device, *pMemory, 0, nullptr, hostInfo.memoryTypeIndex, nullptr,
                        true /* imported */, ZX_HANDLE_INVALID, nullptr, importFd->fd);
    std::lock_guard<ResourceTracker::TrackerMutex> lock(mLock);
    CabooseImport& import = mCabooseImports[*pMemory];
    import.device = device;
    import.image = dedicated->image;
    import.map = static_cast<const uint8_t*>(map);
    import.size = size;
    auto dev = info_VkDevice.find(device);
    if (dev != info_VkDevice.end())
        emitDeviceMemoryReport(dev->second, VK_DEVICE_MEMORY_REPORT_EVENT_TYPE_IMPORT_EXT,
                               (uint64_t)(void*)*pMemory, pAllocateInfo->allocationSize,
                               VK_OBJECT_TYPE_DEVICE_MEMORY, (uint64_t)(void*)*pMemory,
                               hostInfo.memoryTypeIndex);
    return VK_SUCCESS;
}

void ResourceTracker::cabooseForgetMemory(VkDeviceMemory memory) {
    VkImage image = VK_NULL_HANDLE;
    {
        std::lock_guard<ResourceTracker::TrackerMutex> lock(mLock);
        auto it = mCabooseImports.find(memory);
        if (it == mCabooseImports.end()) return;
        if (it->second.map) munmap(const_cast<uint8_t*>(it->second.map), it->second.size);
        image = it->second.image;
        mCabooseImports.erase(it);
    }
    std::lock_guard<std::mutex> latch(mCabooseLatchMutex);
    mCabooseLatchState.erase(image);
}

void ResourceTracker::cabooseForgetImage(VkImage image) {
    {
        std::lock_guard<ResourceTracker::TrackerMutex> lock(mLock);
        for (auto& [memory, import] : mCabooseImports)
            if (import.image == image) import.image = VK_NULL_HANDLE;
    }
    std::lock_guard<std::mutex> latch(mCabooseLatchMutex);
    mCabooseLatchState.erase(image);
}

void ResourceTracker::cabooseRecordImageBind(VkImage image, VkDeviceMemory memory, VkDeviceSize offset) {
    std::lock_guard<ResourceTracker::TrackerMutex> lock(mLock);
    auto it = mCabooseImports.find(memory);
    if (it == mCabooseImports.end()) return;
    it->second.image = image;
    it->second.bindOffset = offset;
}

VkResult ResourceTracker::cabooseLatchMedia(VkEncoder* enc, VkQueue queue) {
    if (usingDirectMapping()) return VK_SUCCESS;
    const VkDevice device = cabooseGetQueueDevice(queue);
    if (device == VK_NULL_HANDLE) return VK_SUCCESS;

    struct Candidate {
        VkImage image;
        caboose::media::ImageDesc desc;
        const uint8_t* map;
        size_t size;
        VkDeviceMemory memory;
    };
    std::vector<Candidate> candidates;
    {
        std::lock_guard<ResourceTracker::TrackerMutex> lock(mLock);
        if (mCabooseImports.empty()) return VK_SUCCESS;
        for (auto& [memory, import] : mCabooseImports) {
            if (import.device != device || import.image == VK_NULL_HANDLE) continue;
            auto image = info_VkImage.find(import.image);
            if (image == info_VkImage.end() || !image->second.cabooseDmabuf) continue;
            caboose::media::ImageDesc desc = image->second.cabooseDesc;
            for (uint32_t p = 0; p < desc.planeCount; ++p) desc.offset[p] += import.bindOffset;
            candidates.push_back({import.image, desc, import.map, import.size, memory});
        }
    }
    if (candidates.empty()) return VK_SUCCESS;

    std::lock_guard<std::mutex> latch(mCabooseLatchMutex);
    std::vector<caboose::media::Entry> entries;
    for (const Candidate& c : candidates) {
        caboose::media::Entry entry;
        auto decision = caboose::media::evaluate(get_host_u64_VkImage(c.image), c.desc, c.map, c.size,
                                                 &mCabooseLatchState[c.image], &entry);
        if (decision == caboose::media::Decision::latch &&
            CB_GM_LATCH_HEAD + caboose::media::encodedSize(entry) > CB_GM_LATCH_MAX_PACKET) {
            // The phone's stream reader takes packets of at most 16 MiB: pixels that do not
            // fit (4K 10-bit and larger) are not carried, and the image keeps its contents.
            std::lock_guard<ResourceTracker::TrackerMutex> lock(mLock);
            auto it = mCabooseImports.find(c.memory);
            if (it != mCabooseImports.end() && !it->second.reportedMismatch) {
                it->second.reportedMismatch = true;
                mesa_logw("caboose: an imported dmabuf's pixels exceed a latch packet; "
                          "the image is not filled");
            }
        } else if (decision == caboose::media::Decision::latch) {
            entries.push_back(std::move(entry));
        } else if (decision == caboose::media::Decision::mismatch) {
            std::lock_guard<ResourceTracker::TrackerMutex> lock(mLock);
            auto it = mCabooseImports.find(c.memory);
            if (it != mCabooseImports.end() && !it->second.reportedMismatch) {
                it->second.reportedMismatch = true;
                mesa_logw("caboose: an imported dmabuf's layout does not describe its picture; "
                          "the image is not filled");
            }
        }
    }
    for (const auto& packet : caboose::media::encodeLatches(get_host_u64_VkQueue(queue), entries)) {
        if (!enc->cabooseWritePrivatePacket(packet.data(), packet.size(), true /* do lock */))
            return VK_ERROR_DEVICE_LOST;
    }
    return VK_SUCCESS;
}
