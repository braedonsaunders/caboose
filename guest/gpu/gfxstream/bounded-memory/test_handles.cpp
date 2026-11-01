// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "handles.h"

#include <vulkan/vulkan_core.h>

#include <cassert>
#include <cstdio>

int main() {
    // A guest-assigned handle: the process tag in the upper half survives on every build.
    const uint64_t tagged = 0x81abcdef00000007ull;
    const VkBuffer buffer = caboose::to_handle<VkBuffer>(tagged);
    assert(caboose::handle_key(buffer) == tagged);
    assert(caboose::handle_key(caboose::to_handle<VkImageView>(7)) == 7);
    assert(caboose::handle_key(VkFence(VK_NULL_HANDLE)) == 0);
    // A dispatchable handle is the object's address.
    int object = 0;
    const VkDevice device = reinterpret_cast<VkDevice>(&object);
    assert(caboose::handle_key(device) == uint64_t(reinterpret_cast<uintptr_t>(&object)));
    assert(caboose::to_handle<VkDevice>(caboose::handle_key(device)) == device);
    std::printf("handles: %zu-bit build\n", sizeof(void*) * 8);
}
