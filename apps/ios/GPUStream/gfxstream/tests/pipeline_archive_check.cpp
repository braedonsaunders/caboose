// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// pipeline_archive_check ARCHIVE|- SPIRV_DIR COUNT: creates COUNT graphics pipelines, each
// from its own vertex and fragment module (SPIRV_DIR/N.vert.spv, N.frag.spv), on the patched
// MoltenVK, with its persistent Metal pipeline binaries at ARCHIVE ("-" for none), and
// prints the total creation time. Run by tests/pipeline_archive_check.sh.
#include <vulkan/vulkan.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

extern "C" void mvkCabooseSetPipelineArchivePath(const char* path);
extern "C" bool mvkCabooseSavePipelineArchive(void);
extern "C" void mvkCabooseGetPipelineArchiveStats(uint64_t* hits, uint64_t* misses);

#define CHECK(call)                                                                  \
    do {                                                                             \
        VkResult r_ = (call);                                                        \
        if (r_ != VK_SUCCESS) {                                                      \
            std::fprintf(stderr, "%s failed: %d\n", #call, r_);                      \
            std::exit(1);                                                            \
        }                                                                            \
    } while (0)

static std::vector<char> readFile(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) { std::fprintf(stderr, "cannot read %s\n", path.c_str()); std::exit(1); }
    return std::vector<char>(std::istreambuf_iterator<char>(in), {});
}

int main(int argc, char** argv) {
    if (argc != 4) { std::fprintf(stderr, "usage: %s ARCHIVE|- SPIRV_DIR COUNT\n", argv[0]); return 2; }
    const bool archive = std::strcmp(argv[1], "-") != 0;
    const std::string dir = argv[2];
    const int count = std::atoi(argv[3]);
    mvkCabooseSetPipelineArchivePath(archive ? argv[1] : nullptr);

    VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
    app.apiVersion = VK_API_VERSION_1_2;
    // MoltenVK is linked directly, without a loader, so no portability enumeration.
    VkInstanceCreateInfo ici{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    ici.pApplicationInfo = &app;
    VkInstance instance;
    CHECK(vkCreateInstance(&ici, nullptr, &instance));
    uint32_t n = 1;
    VkPhysicalDevice physical;
    CHECK(vkEnumeratePhysicalDevices(instance, &n, &physical));
    float priority = 1;
    VkDeviceQueueCreateInfo qci{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
    qci.queueCount = 1;
    qci.pQueuePriorities = &priority;
    const char* deviceExtensions[] = {"VK_KHR_portability_subset"};
    VkDeviceCreateInfo dci{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = &qci;
    dci.enabledExtensionCount = 1;
    dci.ppEnabledExtensionNames = deviceExtensions;
    VkDevice device;
    CHECK(vkCreateDevice(physical, &dci, nullptr, &device));

    VkAttachmentDescription color{};
    color.format = VK_FORMAT_B8G8R8A8_UNORM;
    color.samples = VK_SAMPLE_COUNT_1_BIT;
    color.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    color.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    color.finalLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    VkAttachmentReference ref{0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
    VkSubpassDescription subpass{};
    subpass.colorAttachmentCount = 1;
    subpass.pColorAttachments = &ref;
    VkRenderPassCreateInfo rpci{VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO};
    rpci.attachmentCount = 1;
    rpci.pAttachments = &color;
    rpci.subpassCount = 1;
    rpci.pSubpasses = &subpass;
    VkRenderPass pass;
    CHECK(vkCreateRenderPass(device, &rpci, nullptr, &pass));
    VkPipelineLayoutCreateInfo plci{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
    VkPipelineLayout layout;
    CHECK(vkCreatePipelineLayout(device, &plci, nullptr, &layout));

    double total = 0;
    for (int i = 0; i < count; ++i) {
        VkShaderModule modules[2];
        const char* kinds[2] = {"vert", "frag"};
        for (int s = 0; s < 2; ++s) {
            const auto code = readFile(dir + "/" + std::to_string(i) + "." + kinds[s] + ".spv");
            VkShaderModuleCreateInfo smci{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};
            smci.codeSize = code.size();
            smci.pCode = reinterpret_cast<const uint32_t*>(code.data());
            CHECK(vkCreateShaderModule(device, &smci, nullptr, &modules[s]));
        }
        VkPipelineShaderStageCreateInfo stages[2]{};
        for (int s = 0; s < 2; ++s) {
            stages[s].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
            stages[s].stage = s ? VK_SHADER_STAGE_FRAGMENT_BIT : VK_SHADER_STAGE_VERTEX_BIT;
            stages[s].module = modules[s];
            stages[s].pName = "main";
        }
        VkPipelineVertexInputStateCreateInfo vertex{VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
        VkPipelineInputAssemblyStateCreateInfo assembly{VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO};
        assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
        VkViewport viewport{0, 0, 64, 64, 0, 1};
        VkRect2D scissor{{0, 0}, {64, 64}};
        VkPipelineViewportStateCreateInfo vp{VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO};
        vp.viewportCount = 1; vp.pViewports = &viewport; vp.scissorCount = 1; vp.pScissors = &scissor;
        VkPipelineRasterizationStateCreateInfo raster{VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO};
        raster.lineWidth = 1;
        VkPipelineMultisampleStateCreateInfo ms{VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO};
        ms.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
        VkPipelineColorBlendAttachmentState blendAttachment{};
        blendAttachment.colorWriteMask = 0xF;
        VkPipelineColorBlendStateCreateInfo blend{VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO};
        blend.attachmentCount = 1; blend.pAttachments = &blendAttachment;
        VkGraphicsPipelineCreateInfo gpci{VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO};
        gpci.stageCount = 2; gpci.pStages = stages;
        gpci.pVertexInputState = &vertex; gpci.pInputAssemblyState = &assembly;
        gpci.pViewportState = &vp; gpci.pRasterizationState = &raster;
        gpci.pMultisampleState = &ms; gpci.pColorBlendState = &blend;
        gpci.layout = layout; gpci.renderPass = pass;
        VkPipeline pipeline;
        const auto start = std::chrono::steady_clock::now();
        CHECK(vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &gpci, nullptr, &pipeline));
        total += std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
        vkDestroyPipeline(device, pipeline, nullptr);
        vkDestroyShaderModule(device, modules[0], nullptr);
        vkDestroyShaderModule(device, modules[1], nullptr);
    }
    const bool saved = archive ? mvkCabooseSavePipelineArchive() : true;
    uint64_t hits = 0, misses = 0;
    mvkCabooseGetPipelineArchiveStats(&hits, &misses);
    std::printf("pipelines=%d total_ms=%.1f per_pipeline_ms=%.2f hits=%llu misses=%llu saved=%d\n", count, total,
                total / count, (unsigned long long)hits, (unsigned long long)misses, saved ? 1 : 0);
    vkDestroyPipelineLayout(device, layout, nullptr);
    vkDestroyRenderPass(device, pass, nullptr);
    vkDestroyDevice(device, nullptr);
    vkDestroyInstance(instance, nullptr);
    return saved ? 0 : 1;
}
