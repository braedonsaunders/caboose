// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "caboose_pipeline_cache.h"

#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <unistd.h>
#include <vector>

using namespace caboose::gpuv2;

namespace {

void writeLe32(uint8_t* p, uint32_t v) {
    p[0] = static_cast<uint8_t>(v & 0xffu);
    p[1] = static_cast<uint8_t>((v >> 8) & 0xffu);
    p[2] = static_cast<uint8_t>((v >> 16) & 0xffu);
    p[3] = static_cast<uint8_t>((v >> 24) & 0xffu);
}

VkPhysicalDeviceProperties makeTestProps(uint32_t vendor = 0x106bu,
                                         uint32_t device = 0x0001u,
                                         uint32_t driver = 0x00010402u) {
    VkPhysicalDeviceProperties props{};
    props.vendorID = vendor;
    props.deviceID = device;
    props.driverVersion = driver;
    for (uint32_t i = 0; i < VK_UUID_SIZE; ++i) {
        props.pipelineCacheUUID[i] = static_cast<uint8_t>(0xa0u + i);
    }
    return props;
}

std::vector<uint8_t> makeValidCacheBlob(const VkPhysicalDeviceProperties& props,
                                        const std::vector<uint8_t>& payload) {
    std::vector<uint8_t> blob(PersistentPipelineCache::kMinHeaderBytes + payload.size(), 0);
    writeLe32(blob.data() + 0, static_cast<uint32_t>(PersistentPipelineCache::kMinHeaderBytes));
    writeLe32(blob.data() + 4, static_cast<uint32_t>(VK_PIPELINE_CACHE_HEADER_VERSION_ONE));
    writeLe32(blob.data() + 8, props.vendorID);
    writeLe32(blob.data() + 12, props.deviceID);
    std::memcpy(blob.data() + 16, props.pipelineCacheUUID, VK_UUID_SIZE);
    if (!payload.empty()) {
        std::memcpy(blob.data() + PersistentPipelineCache::kMinHeaderBytes,
                    payload.data(), payload.size());
    }
    return blob;
}

struct FakeVulkanDispatch {
    VkPhysicalDeviceProperties props{};
    uintptr_t nextHandle = 0x1000u;
    bool failNonEmptyInitialData = false;
    uint32_t createCalls = 0;
    uint32_t destroyCalls = 0;
    uint32_t mergeCalls = 0;
    uint32_t getDataCalls = 0;
    std::map<VkPipelineCache, std::vector<uint8_t>> cachePayloads;

    explicit FakeVulkanDispatch(const VkPhysicalDeviceProperties& p) : props(p) {}

    VkResult vkCreatePipelineCache(VkDevice device,
                                   const VkPipelineCacheCreateInfo* pCreateInfo,
                                   const VkAllocationCallbacks*,
                                   VkPipelineCache* pPipelineCache) {
        assert(device != VK_NULL_HANDLE);
        assert(pCreateInfo != nullptr);
        assert(pPipelineCache != nullptr);
        ++createCalls;
        if (pCreateInfo->initialDataSize > 0 && failNonEmptyInitialData) {
            return VK_ERROR_INITIALIZATION_FAILED;
        }
        VkPipelineCache h = reinterpret_cast<VkPipelineCache>(nextHandle++);
        std::vector<uint8_t> payload;
        if (pCreateInfo->initialDataSize >= PersistentPipelineCache::kMinHeaderBytes &&
            pCreateInfo->pInitialData != nullptr) {
            const auto* bytes = static_cast<const uint8_t*>(pCreateInfo->pInitialData);
            payload.assign(bytes + PersistentPipelineCache::kMinHeaderBytes,
                           bytes + pCreateInfo->initialDataSize);
        }
        cachePayloads[h] = std::move(payload);
        *pPipelineCache = h;
        return VK_SUCCESS;
    }

    void vkDestroyPipelineCache(VkDevice device,
                                VkPipelineCache pipelineCache,
                                const VkAllocationCallbacks*) {
        assert(device != VK_NULL_HANDLE);
        if (pipelineCache != VK_NULL_HANDLE) {
            ++destroyCalls;
            cachePayloads.erase(pipelineCache);
        }
    }

