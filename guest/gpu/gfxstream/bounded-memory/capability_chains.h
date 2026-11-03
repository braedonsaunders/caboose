// SPDX-License-Identifier: MIT
#pragma once
#include <vulkan/vulkan_core.h>
#include <cstdint>
#include <cstring>
#include <string>

namespace caboose::memory {
// Physical-device answers that are a root structure and its pNext chain (properties),
// kept by the static query cache as plain bytes. The key holds the chain's
// shape: each structure's sType and size, root first, so an answer only ever fills a chain
// of exactly the same structures, and a replay can rebuild the chain from the key alone.
// The answer holds every structure's members after sType and pNext.
using ChainSize = size_t (*)(VkStructureType root, const void* extension);

// Structures extending VkPhysicalDeviceProperties2 whose members point into application
// memory (from the Vulkan registry the driver is built from). A chain holding one is always asked.
inline bool chainPointerFree(VkStructureType type) {
    switch (type) {
    case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_LAYERED_API_PROPERTIES_LIST_KHR:
    case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_4_PROPERTIES:
    case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_HOST_IMAGE_COPY_PROPERTIES:
    case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_GPA_PROPERTIES_AMD:
        return false;
    default:
        return true;
    }
}

inline constexpr size_t kMaxChainStructures = 256;

// Appends the shape of `root` (a structure of `rootSize` bytes) and its chain to *key. False
// when an extension is unknown to `size`, holds pointers, or the chain is too long.
inline bool chainShape(VkStructureType rootType, const void* root, size_t rootSize, ChainSize size,
                       std::string* key) {
    if (!root || rootSize < sizeof(VkBaseOutStructure)) return false;
    auto put = [key](uint32_t value) { key->append(reinterpret_cast<const char*>(&value), sizeof(value)); };
    put(uint32_t(rootType)); put(uint32_t(rootSize));
    size_t count = 0;
    for (auto* next = static_cast<const VkBaseInStructure*>(root)->pNext; next; next = next->pNext) {
        const size_t bytes = size(rootType, next);
        if (++count > kMaxChainStructures || !chainPointerFree(next->sType) || bytes < sizeof(VkBaseOutStructure))
            return false;
        put(uint32_t(next->sType)); put(uint32_t(bytes));
    }
    return true;
}

// The members of every structure in the chain, in order.
inline std::string chainSave(VkStructureType rootType, const void* root, size_t rootSize, ChainSize size) {
    std::string out;
    auto body = [&out](const void* at, size_t bytes) {
        out.append(static_cast<const char*>(at) + sizeof(VkBaseOutStructure), bytes - sizeof(VkBaseOutStructure));
    };
    body(root, rootSize);
    for (auto* next = static_cast<const VkBaseInStructure*>(root)->pNext; next; next = next->pNext)
        body(next, size(rootType, next));
    return out;
}

// Fills the chain from a saved answer, leaving every sType and pNext as the caller set them.
// False, with nothing written, when the answer's size does not fit the chain.
inline bool chainLoad(VkStructureType rootType, void* root, size_t rootSize, ChainSize size,
                      const std::string& answer) {
    size_t total = rootSize - sizeof(VkBaseOutStructure);
    for (auto* next = static_cast<VkBaseOutStructure*>(root)->pNext; next; next = next->pNext)
        total += size(rootType, next) - sizeof(VkBaseOutStructure);
    if (total != answer.size()) return false;
    size_t at = 0;
    auto body = [&](void* to, size_t bytes) {
        const size_t members = bytes - sizeof(VkBaseOutStructure);
        std::memcpy(static_cast<char*>(to) + sizeof(VkBaseOutStructure), answer.data() + at, members);
        at += members;
    };
    body(root, rootSize);
    for (auto* next = static_cast<VkBaseOutStructure*>(root)->pNext; next; next = next->pNext)
        body(next, size(rootType, next));
    return true;
}
}  // namespace caboose::memory
