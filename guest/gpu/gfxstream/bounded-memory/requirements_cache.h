// SPDX-License-Identifier: MIT
#pragma once
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <mutex>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <unordered_map>
#include <vector>
#include <vulkan/vulkan_core.h>

namespace caboose::memory {

// Memory requirements of images and buffers, keyed by the exact creation parameters, so
// an object made like an earlier one learns its requirements without a round trip.
// Vulkan guarantees identical requirements for identical creation parameters on one
// device; parameters that can make an object special (external memory, DRM modifiers,
// swapchain images, capture replay, unknown extension structures) are never cached.
//
// A device with a known identity (its physical device's vendor, device and driver versions,
// pipeline cache UUID, API version and enabled extensions) keys its objects by that identity
// instead of its handle, and its answers are appended to a file named by the identity, so a
// later device or process made the same way starts with every answer an earlier one received
// (`deviceCreated`). The file is a header and fixed-layout records, each written with one
// append; a truncated or malformed tail is ignored.
class RequirementsCache {
public:
    struct Value {
        VkMemoryRequirements requirements{};
        VkBool32 prefersDedicated = VK_FALSE;
        VkBool32 requiresDedicated = VK_FALSE;
    };
    static constexpr size_t kMaxEntries = 4096;
    static constexpr uint32_t kMaxKeyBytes = 4096;
    static constexpr off_t kMaxFileBytes = 8 << 20;
    static constexpr char kMagic[8] = {'C', 'B', 'R', 'Q', 1, 0, 0, 0};

    // The identity of a device's creation, as a 64-bit hash of `description`.
    static uint64_t identityOf(const std::string& description) {
        uint64_t hash = 0xcbf29ce484222325ull;  // FNV-1a
        for (unsigned char c : description) hash = (hash ^ c) * 0x100000001b3ull;
        return hash ? hash : 1;
    }
    // `device` is made as `identity` says; its answers are kept in `path` ("" keeps them in
    // memory only), whose earlier answers are read now.
    void deviceCreated(uint64_t device, uint64_t identity, const std::string& path) {
        std::lock_guard<std::mutex> lock(mutex_);
        identities_[device] = identity;
        if (path.empty() || files_.count(identity)) return;
        files_[identity] = path;
        loadLocked(identity, path);
    }

    // The cache key of an image's creation parameters on `device`; false when not cacheable.
    static bool imageKey(uint64_t device, const VkImageCreateInfo* info, std::string* key) {
        if (!info || !key) return false;
        key->clear();
        put(key, uint32_t(1));
        put(key, device);
        put(key, info->flags); put(key, info->imageType); put(key, info->format);
        put(key, info->extent.width); put(key, info->extent.height); put(key, info->extent.depth);
        put(key, info->mipLevels); put(key, info->arrayLayers); put(key, info->samples);
        put(key, info->tiling); put(key, info->usage); put(key, info->sharingMode);
        if (info->sharingMode == VK_SHARING_MODE_CONCURRENT) {
            if (info->queueFamilyIndexCount && !info->pQueueFamilyIndices) return false;
            put(key, info->queueFamilyIndexCount);
            for (uint32_t i = 0; i < info->queueFamilyIndexCount; ++i) put(key, info->pQueueFamilyIndices[i]);
        }
        for (auto* next = static_cast<const VkBaseInStructure*>(info->pNext); next; next = next->pNext) {
            switch (next->sType) {
                case VK_STRUCTURE_TYPE_IMAGE_FORMAT_LIST_CREATE_INFO: {
                    auto* list = reinterpret_cast<const VkImageFormatListCreateInfo*>(next);
                    if (list->viewFormatCount && !list->pViewFormats) return false;
                    put(key, next->sType); put(key, list->viewFormatCount);
                    for (uint32_t i = 0; i < list->viewFormatCount; ++i) put(key, list->pViewFormats[i]);
                    break;
                }
                case VK_STRUCTURE_TYPE_IMAGE_STENCIL_USAGE_CREATE_INFO:
                    put(key, next->sType);
                    put(key, reinterpret_cast<const VkImageStencilUsageCreateInfo*>(next)->stencilUsage);
                    break;
                default:
                    return false;
            }
        }
        return true;
    }