    VkResult vkMergePipelineCaches(VkDevice device,
                                   VkPipelineCache dstCache,
                                   uint32_t srcCacheCount,
                                   const VkPipelineCache* pSrcCaches) {
        assert(device != VK_NULL_HANDLE);
        assert(dstCache != VK_NULL_HANDLE);
        ++mergeCalls;
        auto& dst = cachePayloads[dstCache];
        for (uint32_t i = 0; i < srcCacheCount; ++i) {
            const auto it = cachePayloads.find(pSrcCaches[i]);
            if (it != cachePayloads.end()) {
                dst.insert(dst.end(), it->second.begin(), it->second.end());
            }
        }
        return VK_SUCCESS;
    }

    VkResult vkGetPipelineCacheData(VkDevice device,
                                    VkPipelineCache pipelineCache,
                                    size_t* pDataSize,
                                    void* pData) {
        assert(device != VK_NULL_HANDLE);
        assert(pDataSize != nullptr);
        ++getDataCalls;
        const auto it = cachePayloads.find(pipelineCache);
        if (it == cachePayloads.end()) return VK_ERROR_DEVICE_LOST;
        const auto blob = makeValidCacheBlob(props, it->second);
        if (!pData) {
            *pDataSize = blob.size();
            return VK_SUCCESS;
        }
        if (*pDataSize < blob.size()) {
            std::memcpy(pData, blob.data(), *pDataSize);
            return VK_INCOMPLETE;
        }
        std::memcpy(pData, blob.data(), blob.size());
        *pDataSize = blob.size();
        return VK_SUCCESS;
    }
};

} // namespace

