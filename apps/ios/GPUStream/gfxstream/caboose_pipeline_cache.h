// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once

#include <vulkan/vulkan.h>

#ifdef __APPLE__
#include <dlfcn.h>
#include <objc/message.h>
#include <objc/runtime.h>
#endif

#ifdef _WIN32
#include <direct.h>
#include <io.h>
#else
#include <sys/stat.h>
#include <unistd.h>
#endif

#include <atomic>
#include <cinttypes>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

namespace caboose::gpuv2 {

struct PipelineCacheStatsSnapshot {
    uint64_t loaded_from_disk_count = 0;
    uint64_t loaded_from_disk_bytes = 0;
    uint64_t saved_to_disk_count = 0;
    uint64_t saved_to_disk_bytes = 0;
    uint64_t save_skipped_unchanged_count = 0;
    uint64_t graphics_pipeline_calls = 0;
    uint64_t graphics_pipeline_count = 0;
    uint64_t graphics_null_cache_substituted = 0;
    uint64_t graphics_guest_cache_merged = 0;
    uint64_t compute_pipeline_calls = 0;
    uint64_t compute_pipeline_count = 0;
    uint64_t compute_null_cache_substituted = 0;
    uint64_t compute_guest_cache_merged = 0;
    uint64_t guest_cache_seeded_count = 0;
};

// Enables concurrent shader/pipeline compilation in MoltenVK and on the underlying
// Apple MTLDevice singleton (MoltenVK 1.4.2 only calls setShouldMaximizeConcurrentCompilation:
// under #if MVK_MACOS, leaving iOS single-threaded unless explicitly enabled on MTLDevice).
inline bool enableConcurrentShaderCompilation() noexcept {
#ifndef _WIN32
    setenv("MVK_CONFIG_SHOULD_MAXIMIZE_CONCURRENT_COMPILATION", "1", 0);
#endif
#ifdef __APPLE__
    using CreateSystemDefaultDeviceFn = void* (*)();
    auto createDev = reinterpret_cast<CreateSystemDefaultDeviceFn>(
        dlsym(RTLD_DEFAULT, "MTLCreateSystemDefaultDevice"));
    if (!createDev) {
        return false;
    }
    void* mtlDevice = createDev();
    if (!mtlDevice) {
        return false;
    }
    const SEL setConcurrentSel = sel_registerName("setShouldMaximizeConcurrentCompilation:");
    const SEL respondsSel = sel_registerName("respondsToSelector:");
    auto respondsFn = reinterpret_cast<bool (*)(void*, SEL, SEL)>(objc_msgSend);
    if (respondsFn(mtlDevice, respondsSel, setConcurrentSel)) {
        auto setFn = reinterpret_cast<void (*)(void*, SEL, bool)>(objc_msgSend);
        setFn(mtlDevice, setConcurrentSel, true);
    }
    const SEL getConcurrentSel = sel_registerName("shouldMaximizeConcurrentCompilation");
    if (respondsFn(mtlDevice, respondsSel, getConcurrentSel)) {
        auto getFn = reinterpret_cast<bool (*)(void*, SEL)>(objc_msgSend);
        const bool enabled = getFn(mtlDevice, getConcurrentSel);
        auto releaseFn = reinterpret_cast<void (*)(void*, SEL)>(objc_msgSend);
        releaseFn(mtlDevice, sel_registerName("release"));
        return enabled;
    }
    auto releaseFn = reinterpret_cast<void (*)(void*, SEL)>(objc_msgSend);
    releaseFn(mtlDevice, sel_registerName("release"));
    return true;
#else
    return false;
#endif
}

class PersistentPipelineCache {
public:
    static constexpr size_t kMinHeaderBytes = 16u + VK_UUID_SIZE; // 32 bytes
    static constexpr size_t kMaxCacheFileBytes = 64u * 1024u * 1024u; // 64 MiB safety cap
    static constexpr uint32_t kAutoSaveCompileInterval = 4u;

