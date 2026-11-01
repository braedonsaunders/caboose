// SPDX-License-Identifier: MIT
// Unit tests for feature_emulation.h (README.md, "Test").
#include "feature_emulation.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>

using namespace caboose::features;

static int failures = 0;
#define EXPECT(condition)                                                    \
    do {                                                                     \
        if (!(condition)) {                                                  \
            std::fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #condition); \
            ++failures;                                                      \
        }                                                                    \
    } while (0)

static VkSamplerCustomBorderColorCreateInfoEXT floatColor(float r, float g, float b, float a) {
    VkSamplerCustomBorderColorCreateInfoEXT info{};
    info.sType = VK_STRUCTURE_TYPE_SAMPLER_CUSTOM_BORDER_COLOR_CREATE_INFO_EXT;
    info.customBorderColor.float32[0] = r;
    info.customBorderColor.float32[1] = g;
    info.customBorderColor.float32[2] = b;
    info.customBorderColor.float32[3] = a;
    return info;
}

static VkSamplerCustomBorderColorCreateInfoEXT intColor(int32_t r, int32_t g, int32_t b, int32_t a) {
    VkSamplerCustomBorderColorCreateInfoEXT info{};
    info.sType = VK_STRUCTURE_TYPE_SAMPLER_CUSTOM_BORDER_COLOR_CREATE_INFO_EXT;
    info.customBorderColor.int32[0] = r;
    info.customBorderColor.int32[1] = g;
    info.customBorderColor.int32[2] = b;
    info.customBorderColor.int32[3] = a;
    return info;
}

static void borderColors() {
    const auto custom = VK_BORDER_COLOR_FLOAT_CUSTOM_EXT;
    auto c = floatColor(0, 0, 0, 0);  // OpenGL's default border colour
    EXPECT(nearestBorderColor(custom, &c) == VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK);
    c = floatColor(1, 1, 1, 0.2f);
    EXPECT(nearestBorderColor(custom, &c) == VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK);
    c = floatColor(0.1f, 0.2f, 0.1f, 1);
    EXPECT(nearestBorderColor(custom, &c) == VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK);
    c = floatColor(0.9f, 0.8f, 1, 0.7f);
    EXPECT(nearestBorderColor(custom, &c) == VK_BORDER_COLOR_FLOAT_OPAQUE_WHITE);
    c = floatColor(0, 0, 0, NAN);
    EXPECT(nearestBorderColor(custom, &c) == VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK);
    EXPECT(nearestBorderColor(custom, nullptr) == VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK);

    const auto customInt = VK_BORDER_COLOR_INT_CUSTOM_EXT;
    auto i = intColor(255, 255, 255, 0);
    EXPECT(nearestBorderColor(customInt, &i) == VK_BORDER_COLOR_INT_TRANSPARENT_BLACK);
    i = intColor(0, 0, 0, 1);
    EXPECT(nearestBorderColor(customInt, &i) == VK_BORDER_COLOR_INT_OPAQUE_BLACK);
    i = intColor(1, 1, 1, 1);
    EXPECT(nearestBorderColor(customInt, &i) == VK_BORDER_COLOR_INT_OPAQUE_WHITE);
    i = intColor(INT32_MAX, INT32_MAX, INT32_MAX, 1);  // no overflow
    EXPECT(nearestBorderColor(customInt, &i) == VK_BORDER_COLOR_INT_OPAQUE_WHITE);
    EXPECT(nearestBorderColor(customInt, nullptr) == VK_BORDER_COLOR_INT_TRANSPARENT_BLACK);

    // Built-in colours are kept.
    EXPECT(nearestBorderColor(VK_BORDER_COLOR_INT_OPAQUE_BLACK, &i) == VK_BORDER_COLOR_INT_OPAQUE_BLACK);
    EXPECT(nearestBorderColor(VK_BORDER_COLOR_FLOAT_OPAQUE_WHITE, nullptr) ==
           VK_BORDER_COLOR_FLOAT_OPAQUE_WHITE);
}

static void logicOps() {
    VkPipelineColorBlendStateCreateInfo withOp{};
    withOp.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    withOp.logicOpEnable = VK_TRUE;
    withOp.logicOp = VK_LOGIC_OP_XOR;
    withOp.attachmentCount = 2;
    withOp.blendConstants[2] = 0.5f;
    VkPipelineColorBlendStateCreateInfo withoutOp = withOp;
    withoutOp.logicOpEnable = VK_FALSE;

    std::vector<VkGraphicsPipelineCreateInfo> infos(4);
    infos[0].pColorBlendState = &withOp;
    infos[1].pColorBlendState = &withoutOp;
    infos[2].pColorBlendState = nullptr;  // rasterization discarded or dynamic rendering
    infos[3].pColorBlendState = &withOp;
    std::vector<VkPipelineColorBlendStateCreateInfo> blends;
    EXPECT(dropLogicOps(infos, blends));
    EXPECT(blends.size() == 2);
    EXPECT(infos[0].pColorBlendState == &blends[0] && infos[3].pColorBlendState == &blends[1]);
    EXPECT(!infos[0].pColorBlendState->logicOpEnable);
    EXPECT(infos[0].pColorBlendState->attachmentCount == 2);
    EXPECT(infos[0].pColorBlendState->blendConstants[2] == 0.5f);
    EXPECT(infos[1].pColorBlendState == &withoutOp);
    EXPECT(infos[2].pColorBlendState == nullptr);
    // The application's own state is untouched.
    EXPECT(withOp.logicOpEnable && withOp.logicOp == VK_LOGIC_OP_XOR);

    std::vector<VkGraphicsPipelineCreateInfo> plain(1);
    plain[0].pColorBlendState = &withoutOp;
    EXPECT(!dropLogicOps(plain, blends));
    EXPECT(blends.empty());
}

int main() {
    borderColors();
    logicOps();
    if (failures) return EXIT_FAILURE;
    std::puts("feature_emulation_test: ok");
    return EXIT_SUCCESS;
}
