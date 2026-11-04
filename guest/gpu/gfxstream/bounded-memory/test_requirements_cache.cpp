// SPDX-License-Identifier: MIT
#include "requirements_cache.h"
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <unistd.h>
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

    // A device with an identity keys its objects by it and keeps its answers in a file, so a
    // later device or process made the same way starts with them.
    {
        char directory[] = "/tmp/caboose-requirements-XXXXXX";
        assert(mkdtemp(directory));
        const std::string path = std::string(directory) + "/requirements.bin";
        const uint64_t identity = RequirementsCache::identityOf("vendor 1 device 2 extensions a,b");
        assert(identity == RequirementsCache::identityOf("vendor 1 device 2 extensions a,b") &&
               identity != RequirementsCache::identityOf("vendor 1 device 3 extensions a,b"));
        RequirementsCache first;
        first.deviceCreated(0x2000, identity, path);
        std::string key;
        assert(RequirementsCache::imageKey(0x2000, &image, &key));
        first.created(0x10, key);
        first.store(0x10, value);
        first.store(0x10, value);  // known: written once
        RequirementsCache::Value other = value;
        other.requirements.size = 131072;
        buffer.pNext = nullptr;
        assert(RequirementsCache::bufferKey(0x2000, &buffer, &key));
        first.created(0x11, key);
        first.store(0x11, other);
        first.deviceDestroyed(0x2000);
        assert(!first.lookup(0x10, &found));

        // Another process: a new device handle with the same identity starts with both answers.
        RequirementsCache second;
        second.deviceCreated(0x3000, identity, path);
        assert(RequirementsCache::imageKey(0x3000, &image, &key));
        second.created(0x20, key);
        assert(second.lookup(0x20, &found) && found.requirements.size == 65536 && found.prefersDedicated);
        assert(RequirementsCache::bufferKey(0x3000, &buffer, &key));
        second.created(0x21, key);
        assert(second.lookup(0x21, &found) && found.requirements.size == 131072);
        assert(second.size() == 2);

        // Another identity reads nothing of it; a truncated tail is ignored.
        RequirementsCache third;
        third.deviceCreated(0x4000, RequirementsCache::identityOf("vendor 9"), path);
        assert(third.size() == 0);
        {
            FILE* file = std::fopen(path.c_str(), "ab");
            const char partial[3] = {7, 0, 0};
            std::fwrite(partial, 1, sizeof(partial), file);
            std::fclose(file);
        }
        RequirementsCache fourth;
        fourth.deviceCreated(0x5000, identity, path);
        assert(fourth.size() == 2);
        // A file with another header is not read.
        const std::string foreign = std::string(directory) + "/foreign.bin";
        FILE* file = std::fopen(foreign.c_str(), "wb");
        std::fputs("not a cache", file);
        std::fclose(file);
        RequirementsCache fifth;
        fifth.deviceCreated(0x6000, identity, foreign);
        assert(fifth.size() == 0);
        std::remove(path.c_str());
        std::remove(foreign.c_str());
        rmdir(directory);
    }
    // Each question's outcome is counted for the diagnostics line.
    {
        RequirementsCache counted;
        using Outcome = RequirementsCache::Outcome;
        counted.count(Outcome::hit); counted.count(Outcome::hit); counted.count(Outcome::uncachedObject);
        assert(counted.counted(Outcome::hit) == 2 && counted.counted(Outcome::uncachedObject) == 1);
        assert(counted.counted(Outcome::kept) == 0 && counted.counted(Outcome::uncachedQuestion) == 0);
        std::string key;
        assert(RequirementsCache::imageKey(0x7000, &image, &key));
        assert(!counted.known(0x71));
        counted.created(0x71, key);
        assert(counted.known(0x71));
        counted.destroyed(0x71);
        assert(!counted.known(0x71));
    }
    return 0;
}
