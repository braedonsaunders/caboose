// SPDX-License-Identifier: MIT
#pragma once
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vulkan/vulkan_core.h>

namespace caboose::memory {

// Answers about a device's objects that hold for any device made the same way on the same
// physical device: whether a descriptor set layout is supported, for one. They depend on the
// extensions and features the device was made with, so they are kept under the device's
// fingerprint: a digest of its creation parameters, every pNext structure's contents as the
// executor receives them included. A device made with a structure the encoder does not know,
// or one that refers to memory (a device group's devices, a memory report callback), has no
// fingerprint, and its answers are never kept. The answers live in the executor session's
// capability cache (static_query_cache.h), scoped by the physical device's identity, so
// another session, phone or GPU never sees them. A device of an executor that has gone keeps
// its entry until it is destroyed or its handle is reused: its questions are answered as
// lost (the encoder's lost-call check) and its physical device has no scope any more.
class DeviceFingerprints {
public:
    struct Fingerprint {
        uint64_t physical = 0;  // the physical device's handle key, which scopes the answers
        uint64_t high = 0, low = 0;
    };
    static constexpr size_t kMaxDevices = 256;

    // Two independent 64-bit digests of the creation bytes and their length.
    static Fingerprint of(uint64_t physical, const void* bytes, size_t size) {
        const auto* data = static_cast<const unsigned char*>(bytes);
        uint64_t high = 0xcbf29ce484222325ull, low = 0x84222325cbf29ce4ull;
        for (size_t i = 0; i < size; ++i) {
            high = (high ^ data[i]) * 0x100000001b3ull;
            low = (low ^ data[size - 1 - i]) * 0x00000100000001b3ull + 0x9e3779b97f4a7c15ull;
        }
        return {physical, high ^ uint64_t(size), low};
    }

    void created(uint64_t device, const Fingerprint& fingerprint) {
        if (!device || !fingerprint.physical) return;
        std::lock_guard<std::mutex> lock(mutex_);
        if (devices_.size() >= kMaxDevices && !devices_.count(device)) return;
        devices_[device] = fingerprint;
    }
    bool find(uint64_t device, Fingerprint* out) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto found = devices_.find(device);
        if (found == devices_.end()) return false;
        *out = found->second;
        return true;
    }
    void destroyed(uint64_t device) {
        std::lock_guard<std::mutex> lock(mutex_);
        devices_.erase(device);
    }
    size_t size() {
        std::lock_guard<std::mutex> lock(mutex_);
        return devices_.size();
    }

private:
    std::mutex mutex_;
    std::unordered_map<uint64_t, Fingerprint> devices_;
};

// Never destroyed: a process's exit runs static destructors while its other threads may
// still be inside the driver.
inline DeviceFingerprints& deviceFingerprints = *new DeviceFingerprints;

// A descriptor set layout support question's parameters, appended to `out`: the layout's
// flags and bindings, and its pNext structures' contents. False when it cannot be asked from
// the cache: a structure of another kind, or immutable samplers, whose conversions can change
// how many descriptors a binding takes.
inline bool layoutQuestion(const VkDescriptorSetLayoutCreateInfo* info, std::string* out) {
    auto put = [out](const auto& value) { out->append(reinterpret_cast<const char*>(&value), sizeof(value)); };
    if (!info || (info->bindingCount && !info->pBindings)) return false;
    put(info->flags);
    put(info->bindingCount);
    for (uint32_t i = 0; i < info->bindingCount; ++i) {
        const VkDescriptorSetLayoutBinding& binding = info->pBindings[i];
        const bool samplers = binding.descriptorType == VK_DESCRIPTOR_TYPE_SAMPLER ||
                              binding.descriptorType == VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        if (samplers && binding.descriptorCount && binding.pImmutableSamplers) return false;
        put(binding.binding); put(binding.descriptorType); put(binding.descriptorCount); put(binding.stageFlags);
    }
    for (auto* next = static_cast<const VkBaseInStructure*>(info->pNext); next; next = next->pNext) {
        put(next->sType);
        switch (next->sType) {
            case VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO: {
                auto* flags = reinterpret_cast<const VkDescriptorSetLayoutBindingFlagsCreateInfo*>(next);
                if (flags->bindingCount && !flags->pBindingFlags) return false;
                put(flags->bindingCount);
                for (uint32_t i = 0; i < flags->bindingCount; ++i) put(flags->pBindingFlags[i]);
                break;
            }
            case VK_STRUCTURE_TYPE_MUTABLE_DESCRIPTOR_TYPE_CREATE_INFO_EXT: {
                auto* mutable_ = reinterpret_cast<const VkMutableDescriptorTypeCreateInfoEXT*>(next);
                if (mutable_->mutableDescriptorTypeListCount && !mutable_->pMutableDescriptorTypeLists) return false;
                put(mutable_->mutableDescriptorTypeListCount);
                for (uint32_t i = 0; i < mutable_->mutableDescriptorTypeListCount; ++i) {
                    const VkMutableDescriptorTypeListEXT& list = mutable_->pMutableDescriptorTypeLists[i];
                    if (list.descriptorTypeCount && !list.pDescriptorTypes) return false;
                    put(list.descriptorTypeCount);
                    for (uint32_t t = 0; t < list.descriptorTypeCount; ++t) put(list.pDescriptorTypes[t]);
                }
                break;
            }
            default:
                return false;
        }
    }
    return true;
}

// The answer to a descriptor set layout support question: whether it is supported and, when
// asked (VkDescriptorSetVariableDescriptorCountLayoutSupport), the variable count's maximum.
struct LayoutSupportAnswer {
    uint32_t supported = 0;
    uint32_t maxVariableDescriptorCount = 0;
};

}  // namespace caboose::memory
