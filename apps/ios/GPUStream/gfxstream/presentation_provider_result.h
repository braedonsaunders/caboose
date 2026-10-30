// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <vulkan/vulkan.h>
namespace caboose::gpuv2 {
struct PresentationProviderResult {
    bool present = false;
    VkResult value = VK_SUCCESS;
    VkResult record(VkResult result) { present = true; value = result; return result; }
};
}
