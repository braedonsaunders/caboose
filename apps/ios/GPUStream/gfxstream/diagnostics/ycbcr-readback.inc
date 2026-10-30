// Included by compositor-layout.cpp. The caller owns device, queue family,
// pipeline, pipeline layout, descriptor layout, render pass, and conversion.
static uint32_t memoryType(VkPhysicalDevice physical, uint32_t bits, VkMemoryPropertyFlags flags) {
    VkPhysicalDeviceMemoryProperties p{}; vkGetPhysicalDeviceMemoryProperties(physical, &p);
    for (uint32_t i = 0; i < p.memoryTypeCount; ++i)
        if ((bits & (1u << i)) && (p.memoryTypes[i].propertyFlags & flags) == flags) return i;
    std::fprintf(stderr, "No suitable memory type\n"); std::exit(2);
}
struct Buffer { VkBuffer buffer{}; VkDeviceMemory memory{}; };
static Buffer makeBuffer(VkPhysicalDevice physical, VkDevice device, VkDeviceSize size, VkBufferUsageFlags usage) {
    Buffer b; VkBufferCreateInfo ci{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO}; ci.size=size; ci.usage=usage; ci.sharingMode=VK_SHARING_MODE_EXCLUSIVE;
    if (vkCreateBuffer(device,&ci,nullptr,&b.buffer) != VK_SUCCESS) std::exit(2);
    VkMemoryRequirements req{}; vkGetBufferMemoryRequirements(device,b.buffer,&req);
    VkMemoryAllocateInfo ai{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO}; ai.allocationSize=req.size; ai.memoryTypeIndex=memoryType(physical,req.memoryTypeBits,VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (vkAllocateMemory(device,&ai,nullptr,&b.memory) != VK_SUCCESS || vkBindBufferMemory(device,b.buffer,b.memory,0) != VK_SUCCESS) std::exit(2);
    return b;
}
struct Image { VkImage image{}; VkDeviceMemory memory{}; VkImageView view{}; };
static Image makeImage(VkPhysicalDevice physical, VkDevice device, VkFormat format, VkExtent2D extent, VkImageUsageFlags usage, const void* viewNext) {
    Image image; VkImageCreateInfo ci{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO}; ci.imageType=VK_IMAGE_TYPE_2D; ci.format=format; ci.extent={extent.width,extent.height,1}; ci.mipLevels=1; ci.arrayLayers=1; ci.samples=VK_SAMPLE_COUNT_1_BIT; ci.tiling=VK_IMAGE_TILING_OPTIMAL; ci.usage=usage; ci.sharingMode=VK_SHARING_MODE_EXCLUSIVE;
    if (vkCreateImage(device,&ci,nullptr,&image.image) != VK_SUCCESS) std::exit(2);
    VkMemoryRequirements req{}; vkGetImageMemoryRequirements(device,image.image,&req); VkMemoryAllocateInfo ai{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO}; ai.allocationSize=req.size; ai.memoryTypeIndex=memoryType(physical,req.memoryTypeBits,0);
    if (vkAllocateMemory(device,&ai,nullptr,&image.memory) != VK_SUCCESS || vkBindImageMemory(device,image.image,image.memory,0) != VK_SUCCESS) std::exit(2);
    VkImageViewCreateInfo vi{VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO}; vi.pNext=viewNext; vi.image=image.image; vi.viewType=VK_IMAGE_VIEW_TYPE_2D; vi.format=format; vi.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1};
    if (vkCreateImageView(device,&vi,nullptr,&image.view) != VK_SUCCESS) std::exit(2);
    return image;
}
static int drawYcbcr(VkPhysicalDevice physical, VkDevice device, uint32_t family, VkFormat format, int planes, VkSamplerYcbcrConversion conversion, VkDescriptorSetLayout layout, VkPipelineLayout pipelineLayout, VkPipeline pipeline, VkRenderPass pass) {
    VkFormatProperties props{}; vkGetPhysicalDeviceFormatProperties(physical,format,&props);
    if (!(props.optimalTilingFeatures & VK_FORMAT_FEATURE_TRANSFER_DST_BIT)) { std::fprintf(stderr,"YCbCr transfer destination unsupported\n"); return 2; }
    VkImageFormatProperties imageProps{}; VkResult supported=vkGetPhysicalDeviceImageFormatProperties(physical,format,VK_IMAGE_TYPE_2D,VK_IMAGE_TILING_OPTIMAL,VK_IMAGE_USAGE_SAMPLED_BIT|VK_IMAGE_USAGE_TRANSFER_DST_BIT,0,&imageProps);
    if (supported != VK_SUCCESS || imageProps.maxExtent.width < 2 || imageProps.maxExtent.height < 2) { std::fprintf(stderr,"YCbCr sampled transfer image unsupported: %d\n",supported); return 2; }
    VkSamplerYcbcrConversionInfo conversionInfo{VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_INFO}; conversionInfo.conversion=conversion;
    Image source=makeImage(physical,device,format,{2,2},VK_IMAGE_USAGE_TRANSFER_DST_BIT|VK_IMAGE_USAGE_SAMPLED_BIT,&conversionInfo);
    Image target=makeImage(physical,device,VK_FORMAT_R8G8B8A8_UNORM,{1,1},VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT|VK_IMAGE_USAGE_TRANSFER_SRC_BIT,nullptr);
    Buffer upload=makeBuffer(physical,device,12,VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
    Buffer vertex=makeBuffer(physical,device,48,VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
    Buffer uniform=makeBuffer(physical,device,240,VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT);
    Buffer result=makeBuffer(physical,device,4,VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    auto write=[&](Buffer b,const void* data,size_t size){ void* p=nullptr; if(vkMapMemory(device,b.memory,0,size,0,&p)!=VK_SUCCESS) std::exit(2); std::memcpy(p,data,size); vkUnmapMemory(device,b.memory); };
    // Full-range YCbCr: neutral chroma and luma 64/255 gives RGB approximately 64.
    const uint8_t data[12]={64,64,64,64,128,128,0,0,128,0,0,0}; write(upload,data,sizeof(data));
    const float vertices[12]={-1,-1,0.5f,0.5f, 3,-1,0.5f,0.5f, -1,3,0.5f,0.5f}; write(vertex,vertices,sizeof(vertices));
    struct Uniform { float pos[16], tex[16], colorMatrix[16]; uint32_t mode[4]; float alpha[4], color[4]; } u{};
    for (int i=0;i<4;i++) u.pos[i*5]=u.tex[i*5]=u.colorMatrix[i*5]=1.0f; u.mode[0]=2; for(float &a:u.alpha) a=1.0f; write(uniform,&u,sizeof(u));
    VkSamplerYcbcrConversionImageFormatProperties yprops{VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_IMAGE_FORMAT_PROPERTIES}; VkImageFormatProperties2 ip{VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2}; ip.pNext=&yprops; VkPhysicalDeviceImageFormatInfo2 fi{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2}; fi.format=format; fi.type=VK_IMAGE_TYPE_2D; fi.tiling=VK_IMAGE_TILING_OPTIMAL; fi.usage=VK_IMAGE_USAGE_SAMPLED_BIT|VK_IMAGE_USAGE_TRANSFER_DST_BIT; CHECK(vkGetPhysicalDeviceImageFormatProperties2(physical,&fi,&ip));
    VkDescriptorPoolSize sizes[]={{VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,yprops.combinedImageSamplerDescriptorCount},{VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,1}}; VkDescriptorPoolCreateInfo pci{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO}; pci.maxSets=1; pci.poolSizeCount=2; pci.pPoolSizes=sizes; VkDescriptorPool pool; CHECK(vkCreateDescriptorPool(device,&pci,nullptr,&pool));
    VkDescriptorSetAllocateInfo dai{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO}; dai.descriptorPool=pool; dai.descriptorSetCount=1; dai.pSetLayouts=&layout; VkDescriptorSet set; CHECK(vkAllocateDescriptorSets(device,&dai,&set));
    VkDescriptorImageInfo ii{}; ii.imageView=source.view; ii.imageLayout=VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL; VkDescriptorBufferInfo bi{uniform.buffer,0,sizeof(u)};
    VkWriteDescriptorSet writes[2]{}; writes[0].sType=writes[1].sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET; writes[0].dstSet=writes[1].dstSet=set; writes[0].dstBinding=0; writes[1].dstBinding=1; writes[0].descriptorCount=writes[1].descriptorCount=1; writes[0].descriptorType=VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER; writes[1].descriptorType=VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER; writes[0].pImageInfo=&ii; writes[1].pBufferInfo=&bi; vkUpdateDescriptorSets(device,2,writes,0,nullptr);
    VkFramebufferCreateInfo fci{VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO}; fci.renderPass=pass; fci.attachmentCount=1; fci.pAttachments=&target.view; fci.width=fci.height=fci.layers=1; VkFramebuffer fb; CHECK(vkCreateFramebuffer(device,&fci,nullptr,&fb));
    VkCommandPoolCreateInfo cpi{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO}; cpi.queueFamilyIndex=family; VkCommandPool cp; CHECK(vkCreateCommandPool(device,&cpi,nullptr,&cp)); VkCommandBufferAllocateInfo cai{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO}; cai.commandPool=cp; cai.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY; cai.commandBufferCount=1; VkCommandBuffer cmd; CHECK(vkAllocateCommandBuffers(device,&cai,&cmd));
    VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO}; begin.flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT; CHECK(vkBeginCommandBuffer(cmd,&begin));
    VkImageMemoryBarrier barrier{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER}; barrier.oldLayout=VK_IMAGE_LAYOUT_UNDEFINED; barrier.newLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL; barrier.srcQueueFamilyIndex=barrier.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED; barrier.image=source.image; barrier.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1}; barrier.dstAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;
    vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,0,nullptr,0,nullptr,1,&barrier);
    VkBufferImageCopy copies[3]{}; for(int i=0;i<planes;i++){ copies[i].bufferOffset=i==0?0:(i==1?4:8); copies[i].imageSubresource={static_cast<VkImageAspectFlags>(VK_IMAGE_ASPECT_PLANE_0_BIT << i),0,0,1}; copies[i].imageExtent=i==0?VkExtent3D{2,2,1}:VkExtent3D{1,1,1}; }
    vkCmdCopyBufferToImage(cmd,upload.buffer,source.image,VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,planes,copies);
    barrier.oldLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL; barrier.newLayout=VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL; barrier.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT; barrier.dstAccessMask=VK_ACCESS_SHADER_READ_BIT;
    vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,0,0,nullptr,0,nullptr,1,&barrier);
    VkRenderPassBeginInfo rbi{VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO}; rbi.renderPass=pass; rbi.framebuffer=fb; rbi.renderArea={{0,0},{1,1}}; vkCmdBeginRenderPass(cmd,&rbi,VK_SUBPASS_CONTENTS_INLINE); vkCmdBindPipeline(cmd,VK_PIPELINE_BIND_POINT_GRAPHICS,pipeline); vkCmdBindDescriptorSets(cmd,VK_PIPELINE_BIND_POINT_GRAPHICS,pipelineLayout,0,1,&set,0,nullptr); VkDeviceSize offset=0; vkCmdBindVertexBuffers(cmd,0,1,&vertex.buffer,&offset); vkCmdDraw(cmd,3,1,0,0); vkCmdEndRenderPass(cmd);
    barrier.image=target.image; barrier.oldLayout=VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL; barrier.newLayout=VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL; barrier.srcAccessMask=VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT; barrier.dstAccessMask=VK_ACCESS_TRANSFER_READ_BIT;
    vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,0,nullptr,0,nullptr,1,&barrier);
    VkBufferImageCopy output{}; output.imageSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1}; output.imageExtent={1,1,1}; vkCmdCopyImageToBuffer(cmd,target.image,VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,result.buffer,1,&output);
    VkBufferMemoryBarrier bb{VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER}; bb.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT; bb.dstAccessMask=VK_ACCESS_HOST_READ_BIT; bb.srcQueueFamilyIndex=bb.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED; bb.buffer=result.buffer; bb.size=VK_WHOLE_SIZE; vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,0,nullptr,1,&bb,0,nullptr);
    CHECK(vkEndCommandBuffer(cmd)); VkQueue queue; vkGetDeviceQueue(device,family,0,&queue); VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO}; submit.commandBufferCount=1; submit.pCommandBuffers=&cmd; CHECK(vkQueueSubmit(queue,1,&submit,VK_NULL_HANDLE)); CHECK(vkQueueWaitIdle(queue));
    void* ptr=nullptr; CHECK(vkMapMemory(device,result.memory,0,4,0,&ptr)); uint8_t pixel[4]; std::memcpy(pixel,ptr,4); vkUnmapMemory(device,result.memory); std::printf("YCbCr %d-plane RGBA=%u,%u,%u,%u expected ~64,64,64,255\n",planes,pixel[0],pixel[1],pixel[2],pixel[3]);
    bool ok=pixel[0]>=62&&pixel[0]<=66&&pixel[1]>=62&&pixel[1]<=66&&pixel[2]>=62&&pixel[2]<=66&&pixel[3]==255;
    vkDestroyCommandPool(device,cp,nullptr); vkDestroyFramebuffer(device,fb,nullptr); vkDestroyDescriptorPool(device,pool,nullptr);
    for(Buffer b:{upload,vertex,uniform,result}) { vkDestroyBuffer(device,b.buffer,nullptr); vkFreeMemory(device,b.memory,nullptr); }
    for(Image image:{source,target}) { vkDestroyImageView(device,image.view,nullptr); vkDestroyImage(device,image.image,nullptr); vkFreeMemory(device,image.memory,nullptr); }
    return ok?0:1;
}
