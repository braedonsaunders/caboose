// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// Real MoltenVK fixture for the latch copy (media_copy.mm): pictures (synthetic 420v and
// x420 pixel buffers, and a VideoToolbox-decoded H.264 frame) and carried pixels are copied
// into multi-planar and single-plane images and read back. Every copied byte must equal its
// source. Build and run: see the gfxstream README, "Phone-decoded video".
#include "media_apple.h"
#include "media_copy.h"
#include <VideoToolbox/VideoToolbox.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

using namespace caboose::gpuv2::media;

#define CHECK(c) do { if (!(c)) { std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c); std::exit(1); } } while (0)
#define VK(c) do { VkResult r_ = (c); if (r_ != VK_SUCCESS) { std::fprintf(stderr, "FAIL %s:%d %s = %d\n", __FILE__, __LINE__, #c, r_); std::exit(1); } } while (0)

namespace {
VkInstance instance;
VkPhysicalDevice physical;
VkDevice device;
VkQueue queue;
uint32_t family;
std::mutex queueMutex;
VulkanFunctions vk;

#define LOAD(name) reinterpret_cast<PFN_##name>(vkGetDeviceProcAddr(device, #name))
void setup() {
    VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
    app.apiVersion = VK_API_VERSION_1_2;
    const char* instanceExtensions[] = {VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME,
                                        VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME};
    VkInstanceCreateInfo ici{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    ici.flags = VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
    ici.pApplicationInfo = &app;
    ici.enabledExtensionCount = 2;
    ici.ppEnabledExtensionNames = instanceExtensions;
    VK(vkCreateInstance(&ici, nullptr, &instance));
    uint32_t count = 0;
    VK(vkEnumeratePhysicalDevices(instance, &count, nullptr));
    CHECK(count > 0);
    std::vector<VkPhysicalDevice> devices(count);
    VK(vkEnumeratePhysicalDevices(instance, &count, devices.data()));
    physical = devices[0];
    uint32_t families = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(physical, &families, nullptr);
    std::vector<VkQueueFamilyProperties> props(families);
    vkGetPhysicalDeviceQueueFamilyProperties(physical, &families, props.data());
    family = 0;
    while (family < families && !(props[family].queueFlags & VK_QUEUE_GRAPHICS_BIT)) ++family;
    CHECK(family < families);
    float priority = 1;
    VkDeviceQueueCreateInfo qci{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
    qci.queueFamilyIndex = family;
    qci.queueCount = 1;
    qci.pQueuePriorities = &priority;
    VkPhysicalDeviceVulkan11Features v11{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES};
    v11.samplerYcbcrConversion = VK_TRUE;
    const char* deviceExtensions[] = {"VK_EXT_metal_objects", "VK_KHR_portability_subset"};
    VkDeviceCreateInfo dci{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &v11};
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = &qci;
    dci.enabledExtensionCount = 2;
    dci.ppEnabledExtensionNames = deviceExtensions;
    VK(vkCreateDevice(physical, &dci, nullptr, &device));
    vkGetDeviceQueue(device, family, 0, &queue);
    struct {
        PFN_vkGetPhysicalDeviceMemoryProperties vkGetPhysicalDeviceMemoryProperties = ::vkGetPhysicalDeviceMemoryProperties;
        PFN_vkCreateImage vkCreateImage = LOAD(vkCreateImage);
        PFN_vkDestroyImage vkDestroyImage = LOAD(vkDestroyImage);
        PFN_vkCreateBuffer vkCreateBuffer = LOAD(vkCreateBuffer);
        PFN_vkDestroyBuffer vkDestroyBuffer = LOAD(vkDestroyBuffer);
        PFN_vkGetBufferMemoryRequirements vkGetBufferMemoryRequirements = LOAD(vkGetBufferMemoryRequirements);
        PFN_vkAllocateMemory vkAllocateMemory = LOAD(vkAllocateMemory);
        PFN_vkFreeMemory vkFreeMemory = LOAD(vkFreeMemory);
        PFN_vkBindBufferMemory vkBindBufferMemory = LOAD(vkBindBufferMemory);
        PFN_vkMapMemory vkMapMemory = LOAD(vkMapMemory);
        PFN_vkUnmapMemory vkUnmapMemory = LOAD(vkUnmapMemory);
        PFN_vkCreateCommandPool vkCreateCommandPool = LOAD(vkCreateCommandPool);
        PFN_vkDestroyCommandPool vkDestroyCommandPool = LOAD(vkDestroyCommandPool);
        PFN_vkAllocateCommandBuffers vkAllocateCommandBuffers = LOAD(vkAllocateCommandBuffers);
        PFN_vkBeginCommandBuffer vkBeginCommandBuffer = LOAD(vkBeginCommandBuffer);
        PFN_vkEndCommandBuffer vkEndCommandBuffer = LOAD(vkEndCommandBuffer);
        PFN_vkCmdPipelineBarrier vkCmdPipelineBarrier = LOAD(vkCmdPipelineBarrier);
        PFN_vkCmdCopyImage vkCmdCopyImage = LOAD(vkCmdCopyImage);
        PFN_vkCmdCopyBufferToImage vkCmdCopyBufferToImage = LOAD(vkCmdCopyBufferToImage);
        PFN_vkCreateFence vkCreateFence = LOAD(vkCreateFence);
        PFN_vkDestroyFence vkDestroyFence = LOAD(vkDestroyFence);
        PFN_vkWaitForFences vkWaitForFences = LOAD(vkWaitForFences);
        PFN_vkQueueSubmit vkQueueSubmit = LOAD(vkQueueSubmit);
    } table;
    vk = functionsFrom(table);
    vk.exportMetalObjects = LOAD(vkExportMetalObjectsEXT);
    CHECK(vk.complete());
}

uint32_t memoryType(uint32_t bits, VkMemoryPropertyFlags wanted) {
    VkPhysicalDeviceMemoryProperties p;
    vkGetPhysicalDeviceMemoryProperties(physical, &p);
    for (uint32_t i = 0; i < p.memoryTypeCount; ++i)
        if ((bits & (1u << i)) && (p.memoryTypes[i].propertyFlags & wanted) == wanted) return i;
    std::abort();
}

struct Image { VkImage image; VkDeviceMemory memory; VkFormat format; uint32_t w, h; };
Image makeImage(VkFormat format, uint32_t w, uint32_t h) {
    VkImageCreateInfo info{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
    info.imageType = VK_IMAGE_TYPE_2D;
    info.format = format;
    info.extent = {w, h, 1};
    info.mipLevels = info.arrayLayers = 1;
    info.samples = VK_SAMPLE_COUNT_1_BIT;
    info.tiling = VK_IMAGE_TILING_OPTIMAL;
    info.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
    Image img{VK_NULL_HANDLE, VK_NULL_HANDLE, format, w, h};
    VK(vkCreateImage(device, &info, nullptr, &img.image));
    VkMemoryRequirements req;
    vkGetImageMemoryRequirements(device, img.image, &req);
    VkMemoryAllocateInfo a{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    a.allocationSize = req.size;
    a.memoryTypeIndex = memoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    VK(vkAllocateMemory(device, &a, nullptr, &img.memory));
    VK(vkBindImageMemory(device, img.image, img.memory, 0));
    return img;
}

// Reads one plane (aspect) of `img`, `w` x `h` texels of `texel` bytes, tightly packed.
std::vector<uint8_t> readback(const Image& img, VkImageAspectFlags aspect, uint32_t w, uint32_t h, uint32_t texel) {
    const VkDeviceSize size = VkDeviceSize(w) * h * texel;
    VkBufferCreateInfo bi{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
    bi.size = size;
    bi.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    VkBuffer buffer;
    VK(vkCreateBuffer(device, &bi, nullptr, &buffer));
    VkMemoryRequirements req;
    vkGetBufferMemoryRequirements(device, buffer, &req);
    VkMemoryAllocateInfo a{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    a.allocationSize = req.size;
    a.memoryTypeIndex = memoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    VkDeviceMemory memory;
    VK(vkAllocateMemory(device, &a, nullptr, &memory));
    VK(vkBindBufferMemory(device, buffer, memory, 0));
    VkCommandPoolCreateInfo pi{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
    pi.queueFamilyIndex = family;
    VkCommandPool pool;
    VK(vkCreateCommandPool(device, &pi, nullptr, &pool));
    VkCommandBufferAllocateInfo ai{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
    ai.commandPool = pool;
    ai.commandBufferCount = 1;
    VkCommandBuffer cb;
    VK(vkAllocateCommandBuffers(device, &ai, &cb));
    VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    VK(vkBeginCommandBuffer(cb, &begin));
    VkImageMemoryBarrier b{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
    b.srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT;
    b.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    b.oldLayout = VK_IMAGE_LAYOUT_GENERAL;
    b.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    b.srcQueueFamilyIndex = b.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    b.image = img.image;
    b.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, 1, &b);
    VkBufferImageCopy region{};
    region.imageSubresource = {aspect, 0, 0, 1};
    region.imageExtent = {w, h, 1};
    vkCmdCopyImageToBuffer(cb, img.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buffer, 1, &region);
    VK(vkEndCommandBuffer(cb));
    VkSubmitInfo si{VK_STRUCTURE_TYPE_SUBMIT_INFO};
    si.commandBufferCount = 1;
    si.pCommandBuffers = &cb;
    {
        std::lock_guard<std::mutex> lock(queueMutex);
        VK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
        VK(vkQueueWaitIdle(queue));
    }
    void* p;
    VK(vkMapMemory(device, memory, 0, size, 0, &p));
    std::vector<uint8_t> out(static_cast<uint8_t*>(p), static_cast<uint8_t*>(p) + size);
    vkUnmapMemory(device, memory);
    vkDestroyCommandPool(device, pool, nullptr);
    vkDestroyBuffer(device, buffer, nullptr);
    vkFreeMemory(device, memory, nullptr);
    return out;
}

CopyTarget target(const Image& img, uint32_t planes) {
    CopyTarget t;
    t.vk = vk;
    t.physicalDevice = physical;
    t.device = device;
    t.queue = queue;
    t.queueFamily = family;
    t.queueMutex = &queueMutex;
    t.image = img.image;
    t.format = img.format;
    t.extent = {img.w, img.h};
    t.planes = planes;
    t.metalObjects = true;
    return t;
}

CVPixelBufferRef synthetic(OSType format, size_t w, size_t h) {
    NSDictionary* attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                                 (id)kCVPixelBufferMetalCompatibilityKey: @YES};
    CVPixelBufferRef pb = nullptr;
    CHECK(CVPixelBufferCreate(kCFAllocatorDefault, w, h, format, (__bridge CFDictionaryRef)attributes, &pb) == kCVReturnSuccess);
    CVPixelBufferLockBaseAddress(pb, 0);
    for (size_t plane = 0; plane < 2; ++plane) {
        auto* base = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pb, plane));
        const size_t stride = CVPixelBufferGetBytesPerRowOfPlane(pb, plane);
        for (size_t y = 0; y < CVPixelBufferGetHeightOfPlane(pb, plane); ++y)
            for (size_t x = 0; x < stride; ++x) base[y * stride + x] = uint8_t((x * 7 + y * 13 + plane * 101) & 0xff);
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

// The plane's rows of `w` texels of `texel` bytes, tightly packed.
std::vector<uint8_t> planeBytes(CVPixelBufferRef pb, size_t plane, uint32_t w, uint32_t h, uint32_t texel) {
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    auto* base = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pb, plane));
    const size_t stride = CVPixelBufferGetBytesPerRowOfPlane(pb, plane);
    std::vector<uint8_t> out;
    for (uint32_t y = 0; y < h; ++y) out.insert(out.end(), base + y * stride, base + y * stride + size_t(w) * texel);
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    return out;
}

void latchPicture(const CopyTarget& t, CVPixelBufferRef pb) {
    Pending pending;
    VK(copyPicture(t, pb, &pending));
    Reclaimer::instance().retire(std::move(pending), nullptr);
    Reclaimer::instance().drain();
}

// Every plane combination for one picture of bytes-per-sample `bps`.
void checkPicture(CVPixelBufferRef pb, unsigned bps, const char* name) {
    const uint32_t w = uint32_t(CVPixelBufferGetWidth(pb)), h = uint32_t(CVPixelBufferGetHeight(pb));
    const uint32_t cw = uint32_t(CVPixelBufferGetWidthOfPlane(pb, 1)), ch = uint32_t(CVPixelBufferGetHeightOfPlane(pb, 1));
    const VkFormat both = bps == 1 ? VK_FORMAT_G8_B8R8_2PLANE_420_UNORM : VK_FORMAT_G10X6_B10X6R10X6_2PLANE_420_UNORM_3PACK16;
    Image multi = makeImage(both, w, h);
    latchPicture(target(multi, kPlaneLuma | kPlaneChroma), pb);
    CHECK(readback(multi, VK_IMAGE_ASPECT_PLANE_0_BIT, w, h, bps) == planeBytes(pb, 0, w, h, bps));
    CHECK(readback(multi, VK_IMAGE_ASPECT_PLANE_1_BIT, cw, ch, 2 * bps) == planeBytes(pb, 1, cw, ch, 2 * bps));
    Image luma = makeImage(bps == 1 ? VK_FORMAT_R8_UNORM : VK_FORMAT_R16_UNORM, w, h);
    latchPicture(target(luma, kPlaneLuma), pb);
    CHECK(readback(luma, VK_IMAGE_ASPECT_COLOR_BIT, w, h, bps) == planeBytes(pb, 0, w, h, bps));
    Image chroma = makeImage(bps == 1 ? VK_FORMAT_R8G8_UNORM : VK_FORMAT_R16G16_UNORM, cw, ch);
    latchPicture(target(chroma, kPlaneChroma), pb);
    CHECK(readback(chroma, VK_IMAGE_ASPECT_COLOR_BIT, cw, ch, 2 * bps) == planeBytes(pb, 1, cw, ch, 2 * bps));
    // A picture in the wrong format is refused, not copied.
    Pending pending;
    CHECK(copyPicture(target(luma, kPlaneLuma | kPlaneChroma), pb, &pending) == VK_ERROR_FORMAT_NOT_SUPPORTED);
    for (Image* img : {&multi, &luma, &chroma}) {
        vkDestroyImage(device, img->image, nullptr);
        vkFreeMemory(device, img->memory, nullptr);
    }
    std::printf("ok picture %s %ux%u\n", name, w, h);
}

void checkPixels() {
    const uint32_t w = 37, h = 21, pitch = 64;  // odd sizes: chroma rounds up
    std::vector<uint8_t> bytes(size_t(pitch) * h + size_t(pitch) * ((h + 1) / 2));
    for (size_t i = 0; i < bytes.size(); ++i) bytes[i] = uint8_t(i * 31 + 5);
    LatchEntry e{};
    e.image = 1; e.kind = kPixels; e.planes = kPlaneLuma | kPlaneChroma; e.fourcc = kFourccNV12;
    e.width = w; e.height = h; e.pitch = pitch; e.uvOffset = pitch * h;
    e.pixels = bytes.data(); e.pixelBytes = bytes.size();
    Image multi = makeImage(VK_FORMAT_G8_B8R8_2PLANE_420_UNORM, w + 1, h + 1);
    Pending pending;
    VK(copyPixels(target(multi, e.planes), e, &pending));
    Reclaimer::instance().retire(std::move(pending), nullptr);
    Reclaimer::instance().drain();
    auto luma = readback(multi, VK_IMAGE_ASPECT_PLANE_0_BIT, w, h, 1);
    auto chroma = readback(multi, VK_IMAGE_ASPECT_PLANE_1_BIT, (w + 1) / 2, (h + 1) / 2, 2);
    for (uint32_t y = 0; y < h; ++y)
        CHECK(!std::memcmp(luma.data() + y * w, bytes.data() + y * pitch, w));
    for (uint32_t y = 0; y < (h + 1) / 2; ++y)
        CHECK(!std::memcmp(chroma.data() + y * (w + 1), bytes.data() + pitch * h + y * pitch, w + 1));
    std::printf("ok pixels %ux%u\n", w, h);
}

// One H.264 frame encoded and decoded by VideoToolbox, latched as the phone would.
CVPixelBufferRef decodedFrame() {
    __block CMSampleBufferRef encoded = nullptr;
    VTCompressionSessionRef compressor = nullptr;
    CHECK(VTCompressionSessionCreate(kCFAllocatorDefault, 640, 360, kCMVideoCodecType_H264, nullptr, nullptr, nullptr,
                                     nullptr, nullptr, &compressor) == noErr);
    CVPixelBufferRef source = synthetic(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 640, 360);
    CHECK(VTCompressionSessionEncodeFrameWithOutputHandler(compressor, source, CMTimeMake(0, 30), kCMTimeInvalid, nullptr,
        nullptr, ^(OSStatus status, VTEncodeInfoFlags, CMSampleBufferRef sample) {
            if (status == noErr && sample) encoded = (CMSampleBufferRef)CFRetain(sample);
        }) == noErr);
    VTCompressionSessionCompleteFrames(compressor, kCMTimeInvalid);
    VTCompressionSessionInvalidate(compressor);
    CFRelease(compressor);
    CVPixelBufferRelease(source);
    CHECK(encoded);
    CFDictionaryRef attributes = pictureAttributes();
    VTDecompressionSessionRef decompressor = nullptr;
    CHECK(VTDecompressionSessionCreate(kCFAllocatorDefault, CMSampleBufferGetFormatDescription(encoded), nullptr,
                                       attributes, nullptr, &decompressor) == noErr);
    CFRelease(attributes);
    __block CVPixelBufferRef decoded = nullptr;
    CHECK(VTDecompressionSessionDecodeFrameWithOutputHandler(decompressor, encoded, 0, nullptr,
        ^(OSStatus status, VTDecodeInfoFlags, CVImageBufferRef image, CMTime, CMTime) {
            if (status == noErr && image) decoded = CVPixelBufferRetain(image);
        }) == noErr);
    VTDecompressionSessionWaitForAsynchronousFrames(decompressor);
    VTDecompressionSessionInvalidate(decompressor);
    CFRelease(decompressor);
    CFRelease(encoded);
    CHECK(decoded);
    return decoded;
}
}

int main() {
    @autoreleasepool {
        setup();
        CVPixelBufferRef nv12 = synthetic(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 1920, 1080);
        checkPicture(nv12, 1, "420v");
        CVPixelBufferRelease(nv12);
        CVPixelBufferRef p010 = synthetic(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, 1280, 720);
        checkPicture(p010, 2, "x420");
        CVPixelBufferRelease(p010);
        CVPixelBufferRef frame = decodedFrame();
        { OSType f = CVPixelBufferGetPixelFormatType(frame); std::printf("decoded format %c%c%c%c\n", char(f >> 24), char(f >> 16), char(f >> 8), char(f)); }
        CHECK(biPlanarBytesPerSample(CVPixelBufferGetPixelFormatType(frame)) == 1);
        checkPicture(frame, 1, "VideoToolbox H.264");
        CVPixelBufferRelease(frame);
        checkPixels();
        vkDeviceWaitIdle(device);
        std::printf("media copy: all checks passed\n");
    }
    return 0;
}
