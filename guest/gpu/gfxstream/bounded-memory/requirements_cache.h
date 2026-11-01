// SPDX-License-Identifier: MIT
#pragma once
#include <cstdint>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vulkan/vulkan_core.h>

namespace caboose::memory {

// Memory requirements of images and buffers, keyed by the exact creation parameters, so
// an object made like an earlier one learns its requirements without a round trip.
// Vulkan guarantees identical requirements for identical creation parameters on one
// device; parameters that can make an object special (external memory, DRM modifiers,
// swapchain images, capture replay, unknown extension structures) are never cached.
class RequirementsCache {
public:
    struct Value {
        VkMemoryRequirements requirements{};
        VkBool32 prefersDedicated = VK_FALSE;
        VkBool32 requiresDedicated = VK_FALSE;
    };
    static constexpr size_t kMaxEntries = 4096;

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
        if (values_.size() >= kMaxEntries && !values_.count(key->second)) values_.clear();
        values_[key->second] = value;
    }
    // Forgets every key of a destroyed device, so a later device reusing its handle
    // value never sees them.
    void deviceDestroyed(uint64_t device) {
        std::lock_guard<std::mutex> lock(mutex_);
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
    std::mutex mutex_;
    std::unordered_map<uint64_t, std::string> objects_;
    std::unordered_map<std::string, Value> values_;
};

inline RequirementsCache requirementsCache;

}  // namespace caboose::memory