    // The cache key of a buffer's creation parameters on `device`; false when not cacheable.
    static bool bufferKey(uint64_t device, const VkBufferCreateInfo* info, std::string* key) {
        if (!info || !key) return false;
        key->clear();
        put(key, uint32_t(2));
        put(key, device);
        put(key, info->flags); put(key, info->size); put(key, info->usage); put(key, info->sharingMode);
        if (info->sharingMode == VK_SHARING_MODE_CONCURRENT) {
            if (info->queueFamilyIndexCount && !info->pQueueFamilyIndices) return false;
            put(key, info->queueFamilyIndexCount);
            for (uint32_t i = 0; i < info->queueFamilyIndexCount; ++i) put(key, info->pQueueFamilyIndices[i]);
        }
        for (auto* next = static_cast<const VkBaseInStructure*>(info->pNext); next; next = next->pNext) {
            if (next->sType != VK_STRUCTURE_TYPE_BUFFER_USAGE_FLAGS_2_CREATE_INFO_KHR) return false;
            put(key, next->sType);
            put(key, reinterpret_cast<const VkBufferUsageFlags2CreateInfoKHR*>(next)->usage);
        }
        return true;
    }

    // Ties a created object to its creation key.
    void created(uint64_t object, std::string key) {
        if (!object) return;
        std::lock_guard<std::mutex> lock(mutex_);
        uint64_t device = 0;
        if (key.size() >= sizeof(uint32_t) + sizeof(device)) {
            std::memcpy(&device, key.data() + sizeof(uint32_t), sizeof(device));
            auto identity = identities_.find(device);
            if (identity != identities_.end())
                std::memcpy(&key[sizeof(uint32_t)], &identity->second, sizeof(identity->second));
        }
        objects_[object] = std::move(key);
    }
    void destroyed(uint64_t object) {
        std::lock_guard<std::mutex> lock(mutex_);
        objects_.erase(object);
    }
    bool lookup(uint64_t object, Value* out) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto key = objects_.find(object);
        if (key == objects_.end()) return false;
        auto value = values_.find(key->second);
        if (value == values_.end()) return false;
        *out = value->second;
        return true;
    }
    void store(uint64_t object, const Value& value) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto key = objects_.find(object);
        if (key == objects_.end()) return;
        const bool known = values_.count(key->second) != 0;
        if (values_.size() >= kMaxEntries && !known) values_.clear();
        values_[key->second] = value;
        if (!known) appendLocked(key->second, value);
    }
    // Forgets every key of a destroyed device, so a later device reusing its handle
    // value never sees them. Answers kept by identity stay: they hold for any device made
    // the same way.
    void deviceDestroyed(uint64_t device) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto identity = identities_.find(device);
        if (identity != identities_.end()) {
            const uint64_t id = identity->second;
            identities_.erase(identity);
            for (auto it = objects_.begin(); it != objects_.end();) it = ownerOf(it->second) == id ? objects_.erase(it) : std::next(it);
            return;
        }
        auto ofDevice = [device](const std::string& key) {
            uint64_t owner = 0;
            if (key.size() < sizeof(uint32_t) + sizeof(owner)) return false;
            std::memcpy(&owner, key.data() + sizeof(uint32_t), sizeof(owner));
            return owner == device;
        };
        for (auto it = values_.begin(); it != values_.end();) it = ofDevice(it->first) ? values_.erase(it) : std::next(it);
        for (auto it = objects_.begin(); it != objects_.end();) it = ofDevice(it->second) ? objects_.erase(it) : std::next(it);
    }
    size_t size() {
        std::lock_guard<std::mutex> lock(mutex_);
        return values_.size();
    }

