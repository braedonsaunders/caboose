// Memory allocated while the executor is lost: mapped zeroed, bounded, freed with its handle.
#include "lost_memory.h"

#include <cassert>
#include <cstdio>
#include <cstring>

int main() {
    caboose::memory::LostMemory memory;
    assert(!memory.map(7, 0));  // Memory made while connected is not this table's.
    assert(memory.allocated(7, 4096));
    auto* bytes = static_cast<uint8_t*>(memory.map(7, 0));
    assert(bytes && bytes[0] == 0 && bytes[4095] == 0);
    std::memset(bytes, 0xab, 4096);
    assert(static_cast<uint8_t*>(memory.map(7, 100)) == bytes + 100);
    assert(!memory.map(7, 4096));
    assert(!memory.allocated(7, 16));  // One allocation per handle.
    assert(!memory.allocated(8, 0));
    assert(!memory.allocated(8, caboose::memory::LostMemory::kMaxBytes + 1));
    // The total is bounded.
    uint64_t handle = 100;
    while (memory.allocated(handle, caboose::memory::LostMemory::kMaxBytes)) ++handle;
    assert(memory.bytes() <= caboose::memory::LostMemory::kTotalBytes);
    assert(handle - 100 == caboose::memory::LostMemory::kTotalBytes / caboose::memory::LostMemory::kMaxBytes - 1);
    memory.freed(7);
    assert(!memory.contains(7) && !memory.map(7, 0));
    memory.freed(7);
    for (uint64_t h = 100; h < handle; ++h) memory.freed(h);
    assert(memory.bytes() == 0);
    std::puts("lost memory: zeroed, mapped, bounded and freed");
    return 0;
}
