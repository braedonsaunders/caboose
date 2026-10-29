// Tiny offscreen Vulkan acceptance check. No window, swapchain, profile or game.
#include <vulkan/vulkan.h>
#include <algorithm>
#include <cstring>
#include <fstream>
#include <functional>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

constexpr uint32_t Width = 128, Height = 64;
void check(VkResult r, const char* call) {
    if (r != VK_SUCCESS) throw std::runtime_error(std::string(call) + ": " + std::to_string(r));
}
#define VK(call) check((call), #call)
struct Cleanup {
    VkDevice device = VK_NULL_HANDLE;
    std::vector<std::function<void()>> actions;
    ~Cleanup() {
        // The external runner bounds this process even if a failed driver cannot idle.
        if (device) vkDeviceWaitIdle(device);
        for (auto i = actions.rbegin(); i != actions.rend(); ++i) (*i)();
    }
};
std::string quote(const char* text) {
    std::string out = "\"";
    for (const unsigned char* p = reinterpret_cast<const unsigned char*>(text); *p; ++p) {
        if (*p == '"' || *p == '\\') { out += '\\'; out += char(*p); }
        else if (*p < 32) out += '?';
        else out += char(*p);
    }
    return out + '"';
}
struct Buffer { VkBuffer handle; VkDeviceMemory memory; VkDeviceSize allocation; };
uint32_t memoryType(VkPhysicalDevice physical, uint32_t bits, VkMemoryPropertyFlags required) {
    VkPhysicalDeviceMemoryProperties memory{}; vkGetPhysicalDeviceMemoryProperties(physical, &memory);
    for (uint32_t i = 0; i < memory.memoryTypeCount; ++i)
        if ((bits & (1u << i)) && (memory.memoryTypes[i].propertyFlags & required) == required) return i;
    throw std::runtime_error("No compatible memory type");
}
Buffer buffer(Cleanup& c, VkPhysicalDevice physical, VkDeviceSize size, VkBufferUsageFlags usage,
              const std::vector<uint32_t>& data = {}) {
    VkBufferCreateInfo info{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO}; info.size = size; info.usage = usage;
    info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    Buffer b{}; VK(vkCreateBuffer(c.device, &info, nullptr, &b.handle));
    c.actions.push_back([device=c.device, handle=b.handle] { vkDestroyBuffer(device, handle, nullptr); });
    // Buffer destruction must precede freeing its bound memory.
    VkMemoryRequirements req{}; vkGetBufferMemoryRequirements(c.device, b.handle, &req);
    VkMemoryAllocateInfo alloc{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO}; alloc.allocationSize = req.size;
    alloc.memoryTypeIndex = memoryType(physical, req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT);
    VkResult result = vkAllocateMemory(c.device, &alloc, nullptr, &b.memory);
    check(result, "vkAllocateMemory(buffer)");
    b.allocation = req.size;
    c.actions.insert(c.actions.end() - 1, [device=c.device, memory=b.memory] { vkFreeMemory(device, memory, nullptr); });
    VK(vkBindBufferMemory(c.device, b.handle, b.memory, 0));
    if (!data.empty()) {
        if (data.size() * sizeof(uint32_t) > size) throw std::runtime_error("Upload exceeds buffer");
        void* mapped = nullptr; VK(vkMapMemory(c.device, b.memory, 0, VK_WHOLE_SIZE, 0, &mapped));
        std::memcpy(mapped, data.data(), data.size() * sizeof(uint32_t));
        VkMappedMemoryRange range{VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE}; range.memory = b.memory; range.size = VK_WHOLE_SIZE;
        result = vkFlushMappedMemoryRanges(c.device, 1, &range); vkUnmapMemory(c.device, b.memory);
        check(result, "vkFlushMappedMemoryRanges");
    }
    return b;
}
VkShaderModule shader(Cleanup& c, const std::string& file) {
    std::ifstream input(file, std::ios::binary | std::ios::ate);
    if (!input) throw std::runtime_error("Cannot open shader: " + file);
    auto size = input.tellg();
    if (size <= 0 || size % 4 != 0) throw std::runtime_error("Invalid SPIR-V size");
    std::vector<uint32_t> bytes(static_cast<size_t>(size) / 4); input.seekg(0);
    if (!input.read(reinterpret_cast<char*>(bytes.data()), size)) throw std::runtime_error("Cannot read shader");
    VkShaderModuleCreateInfo info{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO}; info.codeSize = static_cast<size_t>(size); info.pCode = bytes.data();
    VkShaderModule module; VK(vkCreateShaderModule(c.device, &info, nullptr, &module));
    c.actions.push_back([device=c.device, module] { vkDestroyShaderModule(device, module, nullptr); });
    return module;
}
#include "compute_fixture.h"