    static uint32_t readLe32(const uint8_t* p) noexcept {
        return static_cast<uint32_t>(p[0]) |
               (static_cast<uint32_t>(p[1]) << 8) |
               (static_cast<uint32_t>(p[2]) << 16) |
               (static_cast<uint32_t>(p[3]) << 24);
    }

    static bool validateBlobHeader(const uint8_t* data, size_t size,
                                   const VkPhysicalDeviceProperties& props) noexcept {
        if (!data || size < kMinHeaderBytes || size > kMaxCacheFileBytes) {
            return false;
        }
        const uint32_t headerSize = readLe32(data);
        const uint32_t headerVersion = readLe32(data + 4);
        const uint32_t vendorID = readLe32(data + 8);
        const uint32_t deviceID = readLe32(data + 12);
        if (headerSize < kMinHeaderBytes || headerSize > size) {
            return false;
        }
        if (headerVersion != VK_PIPELINE_CACHE_HEADER_VERSION_ONE) {
            return false;
        }
        if (vendorID != props.vendorID || deviceID != props.deviceID) {
            return false;
        }
        if (std::memcmp(data + 16, props.pipelineCacheUUID, VK_UUID_SIZE) != 0) {
            return false;
        }
        return true;
    }

    static std::string cacheFileName(const VkPhysicalDeviceProperties& props) {
        char uuidHex[VK_UUID_SIZE * 2 + 1];
        for (size_t i = 0; i < VK_UUID_SIZE; ++i) {
            std::snprintf(uuidHex + i * 2, 3, "%02x", props.pipelineCacheUUID[i]);
        }
        uuidHex[VK_UUID_SIZE * 2] = '\0';
        char buf[160];
        std::snprintf(buf, sizeof(buf), "caboose-vk-pipeline-cache-v1-%08x-%08x-%08x-%s.bin",
                      props.vendorID, props.deviceID, props.driverVersion, uuidHex);
        return std::string(buf);
    }

    static std::string defaultCacheDirectory() {
        if (const char* envDir = std::getenv("CABOOSE_GPU_PIPELINE_CACHE_DIR")) {
            if (*envDir) return std::string(envDir);
        }
        if (const char* tmpDir = std::getenv("TMPDIR")) {
            if (*tmpDir) {
                std::string dir(tmpDir);
                if (!dir.empty() && dir.back() == '/') dir.pop_back();
                return dir + "/caboose-gpu-pipeline-cache";
            }
        }
        if (const char* homeDir = std::getenv("HOME")) {
            if (*homeDir) {
                std::string dir(homeDir);
                if (!dir.empty() && dir.back() == '/') dir.pop_back();
                return dir + "/Library/Caches/caboose-gpu-pipeline-cache";
            }
        }
        return "/tmp/caboose-gpu-pipeline-cache";
    }

    static std::string resolveCacheFilePath(const VkPhysicalDeviceProperties& props,
                                            const char* overrideDir = nullptr) {
        std::string dir = (overrideDir && *overrideDir) ? std::string(overrideDir)
                                                        : defaultCacheDirectory();
        while (dir.size() > 1 && dir.back() == '/') {
            dir.pop_back();
        }
        ensureDirectoryExists(dir);
        return dir + "/" + cacheFileName(props);
    }

    static void ensureDirectoryExists(const std::string& dir) noexcept {
        if (dir.empty()) return;
        std::string current;
        current.reserve(dir.size());
        for (size_t i = 0; i < dir.size(); ++i) {
            current.push_back(dir[i]);
            if ((dir[i] == '/' && i > 0) || i + 1 == dir.size()) {
#ifdef _WIN32
                _mkdir(current.c_str());
#else
                mkdir(current.c_str(), 0700);
#endif
            }
        }
    }

