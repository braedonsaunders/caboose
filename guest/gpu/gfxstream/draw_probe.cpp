// SPDX-License-Identifier: MIT
// Private diagnostic. Uses Mesa's generated encoder and non-direct shadow path;
// does not expose an ICD or claim coherent-memory support.
#include "SocketStream.h"
#include "ResourceTracker.h"
#include "VkEncoder.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <vector>

#define CHECK(call) do { VkResult r_ = (call); if (r_ != VK_SUCCESS) { \
    std::fprintf(stderr, "%s returned %d\n", #call, r_); return 1; } } while (0)

int main(int argc, char** argv) {
    if (argc != 6) { std::fprintf(stderr, "usage: draw_probe SOCKET UINT32_CHALLENGE COMPUTE_SPV SHADER_DIR OUTPUT_RGBA\n"); return 2; }
    char* end = nullptr;
    unsigned long parsed = std::strtoul(argv[2], &end, 10);
    if (!*argv[2] || *end || parsed > UINT32_MAX) return 2;
    uint32_t challenge = static_cast<uint32_t>(parsed);
    if (challenge % 4 != 3) { std::fprintf(stderr, "challenge must be 3 modulo 4\n"); return 2; }
    std::ifstream shaderInput(argv[3], std::ios::binary | std::ios::ate);
    if (!shaderInput) { std::fprintf(stderr, "cannot open shader\n"); return 1; }
    auto shaderSize = shaderInput.tellg();
    if (shaderSize <= 0 || shaderSize > 32000 || shaderSize % 4) return 1;
    std::vector<uint32_t> shaderBytes(static_cast<size_t>(shaderSize) / 4);
    shaderInput.seekg(0);
    if (!shaderInput.read(reinterpret_cast<char*>(shaderBytes.data()), shaderSize)) return 1;
    if (setenv("CABOOSE_GFXSTREAM_SOCKET", argv[1], 1) != 0) return 1;
    auto* tracker = gfxstream::vk::ResourceTracker::get();
    if (tracker->getStreamFeatures() != 0 || tracker->usingDirectMapping()) return 1;
    auto* stream = new CabooseSocketStream(1024 * 1024);
    if (stream->connect(argv[1]) != 0) { std::perror("socket handshake"); stream->decRef(); return 1; }
    const uint32_t flags = 0;
    if (stream->writeFully(&flags, sizeof(flags)) != 0) { stream->decRef(); return 1; }
    {
        gfxstream::vk::VkEncoder enc(stream);
        VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
        app.pApplicationName = "Caboose private buffer probe";
        app.apiVersion = VK_API_VERSION_1_0;
        VkInstanceCreateInfo instanceInfo{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
        instanceInfo.pApplicationInfo = &app;
        VkInstance instance = VK_NULL_HANDLE;
        CHECK(enc.vkCreateInstance(&instanceInfo, nullptr, &instance, true));
        CHECK(tracker->on_vkCreateInstance(&enc, VK_SUCCESS, &instanceInfo, nullptr, &instance));
        uint32_t count = 0;
        CHECK(enc.vkEnumeratePhysicalDevices(instance, &count, nullptr, true));
        if (!count || count > 64) { std::fprintf(stderr, "invalid physical device count\n"); return 1; }
        std::vector<VkPhysicalDevice> devices(count);
        CHECK(enc.vkEnumeratePhysicalDevices(instance, &count, devices.data(), true));
        VkPhysicalDevice physical = devices[0];
        uint32_t familyCount = 0;
        enc.vkGetPhysicalDeviceQueueFamilyProperties(physical, &familyCount, nullptr, true);
        if (!familyCount || familyCount > 128) return 1;
        std::vector<VkQueueFamilyProperties> families(familyCount);
        enc.vkGetPhysicalDeviceQueueFamilyProperties(physical, &familyCount, families.data(), true);
        uint32_t family = 0;
        while (family < familyCount && (families[family].queueFlags & (VK_QUEUE_COMPUTE_BIT | VK_QUEUE_GRAPHICS_BIT)) != (VK_QUEUE_COMPUTE_BIT | VK_QUEUE_GRAPHICS_BIT)) ++family;
        if (family == familyCount) { std::fprintf(stderr, "no transfer queue\n"); return 77; }
        float priority = 1.0f;
        VkDeviceQueueCreateInfo queueInfo{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
        queueInfo.queueFamilyIndex = family; queueInfo.queueCount = 1; queueInfo.pQueuePriorities = &priority;
        VkDeviceCreateInfo deviceInfo{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
        deviceInfo.queueCreateInfoCount = 1; deviceInfo.pQueueCreateInfos = &queueInfo;
        VkDevice device = VK_NULL_HANDLE;
        CHECK(enc.vkCreateDevice(physical, &deviceInfo, nullptr, &device, true));
        CHECK(tracker->on_vkCreateDevice(&enc, VK_SUCCESS, physical, &deviceInfo, nullptr, &device));
        VkQueue queue = VK_NULL_HANDLE;
        enc.vkGetDeviceQueue(device, family, 0, &queue, true);
        VkBufferCreateInfo bufferInfo{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
        bufferInfo.size = 40; bufferInfo.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT;
        bufferInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        VkBuffer buffer = VK_NULL_HANDLE;
        CHECK(enc.vkCreateBuffer(device, &bufferInfo, nullptr, &buffer, true));
        VkMemoryRequirements req{};
        enc.vkGetBufferMemoryRequirements(device, buffer, &req, true);
        if (!req.size || req.size > 65536) { std::fprintf(stderr, "unsupported allocation size\n"); return 77; }
        VkPhysicalDeviceMemoryProperties props{};
        enc.vkGetPhysicalDeviceMemoryProperties(physical, &props, true);
        std::fprintf(stderr, "memoryTypeBits=0x%08x memoryTypeCount=%u\n", req.memoryTypeBits, props.memoryTypeCount);
        for (uint32_t i = 0; i < props.memoryTypeCount; ++i)
            std::fprintf(stderr, "memoryType[%u]=0x%08x\n", i, props.memoryTypes[i].propertyFlags);
        uint32_t type = 0;
        while (type < props.memoryTypeCount) {
            auto bits = props.memoryTypes[type].propertyFlags;
            if ((req.memoryTypeBits & (1u << type)) && (bits & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) &&
                !(bits & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) break;
            ++type;
        }
        if (type == props.memoryTypeCount) { std::fprintf(stderr, "no guest-advertised noncoherent host-visible type\n"); return 77; }
        VkMemoryAllocateInfo alloc{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
        alloc.allocationSize = req.size; alloc.memoryTypeIndex = type;
        VkDeviceMemory memory = VK_NULL_HANDLE;
        CHECK(tracker->on_vkAllocateMemory(&enc, VK_SUCCESS, device, &alloc, nullptr, &memory));
        CHECK(enc.vkBindBufferMemory(device, buffer, memory, 0, true));
        void* mapped = nullptr;
        CHECK(enc.vkMapMemory(device, memory, 0, VK_WHOLE_SIZE, 0, &mapped, true));
        uint32_t initial[10] = {0,0,0,0,0xdeadbeefu,0,0,0,0,0};
        std::memcpy(mapped, initial, sizeof(initial));
        VkMappedMemoryRange range{VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE};
        range.memory = memory; range.offset = 0; range.size = VK_WHOLE_SIZE;
        CHECK(enc.vkFlushMappedMemoryRanges(device, 1, &range, true));
        VkDescriptorSetLayoutBinding binding{0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, nullptr};
        VkDescriptorSetLayoutCreateInfo setInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
        setInfo.bindingCount = 1; setInfo.pBindings = &binding;
        VkDescriptorSetLayout setLayout = VK_NULL_HANDLE;
        CHECK(enc.vkCreateDescriptorSetLayout(device, &setInfo, nullptr, &setLayout, true));
        VkPushConstantRange push{VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(uint32_t)};
        VkPipelineLayoutCreateInfo layoutInfo{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
        layoutInfo.setLayoutCount = 1; layoutInfo.pSetLayouts = &setLayout;
        layoutInfo.pushConstantRangeCount = 1; layoutInfo.pPushConstantRanges = &push;
        VkPipelineLayout layout = VK_NULL_HANDLE;
        CHECK(enc.vkCreatePipelineLayout(device, &layoutInfo, nullptr, &layout, true));
        VkDescriptorPoolSize poolSize{VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1};
        VkDescriptorPoolCreateInfo descriptorPoolInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};
        descriptorPoolInfo.maxSets = 1; descriptorPoolInfo.poolSizeCount = 1; descriptorPoolInfo.pPoolSizes = &poolSize;
        VkDescriptorPool descriptorPool = VK_NULL_HANDLE;
        CHECK(enc.vkCreateDescriptorPool(device, &descriptorPoolInfo, nullptr, &descriptorPool, true));
        VkDescriptorSetAllocateInfo setAlloc{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
        setAlloc.descriptorPool = descriptorPool; setAlloc.descriptorSetCount = 1; setAlloc.pSetLayouts = &setLayout;
        VkDescriptorSet descriptor = VK_NULL_HANDLE;
        CHECK(enc.vkAllocateDescriptorSets(device, &setAlloc, &descriptor, true));
        VkDescriptorBufferInfo descriptorBuffer{buffer, 0, 20};
        VkWriteDescriptorSet write{VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET};
        write.dstSet = descriptor; write.dstBinding = 0; write.descriptorCount = 1;
        write.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER; write.pBufferInfo = &descriptorBuffer;
        enc.vkUpdateDescriptorSets(device, 1, &write, 0, nullptr, true);
        VkShaderModuleCreateInfo shaderInfo{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};
        shaderInfo.codeSize = static_cast<size_t>(shaderSize); shaderInfo.pCode = shaderBytes.data();
        VkShaderModule shader = VK_NULL_HANDLE;
        CHECK(enc.vkCreateShaderModule(device, &shaderInfo, nullptr, &shader, true));
        VkComputePipelineCreateInfo pipelineInfo{VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};
        pipelineInfo.layout = layout;
        pipelineInfo.stage = {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO};
        pipelineInfo.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT; pipelineInfo.stage.module = shader; pipelineInfo.stage.pName = "main";
        VkPipeline pipeline = VK_NULL_HANDLE;
        CHECK(enc.vkCreateComputePipelines(device, VK_NULL_HANDLE, 1, &pipelineInfo, nullptr, &pipeline, true));
        VkCommandPoolCreateInfo poolInfo{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
        poolInfo.queueFamilyIndex = family;
        VkCommandPool pool = VK_NULL_HANDLE;
        CHECK(enc.vkCreateCommandPool(device, &poolInfo, nullptr, &pool, true));
        VkCommandBufferAllocateInfo commandInfo{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
        commandInfo.commandPool = pool; commandInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; commandInfo.commandBufferCount = 1;
        VkCommandBuffer command = VK_NULL_HANDLE;
        CHECK(enc.vkAllocateCommandBuffers(device, &commandInfo, &command, true));
        VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
        begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        CHECK(enc.vkBeginCommandBuffer(command, &begin, true));
        enc.vkCmdBindPipeline(command, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline, true);
        enc.vkCmdBindDescriptorSets(command, VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0, 1, &descriptor, 0, nullptr, true);
        enc.vkCmdPushConstants(command, layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(challenge), &challenge, true);
        enc.vkCmdDispatch(command, 1, 1, 1, true);
        VkMemoryBarrier barrier{VK_STRUCTURE_TYPE_MEMORY_BARRIER};
        barrier.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT; barrier.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
        enc.vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
                                 0, 1, &barrier, 0, nullptr, 0, nullptr, true);
        CHECK(enc.vkEndCommandBuffer(command, true));
        VkFenceCreateInfo fenceInfo{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
        VkFence fence = VK_NULL_HANDLE;
        CHECK(enc.vkCreateFence(device, &fenceInfo, nullptr, &fence, true));
        VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
        submit.commandBufferCount = 1; submit.pCommandBuffers = &command;
        CHECK(enc.vkQueueSubmit(queue, 1, &submit, fence, true));
        CHECK(enc.vkWaitForFences(device, 1, &fence, VK_TRUE, 5000000000ULL, true));
        CHECK(enc.vkInvalidateMappedMemoryRanges(device, 1, &range, true));
        uint32_t observed[5]; std::memcpy(observed, mapped, sizeof(observed));
        const uint32_t expected[5] = {6, 1, 0, 0, challenge ^ 0x6d2b79f5u};
        if (std::memcmp(observed, expected, sizeof(expected))) { std::fprintf(stderr, "compute readback mismatch\n"); return 1; }
        uint32_t cpuCommand[5]; std::memcpy(cpuCommand, observed, sizeof(cpuCommand));
        cpuCommand[0] /= 2; cpuCommand[2] = cpuCommand[0];
        std::memcpy(mapped, cpuCommand, sizeof(cpuCommand));
        CHECK(enc.vkFlushMappedMemoryRanges(device, 1, &range, true));
        VkImageCreateInfo imageInfo{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
        imageInfo.imageType = VK_IMAGE_TYPE_2D; imageInfo.format = VK_FORMAT_R8G8B8A8_UNORM;
        imageInfo.extent = {128,64,1}; imageInfo.mipLevels = 1; imageInfo.arrayLayers = 1;
        imageInfo.samples = VK_SAMPLE_COUNT_1_BIT; imageInfo.tiling = VK_IMAGE_TILING_OPTIMAL;
        imageInfo.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
        imageInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        VkImage image = VK_NULL_HANDLE;
        CHECK(enc.vkCreateImage(device, &imageInfo, nullptr, &image, true));
        VkMemoryRequirements imageReq{}; enc.vkGetImageMemoryRequirements(device, image, &imageReq, true);
        uint32_t imageType = 0;
        while (imageType < props.memoryTypeCount &&
               (!(imageReq.memoryTypeBits & (1u << imageType)) ||
                (props.memoryTypes[imageType].propertyFlags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT))) ++imageType;
        if (imageType == props.memoryTypeCount || imageReq.size > 65536) { std::fprintf(stderr, "unsupported image memory\n"); return 77; }
        VkMemoryAllocateInfo imageAlloc{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
        imageAlloc.allocationSize = imageReq.size; imageAlloc.memoryTypeIndex = imageType;
        VkDeviceMemory imageMemory = VK_NULL_HANDLE;
        CHECK(tracker->on_vkAllocateMemory(&enc, VK_SUCCESS, device, &imageAlloc, nullptr, &imageMemory));
        CHECK(enc.vkBindImageMemory(device, image, imageMemory, 0, true));
        VkImageViewCreateInfo viewInfo{VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};
        viewInfo.image = image; viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D; viewInfo.format = imageInfo.format;
        viewInfo.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1};
        VkImageView view = VK_NULL_HANDLE; CHECK(enc.vkCreateImageView(device, &viewInfo, nullptr, &view, true));
        VkAttachmentDescription attachment{}; attachment.format = imageInfo.format; attachment.samples = VK_SAMPLE_COUNT_1_BIT;
        attachment.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR; attachment.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
        attachment.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE; attachment.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
        attachment.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED; attachment.finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        VkAttachmentReference reference{0,VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
        VkSubpassDescription subpass{}; subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 1; subpass.pColorAttachments = &reference;
        VkSubpassDependency dependencies[2]{};
        dependencies[0] = {VK_SUBPASS_EXTERNAL,0,VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,0,VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,0};
        dependencies[1] = {0,VK_SUBPASS_EXTERNAL,VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,VK_ACCESS_TRANSFER_READ_BIT,0};
        VkRenderPassCreateInfo passInfo{VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO};
        passInfo.attachmentCount=1; passInfo.pAttachments=&attachment; passInfo.subpassCount=1; passInfo.pSubpasses=&subpass;
        passInfo.dependencyCount=2; passInfo.pDependencies=dependencies;
        VkRenderPass pass = VK_NULL_HANDLE; CHECK(enc.vkCreateRenderPass(device, &passInfo, nullptr, &pass, true));
        VkFramebufferCreateInfo framebufferInfo{VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO};
        framebufferInfo.renderPass=pass; framebufferInfo.attachmentCount=1; framebufferInfo.pAttachments=&view;
        framebufferInfo.width=128; framebufferInfo.height=64; framebufferInfo.layers=1;
        VkFramebuffer framebuffer = VK_NULL_HANDLE; CHECK(enc.vkCreateFramebuffer(device, &framebufferInfo, nullptr, &framebuffer, true));
        auto loadShader = [&](const char* name, VkShaderModule* module) -> VkResult {
            std::string path = std::string(argv[4]) + "/" + name;
            std::ifstream input(path, std::ios::binary | std::ios::ate);
            if (!input) return VK_ERROR_INITIALIZATION_FAILED;
            auto bytes = input.tellg(); if (bytes <= 0 || bytes > 32000 || bytes % 4) return VK_ERROR_INITIALIZATION_FAILED;
            std::vector<uint32_t> code(static_cast<size_t>(bytes)/4); input.seekg(0);
            if (!input.read(reinterpret_cast<char*>(code.data()), bytes)) return VK_ERROR_INITIALIZATION_FAILED;
            VkShaderModuleCreateInfo info{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO}; info.codeSize=static_cast<size_t>(bytes); info.pCode=code.data();
            return enc.vkCreateShaderModule(device, &info, nullptr, module, true);
        };
        VkShaderModule vertexShader=VK_NULL_HANDLE, fragmentShader=VK_NULL_HANDLE;
        CHECK(loadShader("control.vert.spv", &vertexShader)); CHECK(loadShader("color.frag.spv", &fragmentShader));
        VkPipelineShaderStageCreateInfo stages[2]{};
        stages[0].sType=VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO; stages[0].stage=VK_SHADER_STAGE_VERTEX_BIT; stages[0].module=vertexShader; stages[0].pName="main";
        stages[1].sType=VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO; stages[1].stage=VK_SHADER_STAGE_FRAGMENT_BIT; stages[1].module=fragmentShader; stages[1].pName="main";
        VkPipelineVertexInputStateCreateInfo vertex{VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
        VkPipelineInputAssemblyStateCreateInfo assembly{VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO}; assembly.topology=VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
        VkViewport viewport{0,0,128,64,0,1}; VkRect2D scissor{{0,0},{128,64}};
        VkPipelineViewportStateCreateInfo viewportInfo{VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO};
        viewportInfo.viewportCount=1; viewportInfo.pViewports=&viewport; viewportInfo.scissorCount=1; viewportInfo.pScissors=&scissor;
        VkPipelineRasterizationStateCreateInfo raster{VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO};
        raster.polygonMode=VK_POLYGON_MODE_FILL; raster.cullMode=VK_CULL_MODE_NONE; raster.frontFace=VK_FRONT_FACE_COUNTER_CLOCKWISE; raster.lineWidth=1;
        VkPipelineMultisampleStateCreateInfo multisample{VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO}; multisample.rasterizationSamples=VK_SAMPLE_COUNT_1_BIT;
        VkPipelineColorBlendAttachmentState blend{}; blend.colorWriteMask=15;
        VkPipelineColorBlendStateCreateInfo blending{VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO}; blending.attachmentCount=1; blending.pAttachments=&blend;
        VkPipelineLayoutCreateInfo graphicsLayoutInfo{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
        VkPipelineLayout graphicsLayout=VK_NULL_HANDLE; CHECK(enc.vkCreatePipelineLayout(device, &graphicsLayoutInfo, nullptr, &graphicsLayout, true));
        VkGraphicsPipelineCreateInfo graphicsInfo{VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO};
        graphicsInfo.stageCount=2; graphicsInfo.pStages=stages; graphicsInfo.pVertexInputState=&vertex; graphicsInfo.pInputAssemblyState=&assembly;
        graphicsInfo.pViewportState=&viewportInfo; graphicsInfo.pRasterizationState=&raster; graphicsInfo.pMultisampleState=&multisample;
        graphicsInfo.pColorBlendState=&blending; graphicsInfo.layout=graphicsLayout; graphicsInfo.renderPass=pass;
        VkPipeline graphicsPipeline=VK_NULL_HANDLE; CHECK(enc.vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &graphicsInfo, nullptr, &graphicsPipeline, true));
        VkBufferCreateInfo readbackInfo{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
        readbackInfo.size=128*64*4; readbackInfo.usage=VK_BUFFER_USAGE_TRANSFER_DST_BIT; readbackInfo.sharingMode=VK_SHARING_MODE_EXCLUSIVE;
        VkBuffer readback=VK_NULL_HANDLE; CHECK(enc.vkCreateBuffer(device, &readbackInfo, nullptr, &readback, true));
        VkMemoryRequirements readReq{}; enc.vkGetBufferMemoryRequirements(device, readback, &readReq, true);
        if (readReq.size > 65536 || !(readReq.memoryTypeBits & (1u << type))) { std::fprintf(stderr, "unsupported readback allocation\n"); return 77; }
        VkMemoryAllocateInfo readAlloc{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO}; readAlloc.allocationSize=readReq.size; readAlloc.memoryTypeIndex=type;
        VkDeviceMemory readMemory=VK_NULL_HANDLE; CHECK(tracker->on_vkAllocateMemory(&enc, VK_SUCCESS, device, &readAlloc, nullptr, &readMemory));
        CHECK(enc.vkBindBufferMemory(device, readback, readMemory, 0, true));
        CHECK(enc.vkResetFences(device, 1, &fence, true));
        CHECK(enc.vkResetCommandPool(device, pool, 0, true));
        CHECK(enc.vkBeginCommandBuffer(command, &begin, true));
        VkMemoryBarrier upload{VK_STRUCTURE_TYPE_MEMORY_BARRIER}; upload.srcAccessMask=VK_ACCESS_HOST_WRITE_BIT; upload.dstAccessMask=VK_ACCESS_INDIRECT_COMMAND_READ_BIT;
        enc.vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_HOST_BIT, VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT, 0, 1, &upload, 0, nullptr, 0, nullptr, true);
        VkClearValue clear{}; clear.color.float32[3]=1;
        VkRenderPassBeginInfo passBegin{VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO};
        passBegin.renderPass=pass; passBegin.framebuffer=framebuffer; passBegin.renderArea=scissor; passBegin.clearValueCount=1; passBegin.pClearValues=&clear;
        enc.vkCmdBeginRenderPass(command, &passBegin, VK_SUBPASS_CONTENTS_INLINE, true);
        enc.vkCmdBindPipeline(command, VK_PIPELINE_BIND_POINT_GRAPHICS, graphicsPipeline, true);
        enc.vkCmdDrawIndirect(command, buffer, 0, 1, 16, true);
        enc.vkCmdEndRenderPass(command, true);
        VkBufferImageCopy copy{}; copy.imageSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1}; copy.imageExtent={128,64,1};
        enc.vkCmdCopyImageToBuffer(command, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback, 1, &copy, true);
        VkMemoryBarrier host{VK_STRUCTURE_TYPE_MEMORY_BARRIER}; host.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT; host.dstAccessMask=VK_ACCESS_HOST_READ_BIT;
        enc.vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &host, 0, nullptr, 0, nullptr, true);
        CHECK(enc.vkEndCommandBuffer(command, true)); CHECK(enc.vkQueueSubmit(queue, 1, &submit, fence, true));
        CHECK(enc.vkWaitForFences(device, 1, &fence, VK_TRUE, 5000000000ULL, true));
        void* pixelData=nullptr; CHECK(enc.vkMapMemory(device, readMemory, 0, VK_WHOLE_SIZE, 0, &pixelData, true));
        VkMappedMemoryRange pixelRange{VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE}; pixelRange.memory=readMemory; pixelRange.size=VK_WHOLE_SIZE;
        CHECK(enc.vkInvalidateMappedMemoryRanges(device, 1, &pixelRange, true));
        std::ofstream output(argv[5], std::ios::binary); output.write(static_cast<const char*>(pixelData), 128*64*4);
        output.close(); if (!output) { std::fprintf(stderr, "image output failed\n"); return 1; }
        enc.vkUnmapMemory(device, readMemory, true);
        enc.vkDestroyBuffer(device, readback, nullptr, true); tracker->on_vkFreeMemory(&enc, device, readMemory, nullptr);
        enc.vkDestroyPipeline(device, graphicsPipeline, nullptr, true); enc.vkDestroyPipelineLayout(device, graphicsLayout, nullptr, true);
        enc.vkDestroyShaderModule(device, fragmentShader, nullptr, true); enc.vkDestroyShaderModule(device, vertexShader, nullptr, true);
        enc.vkDestroyFramebuffer(device, framebuffer, nullptr, true); enc.vkDestroyRenderPass(device, pass, nullptr, true);
        enc.vkDestroyImageView(device, view, nullptr, true); enc.vkDestroyImage(device, image, nullptr, true);
        tracker->on_vkFreeMemory(&enc, device, imageMemory, nullptr);
        enc.vkUnmapMemory(device, memory, true);
        enc.vkDestroyFence(device, fence, nullptr, true);
        enc.vkDestroyCommandPool(device, pool, nullptr, true);
        enc.vkDestroyPipeline(device, pipeline, nullptr, true);
        enc.vkDestroyShaderModule(device, shader, nullptr, true);
        enc.vkDestroyDescriptorPool(device, descriptorPool, nullptr, true);
        enc.vkDestroyPipelineLayout(device, layout, nullptr, true);
        enc.vkDestroyDescriptorSetLayout(device, setLayout, nullptr, true);
        enc.vkDestroyBuffer(device, buffer, nullptr, true);
        tracker->on_vkFreeMemory(&enc, device, memory, nullptr);
        enc.vkDestroyDevice(device, nullptr, true);
        enc.vkDestroyInstance(instance, nullptr, true);
        std::printf("{\"status\":\"RENDERED\",\"bytes\":32768,\"feedback_seed\":%u,\"gpu_feedback_words\":[%u,%u,%u,%u,%u],\"memory_type\":%u,\"memory_flags\":%u}\n",
                    challenge, observed[0], observed[1], observed[2], observed[3], observed[4], type, props.memoryTypes[type].propertyFlags);
    }
    stream->decRef();
    return 0;
}
