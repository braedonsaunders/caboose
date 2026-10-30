// SPDX-License-Identifier: MIT
// Run only against an isolated private ICD and the actual decoder transport.
#include <vulkan/vulkan.h>
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#define REQUIRE(x) do { if (!(x)) { std::fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); std::exit(1); } } while (0)
#define VK_OK(x) REQUIRE((x) == VK_SUCCESS)
static bool same(const VkPhysicalDeviceMemoryProperties& a, const VkPhysicalDeviceMemoryProperties& b) {
    if (a.memoryTypeCount != b.memoryTypeCount || a.memoryHeapCount != b.memoryHeapCount) return false;
    for (uint32_t i=0;i<a.memoryTypeCount;++i)
        if (a.memoryTypes[i].propertyFlags != b.memoryTypes[i].propertyFlags || a.memoryTypes[i].heapIndex != b.memoryTypes[i].heapIndex) return false;
    for (uint32_t i=0;i<a.memoryHeapCount;++i)
        if (a.memoryHeaps[i].size != b.memoryHeaps[i].size || a.memoryHeaps[i].flags != b.memoryHeaps[i].flags) return false;
    return true;
}
int main(int argc, char** argv) {
    if (argc != 2 && argc != 3) { std::fprintf(stderr, "usage: memory_probe UINT32_CHALLENGE [loss-before-invalidate]\n"); return 2; }
    const bool loss = argc == 3;
    REQUIRE(!loss || std::strcmp(argv[2],"loss-before-invalidate")==0);
    char* end=nullptr; unsigned long challenge=std::strtoul(argv[1], &end, 10);
    REQUIRE(*argv[1] && !*end && challenge <= UINT32_MAX);
    VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO}; app.apiVersion=VK_API_VERSION_1_1;
    uint32_t n=0; VK_OK(vkEnumerateInstanceExtensionProperties(nullptr,&n,nullptr));
    std::vector<VkExtensionProperties> exts(n); VK_OK(vkEnumerateInstanceExtensionProperties(nullptr,&n,exts.data()));
    const char* khr=VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME;
    bool hasKhr=false; for (const auto& e:exts) hasKhr |= std::strcmp(e.extensionName,khr)==0;
    // Require all requested query aliases, rather than counting a skipped alias as acceptance.
    REQUIRE(hasKhr);
    VkInstanceCreateInfo ci{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO}; ci.pApplicationInfo=&app;
    ci.enabledExtensionCount=1; ci.ppEnabledExtensionNames=&khr;
    VkInstance instance{}; VK_OK(vkCreateInstance(&ci,nullptr,&instance));
    VK_OK(vkEnumeratePhysicalDevices(instance,&n,nullptr)); REQUIRE(n && n<=64);
    std::vector<VkPhysicalDevice> physicals(n); VK_OK(vkEnumeratePhysicalDevices(instance,&n,physicals.data()));
    auto physical=physicals[0]; VkPhysicalDeviceProperties limits{}; vkGetPhysicalDeviceProperties(physical,&limits);
    VkPhysicalDeviceMemoryProperties props{}; vkGetPhysicalDeviceMemoryProperties(physical,&props);
    VkPhysicalDeviceMemoryProperties2 core{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MEMORY_PROPERTIES_2};
    VkPhysicalDeviceMemoryProperties2 alias{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MEMORY_PROPERTIES_2};
    vkGetPhysicalDeviceMemoryProperties2(physical,&core);
    auto queryKHR=reinterpret_cast<PFN_vkGetPhysicalDeviceMemoryProperties2KHR>(vkGetInstanceProcAddr(instance,"vkGetPhysicalDeviceMemoryProperties2KHR"));
    REQUIRE(queryKHR); queryKHR(physical,&alias);
    REQUIRE(same(props,core.memoryProperties) && same(props,alias.memoryProperties));
    REQUIRE(props.memoryTypeCount && props.memoryTypeCount<=VK_MAX_MEMORY_TYPES);
    std::printf("device=%s atom=%llu mapAlignment=%zu\n",limits.deviceName,(unsigned long long)limits.limits.nonCoherentAtomSize,limits.limits.minMemoryMapAlignment);
    for(uint32_t i=0;i<props.memoryTypeCount;++i) std::printf("guest_type=%u flags=0x%x heap=%u\n",i,props.memoryTypes[i].propertyFlags,props.memoryTypes[i].heapIndex);
    uint32_t familiesCount=0; vkGetPhysicalDeviceQueueFamilyProperties(physical,&familiesCount,nullptr);
    REQUIRE(familiesCount && familiesCount<=128); std::vector<VkQueueFamilyProperties> families(familiesCount);
    vkGetPhysicalDeviceQueueFamilyProperties(physical,&familiesCount,families.data()); uint32_t family=0;
    while(family<familiesCount && !(families[family].queueFlags & VK_QUEUE_TRANSFER_BIT)) ++family;
    REQUIRE(family<familiesCount); float priority=1;
    VkDeviceQueueCreateInfo qi{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO}; qi.queueFamilyIndex=family; qi.queueCount=1; qi.pQueuePriorities=&priority;
    VkDeviceCreateInfo di{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO}; di.queueCreateInfoCount=1; di.pQueueCreateInfos=&qi;
    VkDevice device{}; VK_OK(vkCreateDevice(physical,&di,nullptr,&device)); VkQueue queue{}; vkGetDeviceQueue(device,family,0,&queue);
    VkDeviceSize atom=limits.limits.nonCoherentAtomSize; REQUIRE(atom && !(atom&(atom-1)) && atom<=65536);
    VkDeviceSize unit=std::max<VkDeviceSize>(4096,atom);
    VkBuffer buffers[3]{}; VkMemoryRequirements reqs[3]{};
    for(int i=0;i<3;++i) {
        VkBufferCreateInfo bi{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO}; bi.size=unit; bi.usage=VK_BUFFER_USAGE_TRANSFER_SRC_BIT|VK_BUFFER_USAGE_TRANSFER_DST_BIT;
        VK_OK(vkCreateBuffer(device,&bi,nullptr,&buffers[i])); vkGetBufferMemoryRequirements(device,buffers[i],&reqs[i]);
        VkBufferMemoryRequirementsInfo2 ri{VK_STRUCTURE_TYPE_BUFFER_MEMORY_REQUIREMENTS_INFO_2}; ri.buffer=buffers[i];
        VkMemoryDedicatedRequirements dedicated{VK_STRUCTURE_TYPE_MEMORY_DEDICATED_REQUIREMENTS};
        VkMemoryRequirements2 r2{VK_STRUCTURE_TYPE_MEMORY_REQUIREMENTS_2}; r2.pNext=&dedicated;
        vkGetBufferMemoryRequirements2(device,&ri,&r2);
        if (dedicated.requiresDedicatedAllocation) {
            std::fprintf(stderr,"unsupported probe case: buffer %d requires dedicated allocation; alias test refused\n",i);
            return 77;
        }
        REQUIRE(reqs[i].size==r2.memoryRequirements.size && reqs[i].alignment==r2.memoryRequirements.alignment && reqs[i].memoryTypeBits==r2.memoryRequirements.memoryTypeBits);
        REQUIRE(reqs[i].alignment && !(reqs[i].alignment&(reqs[i].alignment-1)) && reqs[i].alignment<=65536);
    }
    VkDeviceSize stride=unit; uint32_t bits=~0u;
    for(auto r:reqs) { stride=std::max(stride,r.alignment); bits &= r.memoryTypeBits; REQUIRE(r.size<=65536); stride=std::max(stride,r.size); }
    // Round stride to the largest power-of-two alignment, including the atom.
    VkDeviceSize align=unit; for(auto r:reqs) align=std::max(align,r.alignment);
    stride=(stride+align-1)/align*align; REQUIRE(stride<=65536);
    uint32_t type=0;
    for(;type<props.memoryTypeCount;++type) {
        auto f=props.memoryTypes[type].propertyFlags;
        if ((bits&(1u<<type)) && (f&VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) && !(f&VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) break;
    }
    REQUIRE(type<props.memoryTypeCount);
    VkDeviceSize bytes=5*stride+4; VkDeviceMemory memory[2]{}; uint8_t* mapped[2]{};
    std::printf("selected_guest_type=%u requirements_mask=0x%x allocation=%llu bind_offset=%llu copy_bytes=%llu\n",type,bits,(unsigned long long)bytes,(unsigned long long)stride,(unsigned long long)unit);
    for(int i=0;i<2;++i) {
        VkMemoryAllocateInfo ai{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO}; ai.allocationSize=bytes; ai.memoryTypeIndex=type;
        VK_OK(vkAllocateMemory(device,&ai,nullptr,&memory[i]));
        VK_OK(vkMapMemory(device,memory[i],0,VK_WHOLE_SIZE,0,reinterpret_cast<void**>(&mapped[i])));
        std::memset(mapped[i],0x35,bytes);
        VkMappedMemoryRange range{VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE}; range.memory=memory[i]; range.size=VK_WHOLE_SIZE;
        VK_OK(vkFlushMappedMemoryRanges(device,1,&range));
    }
    // Two resources alias exactly one allocation; no allocation-index substitution.
    VK_OK(vkBindBufferMemory(device,buffers[0],memory[0],stride));
    VK_OK(vkBindBufferMemory(device,buffers[1],memory[0],stride));
    VK_OK(vkBindBufferMemory(device,buffers[2],memory[1],stride));
    vkUnmapMemory(device,memory[0]);
    VK_OK(vkMapMemory(device,memory[0],stride,2*stride,0,reinterpret_cast<void**>(&mapped[0])));
    REQUIRE(limits.limits.minMemoryMapAlignment);
    REQUIRE((reinterpret_cast<uintptr_t>(mapped[0])-stride)%limits.limits.minMemoryMapAlignment==0);
    std::vector<uint8_t> expected(unit); for(size_t i=0;i<expected.size();++i) expected[i]=uint8_t((challenge+i*37+(i>>8))&255);
    std::memcpy(mapped[0],expected.data(),unit);
    VkMappedMemoryRange source{VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE}; source.memory=memory[0]; source.offset=stride; source.size=unit;
    VK_OK(vkFlushMappedMemoryRanges(device,1,&source));
    // Poison local bytes after flush. GPU must read the already published bytes.
    std::memset(mapped[0],0xcc,unit);
    VkCommandPoolCreateInfo pi{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO}; pi.queueFamilyIndex=family;
    VkCommandPool pool{}; VK_OK(vkCreateCommandPool(device,&pi,nullptr,&pool));
    VkCommandBufferAllocateInfo cai{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO}; cai.commandPool=pool; cai.commandBufferCount=1; cai.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    VkCommandBuffer command{}; VK_OK(vkAllocateCommandBuffers(device,&cai,&command));
    VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO}; VK_OK(vkBeginCommandBuffer(command,&begin));
    VkBufferCopy copy{0,0,unit}; vkCmdCopyBuffer(command,buffers[1],buffers[2],1,&copy);
    VkMemoryBarrier barrier{VK_STRUCTURE_TYPE_MEMORY_BARRIER}; barrier.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT; barrier.dstAccessMask=VK_ACCESS_HOST_READ_BIT;
    vkCmdPipelineBarrier(command,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,1,&barrier,0,nullptr,0,nullptr);
    VK_OK(vkEndCommandBuffer(command));
    VkFenceCreateInfo fi{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO}; VkFence fence{}; VK_OK(vkCreateFence(device,&fi,nullptr,&fence));
    VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO}; submit.commandBufferCount=1; submit.pCommandBuffers=&command;
    VK_OK(vkQueueSubmit(queue,1,&submit,fence)); VK_OK(vkWaitForFences(device,1,&fence,VK_TRUE,5000000000ULL));
    // Fence completion alone does not publish guest shadow bytes.
    for(VkDeviceSize i=0;i<bytes;++i) REQUIRE(mapped[1][i]==0x35);
    VkMappedMemoryRange dest{VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE}; dest.memory=memory[1]; dest.offset=stride; dest.size=unit;
    if (loss) {
        std::puts("READY revoke isolated transport then send one input byte"); std::fflush(stdout);
        REQUIRE(std::getchar()!=EOF);
        REQUIRE(vkInvalidateMappedMemoryRanges(device,1,&dest)==VK_ERROR_DEVICE_LOST);
        for(VkDeviceSize i=0;i<bytes;++i) REQUIRE(mapped[1][i]==0x35);
        std::puts("PASS local-loss unchanged-shadow; decoder retirement remains externally required");
        // The lost connection cannot acknowledge cleanup. Process exit releases
        // local memory; the harness must retain/quarantine native resources.
        return 0;
    }
    VK_OK(vkInvalidateMappedMemoryRanges(device,1,&dest));
    for(VkDeviceSize i=0;i<bytes;++i) REQUIRE(mapped[1][i]==(i>=stride && i<stride+unit ? expected[i-stride] : 0x35));
    // WHOLE_SIZE ends at this partial mapping's end, not allocation end.
    source.size=VK_WHOLE_SIZE; VK_OK(vkInvalidateMappedMemoryRanges(device,1,&source));
    REQUIRE(std::memcmp(mapped[0],expected.data(),unit)==0);
    for(VkDeviceSize i=unit;i<2*stride;++i) REQUIRE(mapped[0][i]==0x35);
    // Legal non-atom-multiple range ending at allocation end, then zero offset.
    dest.offset=5*stride; dest.size=4; std::memset(mapped[1]+dest.offset,0x79,4);
    VK_OK(vkFlushMappedMemoryRanges(device,1,&dest)); std::memset(mapped[1]+dest.offset,0x12,4);
    VK_OK(vkInvalidateMappedMemoryRanges(device,1,&dest)); for(int i=0;i<4;++i) REQUIRE(mapped[1][dest.offset+i]==0x79);
    dest.offset=0; dest.size=atom; std::memset(mapped[1],0x12,atom);
    VK_OK(vkInvalidateMappedMemoryRanges(device,1,&dest)); for(VkDeviceSize i=0;i<atom;++i) REQUIRE(mapped[1][i]==0x35);
    vkUnmapMemory(device,memory[0]); vkUnmapMemory(device,memory[1]);
    vkDestroyFence(device,fence,nullptr); vkDestroyCommandPool(device,pool,nullptr);
    for(auto b:buffers) vkDestroyBuffer(device,b,nullptr);
    for(auto m:memory) vkFreeMemory(device,m,nullptr);
    vkDestroyDevice(device,nullptr); vkDestroyInstance(instance,nullptr);
    std::puts("PASS query-aliases same-index allocation alias-copy flush invalidate partial-map allocation-end zero-offset");
}