int render(const std::string& directory, const std::string& name, const std::string& output) {
    const bool geometry = name == "geometry_direct" || name == "geometry_indirect" || name == "geometry_indexed_indirect";
    const bool cull = name == "cull_mixed_sign";
    const bool feedback = name == "compute_cpu_feedback";
    const bool compute = feedback || name == "compute_indirect";
    const bool indirect = compute || name == "geometry_indirect" || name == "geometry_indexed_indirect";
    const bool indexed = name == "geometry_indexed_indirect";
    if (name != "control" && !geometry && !cull && !compute) throw std::runtime_error("Unknown case");
    Cleanup cleanup;
    uint32_t count = 0; VK(vkEnumerateInstanceExtensionProperties(nullptr, &count, nullptr));
    std::vector<VkExtensionProperties> extensions(count);
    VK(vkEnumerateInstanceExtensionProperties(nullptr, &count, extensions.data()));
    bool portability = std::any_of(extensions.begin(), extensions.end(), [](const auto& e) {
        return std::strcmp(e.extensionName, "VK_KHR_portability_enumeration") == 0;
    });
    const char* portabilityExtension = "VK_KHR_portability_enumeration";
    VkApplicationInfo application{VK_STRUCTURE_TYPE_APPLICATION_INFO}; application.pApplicationName = "Caboose offscreen acceptance"; application.apiVersion = VK_API_VERSION_1_0;
    VkInstanceCreateInfo instanceInfo{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO}; instanceInfo.pApplicationInfo = &application;
    if (portability) { instanceInfo.flags = VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR; instanceInfo.enabledExtensionCount = 1; instanceInfo.ppEnabledExtensionNames = &portabilityExtension; }
    VkInstance instance; VK(vkCreateInstance(&instanceInfo, nullptr, &instance));
    cleanup.actions.push_back([instance] { vkDestroyInstance(instance, nullptr); });
    VK(vkEnumeratePhysicalDevices(instance, &count, nullptr));
    if (!count) throw std::runtime_error("No physical device");
    std::vector<VkPhysicalDevice> devices(count); VK(vkEnumeratePhysicalDevices(instance, &count, devices.data()));
    VkPhysicalDevice physical = devices.front();
    VkPhysicalDeviceFeatures features{}; vkGetPhysicalDeviceFeatures(physical, &features);
    VkPhysicalDeviceProperties properties{}; vkGetPhysicalDeviceProperties(physical, &properties);
    std::string metadata = "\"device\":" + quote(properties.deviceName) + ",\"geometryShader\":" + (features.geometryShader ? "true" : "false") + ",\"shaderCullDistance\":" + (features.shaderCullDistance ? "true" : "false");
    if ((geometry && !features.geometryShader) || (cull && !features.shaderCullDistance)) {
        std::cout << "{" << metadata << ",\"status\":\"UNSUPPORTED\",\"reason\":" << quote(geometry ? "geometryShader=false" : "shaderCullDistance=false") << "}" << std::endl;
        return 77;
    }
    VkFormatProperties format{}; vkGetPhysicalDeviceFormatProperties(physical, VK_FORMAT_R8G8B8A8_UNORM, &format);
    if (!(format.optimalTilingFeatures & VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT)) throw std::runtime_error("RGBA8 color attachment unsupported");
    vkGetPhysicalDeviceQueueFamilyProperties(physical, &count, nullptr);
    std::vector<VkQueueFamilyProperties> families(count); vkGetPhysicalDeviceQueueFamilyProperties(physical, &count, families.data());
    uint32_t family = 0;
    const VkQueueFlags requiredQueue = VK_QUEUE_GRAPHICS_BIT | (compute ? VK_QUEUE_COMPUTE_BIT : 0);
    while (family < count && (families[family].queueFlags & requiredQueue) != requiredQueue) ++family;
    if (family == count) throw std::runtime_error("No queue supporting required graphics/compute operations");
    VK(vkEnumerateDeviceExtensionProperties(physical, nullptr, &count, nullptr)); extensions.resize(count);
    VK(vkEnumerateDeviceExtensionProperties(physical, nullptr, &count, extensions.data()));
    std::vector<const char*> deviceExtensions;
    for (const auto& e : extensions) if (std::strcmp(e.extensionName, "VK_KHR_portability_subset") == 0) deviceExtensions.push_back("VK_KHR_portability_subset");
    float priority = 1;
    VkDeviceQueueCreateInfo queueInfo{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO}; queueInfo.queueFamilyIndex = family; queueInfo.queueCount = 1; queueInfo.pQueuePriorities = &priority;
    VkPhysicalDeviceFeatures enabled{}; enabled.geometryShader = geometry; enabled.shaderCullDistance = cull;
    VkDeviceCreateInfo deviceInfo{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO}; deviceInfo.queueCreateInfoCount = 1; deviceInfo.pQueueCreateInfos = &queueInfo; deviceInfo.pEnabledFeatures = &enabled;
    deviceInfo.enabledExtensionCount = static_cast<uint32_t>(deviceExtensions.size()); deviceInfo.ppEnabledExtensionNames = deviceExtensions.data();
    VkDevice device; VK(vkCreateDevice(physical, &deviceInfo, nullptr, &device)); cleanup.device = device;
    cleanup.actions.push_back([device] { vkDestroyDevice(device, nullptr); });
    VkQueue queue; vkGetDeviceQueue(device, family, 0, &queue);
    VkImageCreateInfo imageInfo{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO}; imageInfo.imageType = VK_IMAGE_TYPE_2D; imageInfo.format = VK_FORMAT_R8G8B8A8_UNORM;
    imageInfo.extent = {Width, Height, 1}; imageInfo.mipLevels = 1; imageInfo.arrayLayers = 1; imageInfo.samples = VK_SAMPLE_COUNT_1_BIT;
    imageInfo.tiling = VK_IMAGE_TILING_OPTIMAL; imageInfo.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT; imageInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    VkImage image; VK(vkCreateImage(device, &imageInfo, nullptr, &image));
    cleanup.actions.push_back([device,image] { vkDestroyImage(device, image, nullptr); });
    VkMemoryRequirements req{}; vkGetImageMemoryRequirements(device, image, &req);
    VkMemoryAllocateInfo allocation{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO}; allocation.allocationSize = req.size; allocation.memoryTypeIndex = memoryType(physical, req.memoryTypeBits, 0);
    VkDeviceMemory memory; VkResult result = vkAllocateMemory(device, &allocation, nullptr, &memory);
    check(result, "vkAllocateMemory(image)");
    cleanup.actions.insert(cleanup.actions.end() - 1, [device,memory] { vkFreeMemory(device, memory, nullptr); });
    VK(vkBindImageMemory(device, image, memory, 0));
    VkImageViewCreateInfo viewInfo{VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO}; viewInfo.image = image; viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D; viewInfo.format = imageInfo.format; viewInfo.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1};
    VkImageView view; VK(vkCreateImageView(device, &viewInfo, nullptr, &view)); cleanup.actions.push_back([device,view] { vkDestroyImageView(device, view, nullptr); });
    VkAttachmentDescription attachment{}; attachment.format = imageInfo.format; attachment.samples = VK_SAMPLE_COUNT_1_BIT; attachment.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR; attachment.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    attachment.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE; attachment.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE; attachment.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED; attachment.finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    VkAttachmentReference reference{0,VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
    VkSubpassDescription subpass{}; subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS; subpass.colorAttachmentCount = 1; subpass.pColorAttachments = &reference;
    VkSubpassDependency dependencies[2]{};
    dependencies[0] = {VK_SUBPASS_EXTERNAL,0,VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,0,VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,0};
    dependencies[1] = {0,VK_SUBPASS_EXTERNAL,VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,VK_ACCESS_TRANSFER_READ_BIT,0};
    VkRenderPassCreateInfo passInfo{VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO}; passInfo.attachmentCount = 1; passInfo.pAttachments = &attachment; passInfo.subpassCount = 1; passInfo.pSubpasses = &subpass; passInfo.dependencyCount = 2; passInfo.pDependencies = dependencies;
    VkRenderPass pass; VK(vkCreateRenderPass(device, &passInfo, nullptr, &pass)); cleanup.actions.push_back([device,pass] { vkDestroyRenderPass(device, pass, nullptr); });
    VkFramebufferCreateInfo framebufferInfo{VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO}; framebufferInfo.renderPass = pass; framebufferInfo.attachmentCount = 1; framebufferInfo.pAttachments = &view; framebufferInfo.width = Width; framebufferInfo.height = Height; framebufferInfo.layers = 1;
    VkFramebuffer framebuffer; VK(vkCreateFramebuffer(device, &framebufferInfo, nullptr, &framebuffer)); cleanup.actions.push_back([device,framebuffer] { vkDestroyFramebuffer(device, framebuffer, nullptr); });
    std::vector<VkPipelineShaderStageCreateInfo> stages;
    auto stage = [&](const char* name, VkShaderStageFlagBits kind) { VkPipelineShaderStageCreateInfo s{VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO}; s.stage = kind; s.module = shader(cleanup, directory + "/" + name + ".spv"); s.pName = "main"; stages.push_back(s); };
    stage(geometry ? "geometry.vert" : cull ? "cull.vert" : "control.vert", VK_SHADER_STAGE_VERTEX_BIT);
    if (geometry) stage("geometry.geom", VK_SHADER_STAGE_GEOMETRY_BIT);
    stage("color.frag", VK_SHADER_STAGE_FRAGMENT_BIT);
    VkPipelineVertexInputStateCreateInfo vertex{VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
    VkPipelineInputAssemblyStateCreateInfo assembly{VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO}; assembly.topology = geometry ? VK_PRIMITIVE_TOPOLOGY_POINT_LIST : VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    VkViewport viewport{0,0,Width,Height,0,1}; VkRect2D scissor{{0,0},{Width,Height}};
    VkPipelineViewportStateCreateInfo viewportInfo{VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO}; viewportInfo.viewportCount = 1; viewportInfo.pViewports = &viewport; viewportInfo.scissorCount = 1; viewportInfo.pScissors = &scissor;
    VkPipelineRasterizationStateCreateInfo raster{VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO}; raster.polygonMode = VK_POLYGON_MODE_FILL; raster.cullMode = VK_CULL_MODE_NONE; raster.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE; raster.lineWidth = 1;
    VkPipelineMultisampleStateCreateInfo multisample{VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO}; multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
    VkPipelineColorBlendAttachmentState blend{}; blend.colorWriteMask = 15;
    VkPipelineColorBlendStateCreateInfo blending{VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO}; blending.attachmentCount = 1; blending.pAttachments = &blend;
    VkPipelineLayoutCreateInfo layoutInfo{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO}; VkPipelineLayout layout;
    VK(vkCreatePipelineLayout(device, &layoutInfo, nullptr, &layout)); cleanup.actions.push_back([device,layout] { vkDestroyPipelineLayout(device, layout, nullptr); });
    VkGraphicsPipelineCreateInfo pipelineInfo{VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO}; pipelineInfo.stageCount = static_cast<uint32_t>(stages.size()); pipelineInfo.pStages = stages.data(); pipelineInfo.pVertexInputState = &vertex; pipelineInfo.pInputAssemblyState = &assembly; pipelineInfo.pViewportState = &viewportInfo; pipelineInfo.pRasterizationState = &raster; pipelineInfo.pMultisampleState = &multisample; pipelineInfo.pColorBlendState = &blending; pipelineInfo.layout = layout; pipelineInfo.renderPass = pass;
    VkPipeline pipeline = VK_NULL_HANDLE; result = vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &pipelineInfo, nullptr, &pipeline);
    if (pipeline) cleanup.actions.push_back([device,pipeline] { vkDestroyPipeline(device, pipeline, nullptr); });
    check(result, "vkCreateGraphicsPipelines");
    Buffer readback = buffer(cleanup, physical, Width*Height*4, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    Buffer arguments{}, indices{};
    ComputeFixture computeProbe{};
    if (compute) { computeProbe = computeFixture(cleanup, physical, directory); arguments = computeProbe.output; }
    else if (indirect) arguments = buffer(cleanup, physical, indexed ? 20 : 16, VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT, indexed ? std::vector<uint32_t>{1,1,0,0,0} : std::vector<uint32_t>{1,1,0,0});
    if (indexed) indices = buffer(cleanup, physical, 4, VK_BUFFER_USAGE_INDEX_BUFFER_BIT, {0});
    VkCommandPoolCreateInfo poolInfo{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO}; poolInfo.queueFamilyIndex = family;
    VkCommandPool pool; VK(vkCreateCommandPool(device, &poolInfo, nullptr, &pool)); cleanup.actions.push_back([device,pool] { vkDestroyCommandPool(device, pool, nullptr); });
    VkCommandBufferAllocateInfo commandInfo{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO}; commandInfo.commandPool = pool; commandInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; commandInfo.commandBufferCount = 1;
    VkCommandBuffer command; VK(vkAllocateCommandBuffers(device, &commandInfo, &command));
    VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO}; begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT; VK(vkBeginCommandBuffer(command, &begin));
    if (compute) {
        dispatchCompute(command, computeProbe, feedback);
        if (feedback) {
            auto observed = finishComputeFeedback(cleanup, queue, command, computeProbe);
            // The first command buffer has completed; a second one consumes CPU feedback.
            VK(vkAllocateCommandBuffers(device, &commandInfo, &command));
            VK(vkBeginCommandBuffer(command, &begin));
            metadata += ",\"gpu_feedback_words\":[";
            for (size_t i = 0; i < observed.size(); ++i) metadata += (i ? "," : "") + std::to_string(observed[i]);
            metadata += "]";
        }
    }
    if (indirect && (!compute || feedback)) {
        VkMemoryBarrier upload{VK_STRUCTURE_TYPE_MEMORY_BARRIER}; upload.srcAccessMask = VK_ACCESS_HOST_WRITE_BIT; upload.dstAccessMask = VK_ACCESS_INDIRECT_COMMAND_READ_BIT | (indexed ? VK_ACCESS_INDEX_READ_BIT : 0);
        vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_HOST_BIT, VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT | VK_PIPELINE_STAGE_VERTEX_INPUT_BIT, 0, 1, &upload, 0, nullptr, 0, nullptr);
    }
    VkClearValue clear{}; clear.color.float32[3] = 1;
    VkRenderPassBeginInfo passBegin{VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO}; passBegin.renderPass = pass; passBegin.framebuffer = framebuffer; passBegin.renderArea = scissor; passBegin.clearValueCount = 1; passBegin.pClearValues = &clear;
    vkCmdBeginRenderPass(command, &passBegin, VK_SUBPASS_CONTENTS_INLINE); vkCmdBindPipeline(command, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
    if (indexed) { vkCmdBindIndexBuffer(command, indices.handle, 0, VK_INDEX_TYPE_UINT32); vkCmdDrawIndexedIndirect(command, arguments.handle, 0, 1, 20); }
    else if (indirect) vkCmdDrawIndirect(command, arguments.handle, 0, 1, 16);
    else vkCmdDraw(command, geometry ? 1 : 6, 1, 0, 0);
    vkCmdEndRenderPass(command);
    VkBufferImageCopy copy{}; copy.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT,0,0,1}; copy.imageExtent = {Width,Height,1};
    vkCmdCopyImageToBuffer(command, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback.handle, 1, &copy);
    VkMemoryBarrier host{VK_STRUCTURE_TYPE_MEMORY_BARRIER}; host.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT; host.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
    vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &host, 0, nullptr, 0, nullptr); VK(vkEndCommandBuffer(command));
    VkFenceCreateInfo fenceInfo{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO}; VkFence fence; VK(vkCreateFence(device, &fenceInfo, nullptr, &fence)); cleanup.actions.push_back([device,fence] { vkDestroyFence(device, fence, nullptr); });
    VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO}; submit.commandBufferCount = 1; submit.pCommandBuffers = &command;
    VK(vkQueueSubmit(queue, 1, &submit, fence)); VK(vkWaitForFences(device, 1, &fence, VK_TRUE, 5'000'000'000));
    void* mapped = nullptr; VK(vkMapMemory(device, readback.memory, 0, VK_WHOLE_SIZE, 0, &mapped));
    VkMappedMemoryRange range{VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE}; range.memory = readback.memory; range.size = VK_WHOLE_SIZE;
    result = vkInvalidateMappedMemoryRanges(device, 1, &range);
    std::vector<char> pixels(Width*Height*4);
    if (result == VK_SUCCESS) std::memcpy(pixels.data(), mapped, pixels.size());
    vkUnmapMemory(device, readback.memory); check(result, "vkInvalidateMappedMemoryRanges");
    std::ofstream file(output, std::ios::binary); file.write(pixels.data(), pixels.size());
    if (!file) throw std::runtime_error("Cannot write readback");
    std::cout << "{" << metadata << ",\"status\":\"RENDERED\",\"bytes\":" << pixels.size() << "}" << std::endl;
    return 0;
}
int main(int argc, char** argv) {
    if (argc != 4) { std::cerr << "usage: render SHADER_DIRECTORY CASE OUTPUT.rgba\n"; return 2; }
    try { return render(argv[1], argv[2], argv[3]); }
    catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
