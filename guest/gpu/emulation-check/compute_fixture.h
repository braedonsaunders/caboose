// Included after render.cpp's Vulkan allocation helpers. Tests GPU-only dependency
// and CPU feedback separately; neither implements general Vulkan remoting.
struct ComputeFixture {
    Buffer output{};
    VkPipeline pipeline = VK_NULL_HANDLE;
    VkPipelineLayout layout = VK_NULL_HANDLE;
    VkDescriptorSet descriptor = VK_NULL_HANDLE;
    uint32_t seed = 19;
};

ComputeFixture computeFixture(Cleanup& cleanup, VkPhysicalDevice physical, const std::string& directory, uint32_t seed) {
    VkDevice device = cleanup.device;
    ComputeFixture fixture;
    fixture.seed = seed;
    fixture.output = buffer(cleanup, physical, 20,
        VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT, {0,0,0,0,0xdeadbeef});
    VkDescriptorSetLayoutBinding binding{0,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,1,VK_SHADER_STAGE_COMPUTE_BIT,nullptr};
    VkDescriptorSetLayoutCreateInfo setInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
    setInfo.bindingCount = 1; setInfo.pBindings = &binding;
    VkDescriptorSetLayout setLayout;
    VK(vkCreateDescriptorSetLayout(device, &setInfo, nullptr, &setLayout));
    cleanup.actions.push_back([device,setLayout] { vkDestroyDescriptorSetLayout(device, setLayout, nullptr); });
    VkPushConstantRange push{VK_SHADER_STAGE_COMPUTE_BIT,0,sizeof(uint32_t)};
    VkPipelineLayoutCreateInfo layoutInfo{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
    layoutInfo.setLayoutCount = 1; layoutInfo.pSetLayouts = &setLayout;
    layoutInfo.pushConstantRangeCount = 1; layoutInfo.pPushConstantRanges = &push;
    VK(vkCreatePipelineLayout(device, &layoutInfo, nullptr, &fixture.layout));
    cleanup.actions.push_back([device,layout=fixture.layout] { vkDestroyPipelineLayout(device, layout, nullptr); });
    VkDescriptorPoolSize size{VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,1};
    VkDescriptorPoolCreateInfo poolInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};
    poolInfo.maxSets = 1; poolInfo.poolSizeCount = 1; poolInfo.pPoolSizes = &size;
    VkDescriptorPool pool;
    VK(vkCreateDescriptorPool(device, &poolInfo, nullptr, &pool));
    cleanup.actions.push_back([device,pool] { vkDestroyDescriptorPool(device, pool, nullptr); });
    VkDescriptorSetAllocateInfo allocate{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
    allocate.descriptorPool = pool; allocate.descriptorSetCount = 1; allocate.pSetLayouts = &setLayout;
    VK(vkAllocateDescriptorSets(device, &allocate, &fixture.descriptor));
    VkDescriptorBufferInfo data{fixture.output.handle,0,20};
    VkWriteDescriptorSet write{VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET};
    write.dstSet = fixture.descriptor; write.dstBinding = 0; write.descriptorCount = 1;
    write.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER; write.pBufferInfo = &data;
    vkUpdateDescriptorSets(device, 1, &write, 0, nullptr);
    VkComputePipelineCreateInfo pipelineInfo{VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};
    pipelineInfo.layout = fixture.layout;
    pipelineInfo.stage = {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO};
    pipelineInfo.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT;
    pipelineInfo.stage.module = shader(cleanup, directory + "/feedback.comp.spv");
    pipelineInfo.stage.pName = "main";
    VkResult result = vkCreateComputePipelines(device, VK_NULL_HANDLE, 1, &pipelineInfo, nullptr, &fixture.pipeline);
    if (fixture.pipeline) cleanup.actions.push_back([device,pipeline=fixture.pipeline] { vkDestroyPipeline(device, pipeline, nullptr); });
    check(result, "vkCreateComputePipelines");
    return fixture;
}

void dispatchCompute(VkCommandBuffer command, const ComputeFixture& fixture, bool hostReadback) {
    VkMemoryBarrier upload{VK_STRUCTURE_TYPE_MEMORY_BARRIER};
    upload.srcAccessMask = VK_ACCESS_HOST_WRITE_BIT; upload.dstAccessMask = VK_ACCESS_SHADER_WRITE_BIT;
    vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_HOST_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                         0, 1, &upload, 0, nullptr, 0, nullptr);
    vkCmdBindPipeline(command, VK_PIPELINE_BIND_POINT_COMPUTE, fixture.pipeline);
    vkCmdBindDescriptorSets(command, VK_PIPELINE_BIND_POINT_COMPUTE, fixture.layout, 0, 1, &fixture.descriptor, 0, nullptr);
    vkCmdPushConstants(command, fixture.layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(fixture.seed), &fixture.seed);
    vkCmdDispatch(command, 1, 1, 1);
    VkMemoryBarrier ready{VK_STRUCTURE_TYPE_MEMORY_BARRIER};
    ready.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT;
    ready.dstAccessMask = hostReadback ? VK_ACCESS_HOST_READ_BIT : VK_ACCESS_INDIRECT_COMMAND_READ_BIT;
    vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                         hostReadback ? VK_PIPELINE_STAGE_HOST_BIT : VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT,
                         0, 1, &ready, 0, nullptr, 0, nullptr);
}

std::vector<uint32_t> finishComputeFeedback(Cleanup& cleanup, VkQueue queue, VkCommandBuffer command, ComputeFixture& fixture) {
    VkDevice device = cleanup.device;
    VK(vkEndCommandBuffer(command));
    VkFenceCreateInfo info{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO}; VkFence fence;
    VK(vkCreateFence(device, &info, nullptr, &fence));
    cleanup.actions.push_back([device,fence] { vkDestroyFence(device, fence, nullptr); });
    VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO}; submit.commandBufferCount = 1; submit.pCommandBuffers = &command;
    VK(vkQueueSubmit(queue, 1, &submit, fence));
    VK(vkWaitForFences(device, 1, &fence, VK_TRUE, 5'000'000'000));
    void* mapped = nullptr;
    VK(vkMapMemory(device, fixture.output.memory, 0, VK_WHOLE_SIZE, 0, &mapped));
    VkMappedMemoryRange range{VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE};
    range.memory = fixture.output.memory; range.size = VK_WHOLE_SIZE;
    VkResult result = vkInvalidateMappedMemoryRanges(device, 1, &range);
    uint32_t words[5]{};
    if (result == VK_SUCCESS) std::memcpy(words, mapped, sizeof(words));
    const std::vector<uint32_t> observed(words, words + 5);
    bool correct = words[0] == 6 && words[1] == 1 && words[2] == 0 && words[3] == 0 && words[4] == (fixture.seed ^ 0x6d2b79f5u);
    if (result == VK_SUCCESS && correct) {
        // The second submission renders only the right triangle. Its command depends
        // on the actual GPU result observed by the CPU, not a canned success value.
        words[0] /= 2; words[2] = words[0];
        std::memcpy(mapped, words, sizeof(words));
        result = vkFlushMappedMemoryRanges(device, 1, &range);
    }
    vkUnmapMemory(device, fixture.output.memory);
    check(result, "compute feedback invalidate/flush");
    if (!correct) {
        std::string message = "GPU_FEEDBACK_MISMATCH: observed";
        for (uint32_t word : observed) message += " " + std::to_string(word);
        throw std::runtime_error(message);
    }
    return observed;
}
