// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
//
// Vulkan handles as 64-bit values and back, on 64-bit and 32-bit builds alike. A
// non-dispatchable handle is a pointer type on 64-bit builds and a uint64_t on 32-bit
// ones, where a cast through uintptr_t would drop its upper half (a guest-assigned
// handle's process tag); a dispatchable handle is a pointer on both.
#pragma once

#include <cstdint>
#include <type_traits>

namespace caboose {

template <typename Handle>
constexpr uint64_t handle_key(Handle handle) {
    if constexpr (std::is_pointer_v<Handle>) {
        return uint64_t(reinterpret_cast<uintptr_t>(handle));
    } else {
        static_assert(sizeof(Handle) == sizeof(uint64_t), "a non-dispatchable handle is 64 bits");
        return uint64_t(handle);
    }
}

template <typename Handle>
constexpr Handle to_handle(uint64_t value) {
    if constexpr (std::is_pointer_v<Handle>) {
        return reinterpret_cast<Handle>(uintptr_t(value));
    } else {
        return Handle(value);
    }
}

}  // namespace caboose