    static bool readValidatedBlobFromFile(const std::string& path,
                                          const VkPhysicalDeviceProperties& props,
                                          std::vector<uint8_t>& outBlob) noexcept {
        outBlob.clear();
        std::FILE* fp = std::fopen(path.c_str(), "rb");
        if (!fp) return false;
        struct FileGuard {
            std::FILE* f;
            ~FileGuard() { if (f) std::fclose(f); }
        } guard{fp};
        if (std::fseek(fp, 0, SEEK_END) != 0) return false;
        const long len = std::ftell(fp);
        if (len < static_cast<long>(kMinHeaderBytes) ||
            static_cast<size_t>(len) > kMaxCacheFileBytes) {
            return false;
        }
        if (std::fseek(fp, 0, SEEK_SET) != 0) return false;
        try {
            outBlob.resize(static_cast<size_t>(len));
        } catch (...) {
            outBlob.clear();
            return false;
        }
        if (std::fread(outBlob.data(), 1, outBlob.size(), fp) != outBlob.size()) {
            outBlob.clear();
            return false;
        }
        if (!validateBlobHeader(outBlob.data(), outBlob.size(), props)) {
            outBlob.clear();
            return false;
        }
        return true;
    }

    static bool writeBlobAtomically(const std::string& path,
                                    const uint8_t* data,
                                    size_t size) noexcept {
        if (!data || size < kMinHeaderBytes || size > kMaxCacheFileBytes || path.empty()) {
            return false;
        }
        static std::atomic<uint64_t> tmpCounter{1};
        const uint64_t seq = tmpCounter.fetch_add(1, std::memory_order_relaxed);
#ifdef _WIN32
        const int pid = _getpid();
#else
        const int pid = static_cast<int>(getpid());
#endif
        char suffix[64];
        std::snprintf(suffix, sizeof(suffix), ".tmp.%d.%" PRIu64, pid, seq);
        const std::string tmpPath = path + suffix;
        std::FILE* fp = std::fopen(tmpPath.c_str(), "wb");
        if (!fp) return false;
        const size_t written = std::fwrite(data, 1, size, fp);
        const int flushRc = std::fflush(fp);
        const int closeRc = std::fclose(fp);
        if (written != size || flushRc != 0 || closeRc != 0) {
            std::remove(tmpPath.c_str());
            return false;
        }
        if (std::rename(tmpPath.c_str(), path.c_str()) != 0) {
            std::remove(tmpPath.c_str());
            return false;
        }
        return true;
    }

    PersistentPipelineCache() = default;
    PersistentPipelineCache(const PersistentPipelineCache&) = delete;
    PersistentPipelineCache& operator=(const PersistentPipelineCache&) = delete;

    template <typename Dispatch>
    bool initialize(Dispatch* vk, VkDevice device, const VkPhysicalDeviceProperties& props,
                    const char* overrideDir = nullptr) noexcept {
        (void)enableConcurrentShaderCompilation();
        std::lock_guard<std::mutex> lock(mutex_);
        if (cache_ != VK_NULL_HANDLE || !vk || device == VK_NULL_HANDLE) {
            return cache_ != VK_NULL_HANDLE;
        }
        device_ = device;
        props_ = props;
        try {
            path_ = resolveCacheFilePath(props_, overrideDir);
        } catch (...) {
            path_.clear();
        }
        std::vector<uint8_t> initialBlob;
        const bool hadDiskBlob = !path_.empty() &&
                                 readValidatedBlobFromFile(path_, props_, initialBlob);

        VkPipelineCacheCreateInfo ci{};
        ci.sType = VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO;
        ci.flags = 0; // Internally synchronized in MoltenVK
        ci.initialDataSize = initialBlob.size();
        ci.pInitialData = initialBlob.empty() ? nullptr : initialBlob.data();

        VkPipelineCache created = VK_NULL_HANDLE;
        VkResult res = vk->vkCreatePipelineCache(device_, &ci, nullptr, &created);
        if ((res != VK_SUCCESS || created == VK_NULL_HANDLE) && !initialBlob.empty()) {
            // Corrupt cereal archive inside an otherwise header-valid file: fall back to empty cache.
            ci.initialDataSize = 0;
            ci.pInitialData = nullptr;
            created = VK_NULL_HANDLE;
            res = vk->vkCreatePipelineCache(device_, &ci, nullptr, &created);
        } else if (res == VK_SUCCESS && created != VK_NULL_HANDLE && hadDiskBlob) {
            lastSavedSize_ = initialBlob.size();
            lastSavedHash_ = fnv1a64(initialBlob.data(), initialBlob.size());
            stats_.loaded_from_disk_count += 1;
            stats_.loaded_from_disk_bytes += initialBlob.size();
        }
        if (res != VK_SUCCESS || created == VK_NULL_HANDLE) {
            return false;
        }
        cache_ = created;
        return true;
    }

