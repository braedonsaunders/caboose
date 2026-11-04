// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "guest_set_ids.h"

#include <cassert>
#include <cstdio>

using namespace caboose::memory::guest_set_ids;

int main() {
    const uint64_t pool = 0xCA12345600000010ull;
    // The ids follow the pool's handle, one per set, under the same process tag.
    const auto three = ids(pool, 3);
    assert(three.size() == 3 && three[0] == pool + 1 && three[1] == pool + 2 && three[2] == pool + 3);
    for (uint64_t id : three) assert((id >> 32) == (pool >> 32));
    // A block ending at the counter's last value is whole; one past it would carry into the
    // process tag and is refused, as the decoder refuses it.
    assert(validBlock(0xCA123456FFFFFFFEull, 1));
    assert(!validBlock(0xCA123456FFFFFFFFull, 1));
    assert(ids(0xCA123456FFFFFFF0ull, 0x10).empty());
    assert(ids(0xCA123456FFFFFFF0ull, 0xF).size() == 0xF);
    // A pool handle the phone minted, a zero counter, or no sets: no guest-chosen ids.
    assert(!validBlock(0x00007F0012345678ull, 1));
    assert(!validBlock(0xCA12345600000000ull, 1));
    assert(!validBlock(pool, 0));
    // The largest pool whose handle and ids fit one 32-bit counter.
    assert(fits(0xFFFFFFFEu) && !fits(0xFFFFFFFFu) && !fits(0));
    assert(validBlock(0xCA12345600000001ull, 0xFFFFFFFEu));
    // The flag is outside Vulkan's descriptor pool create flags (bits 0-4 today) and the sign bit.
    assert(!(kPoolFlag & 0x8000001Fu));
    // Nothing asks by default.
    assert(request == nullptr);
    std::printf("guest set ids: ok\n");
}
