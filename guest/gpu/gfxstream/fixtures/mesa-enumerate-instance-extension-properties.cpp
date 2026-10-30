VkResult VkEncoder::vkEnumerateInstanceExtensionProperties(const char* pLayerName,
                                                           uint32_t* pPropertyCount,
                                                           VkExtensionProperties* pProperties,
                                                           uint32_t doLock) {
    (void)doLock;
    bool queueSubmitWithCommandsEnabled =
        sFeatureBits & VULKAN_STREAM_FEATURE_QUEUE_SUBMIT_WITH_COMMANDS_BIT;
    if (!queueSubmitWithCommandsEnabled && doLock) this->lock();
    auto stream = mImpl->stream();
    auto pool = mImpl->pool();
    char* local_pLayerName;
    // Avoiding deepcopy for pLayerName
    local_pLayerName = (char*)pLayerName;
    size_t count = 0;
    size_t* countPtr = &count;
    {
        if (sFeatureBits & VULKAN_STREAM_FEATURE_NULL_OPTIONAL_STRINGS_BIT) {
            // WARNING PTR CHECK
            *countPtr += 8;
            if (local_pLayerName) {
                *countPtr += sizeof(uint32_t) + (local_pLayerName ? strlen(local_pLayerName) : 0);
            }
        } else {
            *countPtr += sizeof(uint32_t) + (local_pLayerName ? strlen(local_pLayerName) : 0);
        }
        // WARNING PTR CHECK
        *countPtr += 8;
        if (pPropertyCount) {
            *countPtr += sizeof(uint32_t);
        }
        // WARNING PTR CHECK
        *countPtr += 8;
        if (pProperties) {
            if (pPropertyCount) {
                for (uint32_t i = 0; i < (uint32_t)(*pPropertyCount); ++i) {
                    count_VkExtensionProperties(sFeatureBits, VK_STRUCTURE_TYPE_MAX_ENUM,
                                                (VkExtensionProperties*)(pProperties + i),
                                                countPtr);
                }
            }
        }
    }
    uint32_t packetSize_vkEnumerateInstanceExtensionProperties =
        4 + 4 + (queueSubmitWithCommandsEnabled ? 4 : 0) + count;
    uint8_t* streamPtr = stream->reserve(packetSize_vkEnumerateInstanceExtensionProperties);
    uint8_t** streamPtrPtr = &streamPtr;
    uint32_t opcode_vkEnumerateInstanceExtensionProperties =
        OP_vkEnumerateInstanceExtensionProperties;
    uint32_t seqno;
    if (queueSubmitWithCommandsEnabled) seqno = ResourceTracker::nextSeqno();
    memcpy(streamPtr, &opcode_vkEnumerateInstanceExtensionProperties, sizeof(uint32_t));
    streamPtr += sizeof(uint32_t);
    memcpy(streamPtr, &packetSize_vkEnumerateInstanceExtensionProperties, sizeof(uint32_t));
    streamPtr += sizeof(uint32_t);
    if (queueSubmitWithCommandsEnabled) {
        memcpy(streamPtr, &seqno, sizeof(uint32_t));
        streamPtr += sizeof(uint32_t);
    }
    if (stream->getFeatureBits() & VULKAN_STREAM_FEATURE_NULL_OPTIONAL_STRINGS_BIT) {
        // WARNING PTR CHECK
        uint64_t cgen_var_0 = (uint64_t)(uintptr_t)local_pLayerName;
        memcpy((*streamPtrPtr), &cgen_var_0, 8);
        gfxstream::aemu::Stream::toBe64((uint8_t*)(*streamPtrPtr));
        *streamPtrPtr += 8;
        if (local_pLayerName) {
            {
                uint32_t l = local_pLayerName ? strlen(local_pLayerName) : 0;
                memcpy(*streamPtrPtr, (uint32_t*)&l, sizeof(uint32_t));
                gfxstream::aemu::Stream::toBe32((uint8_t*)*streamPtrPtr);
                *streamPtrPtr += sizeof(uint32_t);
                memcpy(*streamPtrPtr, (char*)local_pLayerName, l);
                *streamPtrPtr += l;
            }
        }
    } else {
        {
            uint32_t l = local_pLayerName ? strlen(local_pLayerName) : 0;
            memcpy(*streamPtrPtr, (uint32_t*)&l, sizeof(uint32_t));
            gfxstream::aemu::Stream::toBe32((uint8_t*)*streamPtrPtr);
            *streamPtrPtr += sizeof(uint32_t);
            memcpy(*streamPtrPtr, (char*)local_pLayerName, l);
            *streamPtrPtr += l;
        }
    }
    // WARNING PTR CHECK
    uint64_t cgen_var_0 = (uint64_t)(uintptr_t)pPropertyCount;
    memcpy((*streamPtrPtr), &cgen_var_0, 8);
    gfxstream::aemu::Stream::toBe64((uint8_t*)(*streamPtrPtr));
    *streamPtrPtr += 8;
    if (pPropertyCount) {
        memcpy(*streamPtrPtr, (uint32_t*)pPropertyCount, sizeof(uint32_t));
        *streamPtrPtr += sizeof(uint32_t);
    }
    // WARNING PTR CHECK
    uint64_t cgen_var_1 = (uint64_t)(uintptr_t)pProperties;
    memcpy((*streamPtrPtr), &cgen_var_1, 8);
    gfxstream::aemu::Stream::toBe64((uint8_t*)(*streamPtrPtr));
    *streamPtrPtr += 8;
    if (pProperties) {
        for (uint32_t i = 0; i < (uint32_t)(*pPropertyCount); ++i) {
            reservedmarshal_VkExtensionProperties(stream, VK_STRUCTURE_TYPE_MAX_ENUM,
                                                  (VkExtensionProperties*)(pProperties + i),
                                                  streamPtrPtr);
        }
    }
    // WARNING PTR CHECK
    uint32_t* check_pPropertyCount;
    (void)check_pPropertyCount;
    check_pPropertyCount = (uint32_t*)(uintptr_t)stream->getBe64();
    if (pPropertyCount) {
        if (!(check_pPropertyCount)) {
            fprintf(stderr, "fatal: pPropertyCount inconsistent between guest and host\n");
        }
        stream->read((uint32_t*)pPropertyCount, sizeof(uint32_t));
    }
    // WARNING PTR CHECK
    VkExtensionProperties* check_pProperties;
    (void)check_pProperties;
    check_pProperties = (VkExtensionProperties*)(uintptr_t)stream->getBe64();
    if (pProperties) {
        if (!(check_pProperties)) {
            fprintf(stderr, "fatal: pProperties inconsistent between guest and host\n");
        }
        if (pPropertyCount) {
            for (uint32_t i = 0; i < (uint32_t)(*pPropertyCount); ++i) {
                unmarshal_VkExtensionProperties(stream, VK_STRUCTURE_TYPE_MAX_ENUM,
                                                (VkExtensionProperties*)(pProperties + i));
            }
        }
    }
    if (pPropertyCount) {
        if (pProperties) {
            for (uint32_t i = 0; i < (uint32_t)(*pPropertyCount); ++i) {
                transform_fromhost_VkExtensionProperties(sResourceTracker,
                                                         (VkExtensionProperties*)(pProperties + i));
            }
        }
    }
    VkResult vkEnumerateInstanceExtensionProperties_VkResult_return = (VkResult)0;
    stream->read(&vkEnumerateInstanceExtensionProperties_VkResult_return, sizeof(VkResult));
    ++encodeCount;
    if (0 == encodeCount % POOL_CLEAR_INTERVAL) {
        pool->freeAll();
        stream->clearPool();
    }
    if (!queueSubmitWithCommandsEnabled && doLock) this->unlock();
    return vkEnumerateInstanceExtensionProperties_VkResult_return;