private:
    template <class T> static void put(std::string* key, const T& value) {
        key->append(reinterpret_cast<const char*>(&value), sizeof(value));
    }
    static uint64_t ownerOf(const std::string& key) {
        uint64_t owner = 0;
        if (key.size() >= sizeof(uint32_t) + sizeof(owner)) std::memcpy(&owner, key.data() + sizeof(uint32_t), sizeof(owner));
        return owner;
    }
    // A record: key length u32, key, size u64, alignment u64, memory type bits u32, prefers
    // and requires dedicated u32 each.
    static constexpr size_t kValueBytes = 8 + 8 + 4 + 4 + 4;
    void loadLocked(uint64_t identity, const std::string& path) {
        const int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
        if (fd < 0) return;
        struct stat info;
        std::vector<char> bytes;
        if (fstat(fd, &info) == 0 && info.st_size > 0 && info.st_size <= kMaxFileBytes) {
            bytes.resize(size_t(info.st_size));
            size_t got = 0;
            while (got < bytes.size()) {
                const ssize_t n = ::read(fd, bytes.data() + got, bytes.size() - got);
                if (n <= 0) break;
                got += size_t(n);
            }
            bytes.resize(got);
        }
        ::close(fd);
        if (bytes.size() < sizeof(kMagic) || std::memcmp(bytes.data(), kMagic, sizeof(kMagic))) return;
        size_t at = sizeof(kMagic);
        while (bytes.size() - at >= sizeof(uint32_t) && values_.size() < kMaxEntries) {
            uint32_t length = 0;
            std::memcpy(&length, bytes.data() + at, sizeof(length));
            if (length > kMaxKeyBytes || bytes.size() - at - sizeof(length) < length + kValueBytes) break;
            std::string key(bytes.data() + at + sizeof(length), length);
            const char* v = bytes.data() + at + sizeof(length) + length;
            at += sizeof(length) + length + kValueBytes;
            if (ownerOf(key) != identity) continue;
            Value value;
            uint32_t prefers = 0, required = 0;
            std::memcpy(&value.requirements.size, v, 8);
            std::memcpy(&value.requirements.alignment, v + 8, 8);
            std::memcpy(&value.requirements.memoryTypeBits, v + 16, 4);
            std::memcpy(&prefers, v + 20, 4);
            std::memcpy(&required, v + 24, 4);
            value.prefersDedicated = prefers ? VK_TRUE : VK_FALSE;
            value.requiresDedicated = required ? VK_TRUE : VK_FALSE;
            values_.emplace(std::move(key), value);
        }
    }
    void appendLocked(const std::string& key, const Value& value) {
        auto file = files_.find(ownerOf(key));
        if (file == files_.end() || key.size() > kMaxKeyBytes) return;
        const int fd = ::open(file->second.c_str(), O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0644);
        if (fd < 0) return;
        struct stat info;
        if (fstat(fd, &info) != 0 || info.st_size >= kMaxFileBytes) {
            ::close(fd);
            return;
        }
        std::string record;
        if (info.st_size == 0) record.append(kMagic, sizeof(kMagic));
        const uint32_t length = uint32_t(key.size());
        const uint32_t prefers = value.prefersDedicated ? 1 : 0, required = value.requiresDedicated ? 1 : 0;
        put(&record, length);
        record += key;
        put(&record, value.requirements.size);
        put(&record, value.requirements.alignment);
        put(&record, value.requirements.memoryTypeBits);
        put(&record, prefers);
        put(&record, required);
        // One write, so records of processes appending at once never interleave.
        ssize_t written;
        do { written = ::write(fd, record.data(), record.size()); } while (written < 0 && errno == EINTR);
        ::close(fd);
    }
    std::mutex mutex_;
    std::unordered_map<uint64_t, std::string> objects_;
    std::unordered_map<std::string, Value> values_;
    std::unordered_map<uint64_t, uint64_t> identities_;  // device -> identity
    std::unordered_map<uint64_t, std::string> files_;    // identity -> file
};

// Never destroyed: a process's exit runs static destructors while its other threads may
// still be inside the driver.
inline RequirementsCache& requirementsCache = *new RequirementsCache;

}  // namespace caboose::memory
