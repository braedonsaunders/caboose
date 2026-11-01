// SPDX-License-Identifier: MIT
//
// Device features the Caboose driver offers when the phone's GPU lacks them, so that Zink
// can give applications desktop OpenGL instead of OpenGL ES 2.0 (docs/gpu-live.md,
// "Applications"). Metal, which MoltenVK runs on, has neither; both are approximated in the
// driver and never reach the phone:
//
// - logicOp. A pipeline's logic operation is dropped, and it writes its colour as its blend
//   state otherwise says. OpenGL exposes logic operations only as glLogicOp, which
//   applications drawn since the 1990s rarely enable.
// - VK_EXT_custom_border_color. Metal samplers have three border colours. A custom colour
//   becomes the nearest of transparent black, opaque black and opaque white. OpenGL's default
//   border colour, the one most clamp-to-border textures keep, is transparent black.
#pragma once

#include <cstdint>
#include <vector>

#include <vulkan/vulkan.h>

namespace caboose::features {

inline constexpr const char* kCustomBorderColor = "VK_EXT_custom_border_color";
// What a driver that offers custom border colours reports: Zink keeps one sampler per GL
// sampler, far below this.
inline constexpr uint32_t kMaxCustomBorderColorSamplers = 4000;

// The built-in border colour nearest to a custom one. `custom` may be null (no colour given).
inline VkBorderColor nearestBorderColor(VkBorderColor color,
                                        const VkSamplerCustomBorderColorCreateInfoEXT* custom) {
    if (color == VK_BORDER_COLOR_FLOAT_CUSTOM_EXT) {
        if (!custom) return VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK;
        const float* c = custom->customBorderColor.float32;
        if (!(c[3] >= 0.5f)) return VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK;
        return (c[0] + c[1] + c[2]) / 3.0f >= 0.5f ? VK_BORDER_COLOR_FLOAT_OPAQUE_WHITE
                                                    : VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK;
    }
    if (color == VK_BORDER_COLOR_INT_CUSTOM_EXT) {
        if (!custom) return VK_BORDER_COLOR_INT_TRANSPARENT_BLACK;
        const int32_t* c = custom->customBorderColor.int32;
        if (c[3] <= 0) return VK_BORDER_COLOR_INT_TRANSPARENT_BLACK;
        // The integer opaque white is 1 in every channel.
        return int64_t(c[0]) + c[1] + c[2] >= 3 ? VK_BORDER_COLOR_INT_OPAQUE_WHITE
                                                 : VK_BORDER_COLOR_INT_OPAQUE_BLACK;
    }
    return color;
}

// Drops the logic operation of every pipeline in `infos` that enables one, pointing it at a
// copy of its colour blend state kept in `blends`. True if any pipeline changed.
inline bool dropLogicOps(std::vector<VkGraphicsPipelineCreateInfo>& infos,
                         std::vector<VkPipelineColorBlendStateCreateInfo>& blends) {
    blends.clear();
    blends.reserve(infos.size());  // pointers into it stay valid
    bool changed = false;
    for (VkGraphicsPipelineCreateInfo& info : infos) {
        if (!info.pColorBlendState || !info.pColorBlendState->logicOpEnable) continue;
        blends.push_back(*info.pColorBlendState);
        blends.back().logicOpEnable = VK_FALSE;
        blends.back().logicOp = VK_LOGIC_OP_COPY;
        info.pColorBlendState = &blends.back();
        changed = true;
    }
    return changed;
}

}  // namespace caboose::features