    VkPipelineCache handle() const noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        return cache_;
    }

    std::string path() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return path_;
    }

    PipelineCacheStatsSnapshot stats() const noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        return stats_;
    }

    // Seed a newly created guest VkPipelineCache with the persistent device cache so guest
    // pipelines using that cache hit pre-compiled shaders immediately.
    template <typename Dispatch>
    void seedGuestCache(Dispatch* vk, VkPipelineCache guestCache) noexcept {
        if (!vk || guestCache == VK_NULL_HANDLE) return;
        VkPipelineCache src = VK_NULL_HANDLE;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (cache_ == VK_NULL_HANDLE || guestCache == cache_) return;
            src = cache_;
            stats_.guest_cache_seeded_count += 1;
        }
        (void)vk->vkMergePipelineCaches(device_, guestCache, 1, &src);
    }

    // Merge a guest VkPipelineCache back into the persistent cache (e.g. before guest cache destroy
    // or after guest vkMergePipelineCaches).
    template <typename Dispatch>
    void absorbGuestCache(Dispatch* vk, VkPipelineCache guestCache, bool flushImmediately = false) noexcept {
        if (!vk || guestCache == VK_NULL_HANDLE) return;
        VkPipelineCache dst = VK_NULL_HANDLE;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (cache_ == VK_NULL_HANDLE || guestCache == cache_) return;
            dst = cache_;
        }
        if (vk->vkMergePipelineCaches(device_, dst, 1, &guestCache) == VK_SUCCESS) {
            bool doSave = flushImmediately;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                dirty_ = true;
                unsavedCompilations_ += 1;
                if (unsavedCompilations_ >= kAutoSaveCompileInterval) {
                    doSave = true;
                }
            }
            if (doSave) {
                (void)saveToDisk(vk);
            }
        }
    }

    // Called around vkCreateGraphicsPipelines / vkCreateComputePipelines.
    // Returns the VkPipelineCache to pass to the underlying driver (substituting the persistent
    // cache when guestCache == VK_NULL_HANDLE).
    VkPipelineCache effectiveCacheForCreate(VkPipelineCache guestCache) const noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        if (guestCache != VK_NULL_HANDLE) return guestCache;
        return cache_;
    }

    template <typename Dispatch>
    void onPipelinesCreated(Dispatch* vk, VkPipelineCache guestCache,
                            uint32_t createInfoCount, bool isCompute) noexcept {
        if (!vk || createInfoCount == 0) return;
        VkPipelineCache dst = VK_NULL_HANDLE;
        bool needMerge = false;
        bool shouldSave = false;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (cache_ == VK_NULL_HANDLE) return;
            dst = cache_;
            if (isCompute) {
                stats_.compute_pipeline_calls += 1;
                stats_.compute_pipeline_count += createInfoCount;
                if (guestCache == VK_NULL_HANDLE) {
                    stats_.compute_null_cache_substituted += 1;
                } else if (guestCache != cache_) {
                    stats_.compute_guest_cache_merged += 1;
                    needMerge = true;
                }
            } else {
                stats_.graphics_pipeline_calls += 1;
                stats_.graphics_pipeline_count += createInfoCount;
                if (guestCache == VK_NULL_HANDLE) {
                    stats_.graphics_null_cache_substituted += 1;
                } else if (guestCache != cache_) {
                    stats_.graphics_guest_cache_merged += 1;
                    needMerge = true;
                }
            }
            dirty_ = true;
            unsavedCompilations_ += createInfoCount;
            if (unsavedCompilations_ >= kAutoSaveCompileInterval) {
                shouldSave = true;
            }
        }
        if (needMerge) {
            (void)vk->vkMergePipelineCaches(device_, dst, 1, &guestCache);
        }
        if (shouldSave) {
            (void)saveToDisk(vk);
        }
    }

    template <typename Dispatch>
    bool saveToDisk(Dispatch* vk) noexcept {
        if (!vk) return false;
        std::lock_guard<std::mutex> lock(mutex_);
        return saveToDiskLocked(vk);
    }

    template <typename Dispatch>
    void shutdown(Dispatch* vk) noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        if (cache_ == VK_NULL_HANDLE) return;
        if (vk && device_ != VK_NULL_HANDLE) {
            if (dirty_) {
                (void)saveToDiskLocked(vk);
            }
            vk->vkDestroyPipelineCache(device_, cache_, nullptr);
        }
        cache_ = VK_NULL_HANDLE;
        device_ = VK_NULL_HANDLE;
        dirty_ = false;
        unsavedCompilations_ = 0;
    }

