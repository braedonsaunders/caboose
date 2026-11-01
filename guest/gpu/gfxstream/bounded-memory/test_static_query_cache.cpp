// SPDX-License-Identifier: MIT
#include "static_query_cache.h"
#include <cassert>
#include <cstdint>
using caboose::memory::StaticQueryCache;

int main() {
    StaticQueryCache cache;
    struct Answer { int32_t result; uint32_t values[4]; };
    const auto a = StaticQueryCache::key(uint32_t(20004), uint64_t(0x10), uint32_t(44));
    const auto b = StaticQueryCache::key(uint32_t(20004), uint64_t(0x10), uint32_t(45));
    const auto c = StaticQueryCache::key(uint32_t(20005), uint64_t(0x10), uint32_t(44));
    assert(a != b && a != c);
    Answer out{};
    assert(!cache.lookup(a, &out));
    cache.store(a, Answer{-11, {1, 2, 3, 4}});
    assert(cache.lookup(a, &out) && out.result == -11 && out.values[3] == 4);
    assert(!cache.lookup(b, &out));
    // A different answer type for the same key is not mistaken for it.
    uint64_t wrong = 0;
    assert(!cache.lookup(a, &wrong));
    cache.store(a, Answer{0, {5, 6, 7, 8}});
    assert(cache.lookup(a, &out) && out.result == 0 && out.values[0] == 5);
    for (uint32_t i = 0; i < StaticQueryCache::kMaxEntries + 10; ++i)
        cache.store(StaticQueryCache::key(uint32_t(1), i), i);
    uint32_t value = 0;
    assert(cache.lookup(StaticQueryCache::key(uint32_t(1), uint32_t(StaticQueryCache::kMaxEntries + 9)), &value) &&
           value == StaticQueryCache::kMaxEntries + 9);
    return 0;
}
