// SPDX-License-Identifier: MIT
#include "requirements_cache.h"
#include <cassert>
#include <string>
using caboose::memory::RequirementsCache;

int main() {
    RequirementsCache cache;
    const uint64_t device = 0x1000;
    VkImageCreateInfo image{};
    image.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    image.imageType = VK_IMAGE_TYPE_2D; image.format = VK_FORMAT_B8G8R8A8_UNORM;
    image.extent = {256, 256, 1}; image.mipLevels = 1; image.arrayLayers = 1;
    image.samples = VK_SAMPLE_COUNT_1_BIT; image.tiling = VK_IMAGE_TILING_OPTIMAL;
    image.usage = VK_IMAGE_USAGE_SAMPLED_BIT;

    std::string a, b;
    assert(RequirementsCache::imageKey(device, &image, &a));
    assert(RequirementsCache::imageKey(device, &image, &b) && a == b);
    image.extent.width = 257;
    assert(RequirementsCache::imageKey(device, &image, &b) && a != b);
    assert(RequirementsCache::imageKey(device + 1, &image, &b) && a != b);
    image.extent.width = 256;

    // Known extension structures are part of the key; unknown or special ones are not cached.
    VkFormat formats[] = {VK_FORMAT_B8G8R8A8_UNORM, VK_FORMAT_B8G8R8A8_SRGB};
    VkImageFormatListCreateInfo list{VK_STRUCTURE_TYPE_IMAGE_FORMAT_LIST_CREATE_INFO, nullptr, 2, formats};
    image.pNext = &list;
    assert(RequirementsCache::imageKey(device, &image, &b) && a != b);
    VkExternalMemoryImageCreateInfo external{};
    external.sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO;
    list.pNext = &external;
    assert(!RequirementsCache::imageKey(device, &image, &b));
    image.pNext = nullptr;

    // A second object made the same way is answered from the first one's query.
    RequirementsCache::Value value;
    value.requirements = {65536, 4096, 0xb};
    value.prefersDedicated = VK_TRUE;
    assert(!cache.lookup(0xA, &value));
    cache.created(0xA, a);
    assert(!cache.lookup(0xA, &value));
    cache.store(0xA, value);
    cache.created(0xB, a);
    RequirementsCache::Value found;
    assert(cache.lookup(0xB, &found) && found.requirements.size == 65536 &&
           found.requirements.alignment == 4096 && found.requirements.memoryTypeBits == 0xb &&
           found.prefersDedicated && !found.requiresDedicated);
    cache.destroyed(0xB);
    assert(!cache.lookup(0xB, &found) && cache.lookup(0xA, &found));
    // Unknown objects are never stored.
    cache.store(0xC, value);
    assert(cache.size() == 1);

    VkBufferCreateInfo buffer{};
    buffer.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    buffer.size = 4096; buffer.usage = VK_BUFFER_USAGE_VERTEX_BUFFER_BIT;
    std::string c;
    assert(RequirementsCache::bufferKey(device, &buffer, &c) && c != a);
    cache.created(0xD, c);
    cache.store(0xD, value);
    VkExternalMemoryBufferCreateInfo externalBuffer{};
    externalBuffer.sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO;
    buffer.pNext = &externalBuffer;
    assert(!RequirementsCache::bufferKey(device, &buffer, &c));

    // A destroyed device forgets everything keyed to it.
    std::string other;
    assert(RequirementsCache::imageKey(device + 1, &image, &other));
    cache.created(0xE, other);
    cache.store(0xE, value);
    cache.deviceDestroyed(device);
    assert(!cache.lookup(0xA, &found) && !cache.lookup(0xD, &found) && cache.lookup(0xE, &found));
    return 0;
}
