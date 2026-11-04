// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
//
// Descriptor set ids the process chooses (docs/gpu-live.md, "Guest-chosen set ids"). With
// hello feature 0x100000 a batched descriptor pool reserves 1 + maxSets consecutive
// guest-assigned handles: the pool is the first and its sets are the rest. Its create info
// carries kPoolFlag, which tells the decoder to register those ids for the pool instead of
// minting them, so the process never asks for them (vkCollectDescriptorPoolIdsGOOGLE) and
// never waits for that reply. The decoder takes the flag off before the driver sees it; its
// value matches the fork's host/vulkan/caboose_guest_set_ids.h.
#pragma once

#include <cstdint>
#include <vector>

namespace caboose::memory::guest_set_ids {

// Outside every VkDescriptorPoolCreateFlagBits Vulkan defines.
constexpr uint32_t kPoolFlag = 0x40000000u;

// A pool's handle and set ids take one block of a 32-bit handle counter.
inline bool fits(uint32_t maxSets) { return maxSets && maxSets < 0xFFFFFFFFu; }

// True when `pool` and the maxSets handles after it are guest-assigned handles of one
// process tag (0xCA, a 24-bit tag, a 32-bit counter that does not run out inside the block).
inline bool validBlock(uint64_t pool, uint32_t maxSets) {
    if ((pool >> 56) != 0xCA || !fits(maxSets)) return false;
    const uint64_t counter = pool & 0xFFFFFFFFull;
    return counter && counter + maxSets <= 0xFFFFFFFFull;
}

// The pool's set ids, pool + 1 through pool + maxSets; empty when the block is not valid.
inline std::vector<uint64_t> ids(uint64_t pool, uint32_t maxSets) {
    std::vector<uint64_t> result;
    if (!validBlock(pool, maxSets)) return result;
    result.reserve(maxSets);
    for (uint32_t i = 1; i <= maxSets; ++i) result.push_back(pool + i);
    return result;
}

// Set by the resource tracker around one vkCreateDescriptorPool on its thread when the pool
// may choose its set ids. The encoder writes the pool's handle there when it reserved the
// block and marked the create info; it stays zero when the pool asks for its ids instead.
inline thread_local uint64_t* request = nullptr;

}  // namespace caboose::memory::guest_set_ids
