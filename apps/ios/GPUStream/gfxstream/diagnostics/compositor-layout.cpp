// Minimal pipeline probe. Include the unmodified shader headers from the pinned gfxstream source.
#include <vulkan/vulkan.h>
#include <cstdio>
#include <cstdlib>
#include <vector>
#include "compositor_vertex_shader.h"
#include "compositor_fragment_shader.h"
#define CHECK(x) do { VkResult r = (x); if (r != VK_SUCCESS) { std::fprintf(stderr, "%s: %d\n", #x, r); return 1; } } while (0)
int main(int argc, char** argv) {
    // mode 0 original, 1 mutable sampler, 2 vertex only without binding 0, 3 vertex only original layout, 4/5 two-/three-plane YCbCr.
    int mode = argc > 1 ? std::atoi(argv[1]) : 0;
    VkApplicationInfo ai{VK_STRUCTURE_TYPE_APPLICATION_INFO}; ai.apiVersion = VK_API_VERSION_1_1;
    VkInstanceCreateInfo ici{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO}; ici.pApplicationInfo = &ai; const char* ie = "VK_KHR_portability_enumeration"; ici.enabledExtensionCount = 1; ici.ppEnabledExtensionNames = &ie; ici.flags = VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
    VkInstance instance; CHECK(vkCreateInstance(&ici, nullptr, &instance));
    uint32_t count = 0; CHECK(vkEnumeratePhysicalDevices(instance, &count, nullptr)); if (!count) return 2;
    std::vector<VkPhysicalDevice> devices(count); CHECK(vkEnumeratePhysicalDevices(instance, &count, devices.data()));
    uint32_t n = 0; vkGetPhysicalDeviceQueueFamilyProperties(devices[0], &n, nullptr);
    std::vector<VkQueueFamilyProperties> qs(n); vkGetPhysicalDeviceQueueFamilyProperties(devices[0], &n, qs.data());
    uint32_t q = 0; while (q < n && !(qs[q].queueFlags & VK_QUEUE_GRAPHICS_BIT)) ++q; if (q == n) return 2;
    float priority = 1; VkDeviceQueueCreateInfo qi{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO}; qi.queueFamilyIndex = q; qi.queueCount = 1; qi.pQueuePriorities = &priority;
    VkDeviceCreateInfo di{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO}; di.queueCreateInfoCount = 1; di.pQueueCreateInfos = &qi; const char* de = "VK_KHR_portability_subset"; di.enabledExtensionCount = 1; di.ppEnabledExtensionNames = &de;
    VkPhysicalDeviceSamplerYcbcrConversionFeatures yf{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SAMPLER_YCBCR_CONVERSION_FEATURES}; VkPhysicalDeviceFeatures2 features{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2}; features.pNext = &yf; vkGetPhysicalDeviceFeatures2(devices[0], &features); if (mode >= 4) { if (!yf.samplerYcbcrConversion) { std::fprintf(stderr,"YCbCr conversion unsupported\n"); return 2; } di.pNext = &yf; }
    VkDevice device; CHECK(vkCreateDevice(devices[0], &di, nullptr, &device));
    VkSamplerCreateInfo si{VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO}; si.magFilter = VK_FILTER_LINEAR; si.minFilter = VK_FILTER_LINEAR; si.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST; si.addressModeU = si.addressModeV = si.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE; si.maxLod = 1;
    VkSamplerYcbcrConversion conversion = VK_NULL_HANDLE; VkSamplerYcbcrConversionInfo yci{VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_INFO}; if (mode >= 4) { VkSamplerYcbcrConversionCreateInfo yc{VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_CREATE_INFO}; yc.format = mode == 4 ? VK_FORMAT_G8_B8R8_2PLANE_420_UNORM : VK_FORMAT_G8_B8_R8_3PLANE_420_UNORM; VkFormatProperties fp{}; vkGetPhysicalDeviceFormatProperties(devices[0], yc.format, &fp); const VkFormatFeatureFlags required = VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT | VK_FORMAT_FEATURE_COSITED_CHROMA_SAMPLES_BIT; if ((fp.optimalTilingFeatures & required) != required) { std::fprintf(stderr,"YCbCr format/chroma unsupported: format=%d features=0x%x required=0x%x\n", yc.format, fp.optimalTilingFeatures, required); vkDestroyDevice(device,nullptr); vkDestroyInstance(instance,nullptr); return 2; } yc.ycbcrModel = VK_SAMPLER_YCBCR_MODEL_CONVERSION_YCBCR_601; yc.ycbcrRange = VK_SAMPLER_YCBCR_RANGE_ITU_FULL; yc.components = {VK_COMPONENT_SWIZZLE_IDENTITY,VK_COMPONENT_SWIZZLE_IDENTITY,VK_COMPONENT_SWIZZLE_IDENTITY,VK_COMPONENT_SWIZZLE_IDENTITY}; yc.xChromaOffset = yc.yChromaOffset = VK_CHROMA_LOCATION_COSITED_EVEN; yc.chromaFilter = VK_FILTER_NEAREST; CHECK(vkCreateSamplerYcbcrConversion(device,&yc,nullptr,&conversion)); yci.conversion = conversion; si.pNext = &yci; si.magFilter = si.minFilter = VK_FILTER_NEAREST; }
    VkSampler sampler; CHECK(vkCreateSampler(device, &si, nullptr, &sampler));
    VkDescriptorSetLayoutBinding bindings[2]{};
    bindings[0].binding = 0; bindings[0].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER; bindings[0].descriptorCount = 1; bindings[0].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT; bindings[0].pImmutableSamplers = mode == 1 ? nullptr : &sampler;
    bindings[1].binding = 1; bindings[1].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER; bindings[1].descriptorCount = 1; bindings[1].stageFlags = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT;
    VkDescriptorSetLayoutCreateInfo li{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO}; li.bindingCount = mode == 2 ? 1 : 2; li.pBindings = bindings + (mode == 2);
    VkDescriptorSetLayout layout; CHECK(vkCreateDescriptorSetLayout(device, &li, nullptr, &layout));
    VkPipelineLayoutCreateInfo pi{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO}; pi.setLayoutCount = 1; pi.pSetLayouts = &layout;
    VkPipelineLayout pl; CHECK(vkCreatePipelineLayout(device, &pi, nullptr, &pl));
    VkShaderModule mods[2]; const std::vector<uint32_t>* code[] = {&kCompositorVertexShader, &kCompositorFragmentShader};
    for (int i = 0; i < 2; ++i) { VkShaderModuleCreateInfo mi{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO}; mi.codeSize = code[i]->size()*4; mi.pCode = code[i]->data(); CHECK(vkCreateShaderModule(device, &mi, nullptr, &mods[i])); }
    VkAttachmentDescription att{}; att.format = VK_FORMAT_R8G8B8A8_UNORM; att.samples = VK_SAMPLE_COUNT_1_BIT; att.loadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE; att.storeOp = VK_ATTACHMENT_STORE_OP_STORE; att.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED; att.finalLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    VkAttachmentReference ar{0,VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL}; VkSubpassDescription sub{}; sub.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS; sub.colorAttachmentCount = 1; sub.pColorAttachments = &ar;
    VkRenderPassCreateInfo ri{VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO}; ri.attachmentCount = 1; ri.pAttachments = &att; ri.subpassCount = 1; ri.pSubpasses = &sub; VkRenderPass rp; CHECK(vkCreateRenderPass(device, &ri, nullptr, &rp));
    VkPipelineShaderStageCreateInfo stages[2]{}; for (int i=0;i<2;++i) { stages[i].sType=VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO; stages[i].stage=i ? VK_SHADER_STAGE_FRAGMENT_BIT : VK_SHADER_STAGE_VERTEX_BIT; stages[i].module=mods[i]; stages[i].pName="main"; }
    VkVertexInputBindingDescription vb{0,16,VK_VERTEX_INPUT_RATE_VERTEX}; VkVertexInputAttributeDescription va[]={{0,0,VK_FORMAT_R32G32_SFLOAT,0},{1,0,VK_FORMAT_R32G32_SFLOAT,8}};
    VkPipelineVertexInputStateCreateInfo vi{VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO}; vi.vertexBindingDescriptionCount=1; vi.pVertexBindingDescriptions=&vb; vi.vertexAttributeDescriptionCount=2; vi.pVertexAttributeDescriptions=va;
    VkPipelineInputAssemblyStateCreateInfo ia{VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO}; ia.topology=VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    VkViewport viewport{0,0,1,1,0,1}; VkRect2D scissor{{0,0},{1,1}}; VkPipelineViewportStateCreateInfo vs{VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO}; vs.viewportCount=1; vs.pViewports=&viewport; vs.scissorCount=1; vs.pScissors=&scissor;
    VkPipelineRasterizationStateCreateInfo rs{VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO}; rs.rasterizerDiscardEnable = (mode == 2 || mode == 3); rs.polygonMode=VK_POLYGON_MODE_FILL; rs.lineWidth=1; rs.cullMode=VK_CULL_MODE_BACK_BIT; rs.frontFace=VK_FRONT_FACE_CLOCKWISE;
    VkPipelineMultisampleStateCreateInfo ms{VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO}; ms.rasterizationSamples=VK_SAMPLE_COUNT_1_BIT;
    VkPipelineColorBlendAttachmentState ba{}; ba.colorWriteMask=15; VkPipelineColorBlendStateCreateInfo bs{VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO}; bs.attachmentCount=1; bs.pAttachments=&ba;
    VkGraphicsPipelineCreateInfo gp{VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO}; gp.stageCount=(mode == 2 || mode == 3) ? 1 : 2; gp.pStages=stages; gp.pVertexInputState=&vi; gp.pInputAssemblyState=&ia; gp.pViewportState=&vs; gp.pRasterizationState=&rs; gp.pMultisampleState=&ms; gp.pColorBlendState=&bs; gp.layout=pl; gp.renderPass=rp;
    VkPipeline pipeline = VK_NULL_HANDLE; VkResult result = vkCreateGraphicsPipelines(device,VK_NULL_HANDLE,1,&gp,nullptr,&pipeline); std::printf("mode=%d pipeline_result=%d\n",mode,result);
    if (pipeline) vkDestroyPipeline(device,pipeline,nullptr); vkDestroyRenderPass(device,rp,nullptr); for(auto m:mods) vkDestroyShaderModule(device,m,nullptr); vkDestroyPipelineLayout(device,pl,nullptr); vkDestroyDescriptorSetLayout(device,layout,nullptr); vkDestroySampler(device,sampler,nullptr); if (conversion) vkDestroySamplerYcbcrConversion(device,conversion,nullptr); vkDestroyDevice(device,nullptr); vkDestroyInstance(instance,nullptr); return result == VK_SUCCESS ? 0 : 1;
}