int main() {
    // 1. Concurrent compilation environment variable + Metal device toggle.
    (void)enableConcurrentShaderCompilation();
    const char* mvkConcurrent = std::getenv("MVK_CONFIG_SHOULD_MAXIMIZE_CONCURRENT_COMPILATION");
    assert(mvkConcurrent != nullptr && std::strcmp(mvkConcurrent, "1") == 0);

    // 2. Blob header validation.
    const VkPhysicalDeviceProperties props = makeTestProps();
    const auto validBlob = makeValidCacheBlob(props, {1, 2, 3, 4, 5});
    assert(PersistentPipelineCache::validateBlobHeader(validBlob.data(), validBlob.size(), props));
    assert(!PersistentPipelineCache::validateBlobHeader(validBlob.data(), 16, props));

    auto badVersion = validBlob;
    writeLe32(badVersion.data() + 4, 99u);
    assert(!PersistentPipelineCache::validateBlobHeader(badVersion.data(), badVersion.size(), props));

    auto badVendor = validBlob;
    writeLe32(badVendor.data() + 8, 0x9999u);
    assert(!PersistentPipelineCache::validateBlobHeader(badVendor.data(), badVendor.size(), props));

    auto badUuid = validBlob;
    badUuid[16 + VK_UUID_SIZE - 1] ^= 0xffu;
    assert(!PersistentPipelineCache::validateBlobHeader(badUuid.data(), badUuid.size(), props));

    // 3. Create temp directory for end-to-end persistence and recovery tests.
    char dirTemplate[] = "/tmp/caboose-pipeline-cache-test-XXXXXX";
    char* testDir = mkdtemp(dirTemplate);
    assert(testDir != nullptr);

    const VkDevice fakeDevice = reinterpret_cast<VkDevice>(0xdeadbeefu);
    FakeVulkanDispatch vk(props);

    std::string savedPath;
    {
        PersistentPipelineCache cache;
        assert(cache.initialize(&vk, fakeDevice, props, testDir));
        assert(cache.handle() != VK_NULL_HANDLE);
        savedPath = cache.path();
        assert(!savedPath.empty());
        assert(cache.stats().loaded_from_disk_count == 0);

        // Null guest cache is substituted with the persistent host cache.
        const VkPipelineCache effective = cache.effectiveCacheForCreate(VK_NULL_HANDLE);
        assert(effective == cache.handle());

        // Simulate pipeline compilation populating the persistent cache.
        vk.cachePayloads[cache.handle()] = {0x11, 0x22, 0x33, 0x44};
        cache.onPipelinesCreated(&vk, VK_NULL_HANDLE, 2, /*isCompute=*/false);
        assert(cache.stats().graphics_pipeline_calls == 1);
        assert(cache.stats().graphics_pipeline_count == 2);
        assert(cache.stats().graphics_null_cache_substituted == 1);
        assert(cache.stats().saved_to_disk_count == 0); // < kAutoSaveCompileInterval (4)

        // Reaching kAutoSaveCompileInterval triggers an automatic atomic save to disk.
        vk.cachePayloads[cache.handle()].push_back(0x55);
        cache.onPipelinesCreated(&vk, VK_NULL_HANDLE, 2, /*isCompute=*/true);
        assert(cache.stats().compute_pipeline_calls == 1);
        assert(cache.stats().compute_pipeline_count == 2);
        assert(cache.stats().compute_null_cache_substituted == 1);
        assert(cache.stats().saved_to_disk_count == 1);

        // Saving again without changes skips disk write.
        assert(cache.saveToDisk(&vk));
        assert(cache.stats().save_skipped_unchanged_count == 1);
        assert(cache.stats().saved_to_disk_count == 1);

        // Guest-created cache is seeded from the persistent cache and merged back on pipeline creation.
        VkPipelineCache guestCache = VK_NULL_HANDLE;
        VkPipelineCacheCreateInfo guestCi{};
        guestCi.sType = VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO;
        assert(vk.vkCreatePipelineCache(fakeDevice, &guestCi, nullptr, &guestCache) == VK_SUCCESS);
        cache.seedGuestCache(&vk, guestCache);
        assert(cache.stats().guest_cache_seeded_count == 1);
        assert(vk.cachePayloads[guestCache].size() == 5);
        assert(cache.effectiveCacheForCreate(guestCache) == guestCache);

        vk.cachePayloads[guestCache].push_back(0x66);
        cache.onPipelinesCreated(&vk, guestCache, 1, /*isCompute=*/false);
        assert(cache.stats().graphics_guest_cache_merged == 1);

        // Shutdown flushes dirty changes and destroys the persistent VkPipelineCache.
        cache.shutdown(&vk);
        assert(cache.handle() == VK_NULL_HANDLE);
        assert(cache.stats().saved_to_disk_count == 2);
        vk.vkDestroyPipelineCache(fakeDevice, guestCache, nullptr);
    }

    // 4. Reload from disk on next device creation and verify warm payload is restored.
    {
        FakeVulkanDispatch vk2(props);
        PersistentPipelineCache cache2;
        assert(cache2.initialize(&vk2, fakeDevice, props, testDir));
        assert(cache2.stats().loaded_from_disk_count == 1);
        assert(cache2.stats().loaded_from_disk_bytes > PersistentPipelineCache::kMinHeaderBytes);
        assert(!vk2.cachePayloads[cache2.handle()].empty());
        cache2.shutdown(&vk2);
    }

    // 5. If driver rejects non-empty initial data, initialize falls back to an empty cache cleanly.
    {
        FakeVulkanDispatch vk3(props);
        vk3.failNonEmptyInitialData = true;
        PersistentPipelineCache cache3;
        assert(cache3.initialize(&vk3, fakeDevice, props, testDir));
        assert(cache3.handle() != VK_NULL_HANDLE);
        assert(cache3.stats().loaded_from_disk_count == 0);
        assert(vk3.createCalls == 2); // 1 failed with data + 1 succeeded empty
        cache3.shutdown(&vk3);
    }

    // 6. Corrupt file on disk is ignored safely.
    {
        std::FILE* fp = std::fopen(savedPath.c_str(), "wb");
        assert(fp != nullptr);
        const char garbage[] = "corrupt-header";
        std::fwrite(garbage, 1, sizeof(garbage), fp);
        std::fclose(fp);

        FakeVulkanDispatch vk4(props);
        PersistentPipelineCache cache4;
        assert(cache4.initialize(&vk4, fakeDevice, props, testDir));
        assert(cache4.handle() != VK_NULL_HANDLE);
        assert(cache4.stats().loaded_from_disk_count == 0);
        cache4.shutdown(&vk4);
    }

    std::remove(savedPath.c_str());
    rmdir(testDir);
    std::puts("persistent pipeline cache PASS");
    return 0;
}