private:
    static uint64_t fnv1a64(const uint8_t* data, size_t size) noexcept {
        uint64_t hash = 14695981039346656037ull;
        for (size_t i = 0; i < size; ++i) {
            hash ^= static_cast<uint64_t>(data[i]);
            hash *= 1099511628211ull;
        }
        return hash;
    }

    template <typename Dispatch>
    bool saveToDiskLocked(Dispatch* vk) noexcept {
        if (cache_ == VK_NULL_HANDLE || device_ == VK_NULL_HANDLE || path_.empty()) {
            return false;
        }
        size_t dataSize = 0;
        if (vk->vkGetPipelineCacheData(device_, cache_, &dataSize, nullptr) != VK_SUCCESS ||
            dataSize < kMinHeaderBytes || dataSize > kMaxCacheFileBytes) {
            return false;
        }
        std::vector<uint8_t> blob;
        try {
            blob.resize(dataSize);
        } catch (...) {
            return false;
        }
        if (vk->vkGetPipelineCacheData(device_, cache_, &dataSize, blob.data()) != VK_SUCCESS ||
            dataSize < kMinHeaderBytes) {
            return false;
        }
        blob.resize(dataSize);
        if (!validateBlobHeader(blob.data(), blob.size(), props_)) {
            return false;
        }
        const uint64_t hash = fnv1a64(blob.data(), blob.size());
        if (blob.size() == lastSavedSize_ && hash == lastSavedHash_) {
            dirty_ = false;
            unsavedCompilations_ = 0;
            stats_.save_skipped_unchanged_count += 1;
            return true;
        }
        if (!writeBlobAtomically(path_, blob.data(), blob.size())) {
            return false;
        }
        lastSavedSize_ = blob.size();
        lastSavedHash_ = hash;
        dirty_ = false;
        unsavedCompilations_ = 0;
        stats_.saved_to_disk_count += 1;
        stats_.saved_to_disk_bytes += blob.size();
        return true;
    }

    mutable std::mutex mutex_;
    VkDevice device_ = VK_NULL_HANDLE;
    VkPipelineCache cache_ = VK_NULL_HANDLE;
    VkPhysicalDeviceProperties props_{};
    std::string path_;
    size_t lastSavedSize_ = 0;
    uint64_t lastSavedHash_ = 0;
    uint32_t unsavedCompilations_ = 0;
    bool dirty_ = false;
    PipelineCacheStatsSnapshot stats_{};
};

} // namespace caboose::gpuv2
