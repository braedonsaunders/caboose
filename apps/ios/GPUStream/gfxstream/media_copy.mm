// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "media_copy.h"
#include "media_apple.h"
#import <Metal/Metal.h>
#include <CoreVideo/CVMetalTextureCache.h>
#include <algorithm>
#include <condition_variable>
#include <deque>
#include <map>
#include <thread>
#include <vector>

namespace caboose::gpuv2::media {
bool VulkanFunctions::complete() const {
    return getPhysicalDeviceMemoryProperties && createImage && destroyImage && createBuffer && destroyBuffer &&
           getBufferMemoryRequirements && allocateMemory && freeMemory && bindBufferMemory && mapMemory &&
           unmapMemory && createCommandPool && destroyCommandPool && allocateCommandBuffers &&
           beginCommandBuffer && endCommandBuffer && cmdPipelineBarrier && cmdCopyImage &&
           cmdCopyBufferToImage && createFence && destroyFence && waitForFences && queueSubmit;
}

class PendingCopy {
public:
    explicit PendingCopy(const CopyTarget& t) : vk(t.vk), device(t.device) {}
    ~PendingCopy() {
        for (VkImage image : sources) vk.destroyImage(device, image, nullptr);
        for (CVMetalTextureRef texture : textures) CFRelease(texture);
        if (picture) CVPixelBufferRelease(picture);
        if (buffer) vk.destroyBuffer(device, buffer, nullptr);
        if (memory) vk.freeMemory(device, memory, nullptr);
        if (pool) vk.destroyCommandPool(device, pool, nullptr);
        if (fence) vk.destroyFence(device, fence, nullptr);
    }
    // Returns once the GPU no longer uses the resources: the fence signalled, or the device
    // was lost (a lost device runs nothing more).
    void wait() {
        if (!submitted) return;
        for (;;) {
            const VkResult r = vk.waitForFences(device, 1, &fence, VK_TRUE, 1000000000ull);
            if (r != VK_TIMEOUT) return;
        }
    }
    VulkanFunctions vk;
    VkDevice device;
    VkCommandPool pool = VK_NULL_HANDLE;
    VkCommandBuffer commands = VK_NULL_HANDLE;
    VkFence fence = VK_NULL_HANDLE;
    std::vector<VkImage> sources;
    std::vector<CVMetalTextureRef> textures;
    CVPixelBufferRef picture = nullptr;
    VkBuffer buffer = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    bool submitted = false;
};
void PendingCopyDeleter::operator()(PendingCopy* p) const { delete p; }

namespace {
enum class Shape { none, both, luma, chroma };
struct Layout { Shape shape; uint32_t bytesPerSample; };

Layout layoutOf(VkFormat format) {
    switch (format) {
    case VK_FORMAT_G8_B8R8_2PLANE_420_UNORM: return {Shape::both, 1};
    case VK_FORMAT_G10X6_B10X6R10X6_2PLANE_420_UNORM_3PACK16:
    case VK_FORMAT_G16_B16R16_2PLANE_420_UNORM: return {Shape::both, 2};
    case VK_FORMAT_R8_UNORM: return {Shape::luma, 1};
    case VK_FORMAT_R8G8_UNORM: return {Shape::chroma, 1};
    case VK_FORMAT_R16_UNORM:
    case VK_FORMAT_R10X6_UNORM_PACK16: return {Shape::luma, 2};
    case VK_FORMAT_R16G16_UNORM:
    case VK_FORMAT_R10X6G10X6_UNORM_2PACK16: return {Shape::chroma, 2};
    default: return {Shape::none, 0};
    }
}
uint32_t planesOf(Shape shape) {
    return shape == Shape::both ? (kPlaneLuma | kPlaneChroma) : shape == Shape::luma ? kPlaneLuma
         : shape == Shape::chroma ? kPlaneChroma : 0;
}
// The extent of the destination's plane that holds surface plane `chroma`.
VkExtent2D destinationPlane(const CopyTarget& t, bool chroma) {
    if (layoutOf(t.format).shape == Shape::both && chroma)
        return {(t.extent.width + 1) / 2, (t.extent.height + 1) / 2};
    return t.extent;
}
VkImageAspectFlags destinationAspect(const CopyTarget& t, bool chroma) {
    if (layoutOf(t.format).shape != Shape::both) return VK_IMAGE_ASPECT_COLOR_BIT;
    return chroma ? VK_IMAGE_ASPECT_PLANE_1_BIT : VK_IMAGE_ASPECT_PLANE_0_BIT;
}

VkImageMemoryBarrier barrier(VkImage image, VkImageLayout from, VkImageLayout to, VkAccessFlags src,
                             VkAccessFlags dst) {
    VkImageMemoryBarrier b{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
    b.srcAccessMask = src;
    b.dstAccessMask = dst;
    b.oldLayout = from;
    b.newLayout = to;
    b.srcQueueFamilyIndex = b.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    b.image = image;
    b.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    return b;
}

VkResult begin(const CopyTarget& t, PendingCopy& p) {
    VkCommandPoolCreateInfo pool{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
    pool.flags = VK_COMMAND_POOL_CREATE_TRANSIENT_BIT;
    pool.queueFamilyIndex = t.queueFamily;
    VkResult r = t.vk.createCommandPool(t.device, &pool, nullptr, &p.pool);
    if (r != VK_SUCCESS) return r;
    VkCommandBufferAllocateInfo allocate{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
    allocate.commandPool = p.pool;
    allocate.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    allocate.commandBufferCount = 1;
    if ((r = t.vk.allocateCommandBuffers(t.device, &allocate, &p.commands)) != VK_SUCCESS) return r;
    VkFenceCreateInfo fence{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    if ((r = t.vk.createFence(t.device, &fence, nullptr, &p.fence)) != VK_SUCCESS) return r;
    VkCommandBufferBeginInfo info{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    info.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    if ((r = t.vk.beginCommandBuffer(p.commands, &info)) != VK_SUCCESS) return r;
    // Overwrites the image: after every earlier read and write of it on this queue.
    auto in = barrier(t.image, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                      VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT, VK_ACCESS_TRANSFER_WRITE_BIT);
    t.vk.cmdPipelineBarrier(p.commands, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0,
                            0, nullptr, 0, nullptr, 1, &in);
    return VK_SUCCESS;
}

VkResult finish(const CopyTarget& t, PendingCopy& p) {
    // Before every later use, in GENERAL: the layout the application's barriers start from.
    auto out = barrier(t.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_GENERAL,
                       VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT);
    t.vk.cmdPipelineBarrier(p.commands, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0,
                            0, nullptr, 0, nullptr, 1, &out);
    VkResult r = t.vk.endCommandBuffer(p.commands);
    if (r != VK_SUCCESS) return r;
    VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &p.commands;
    std::unique_lock<std::mutex> lock;
    if (t.queueMutex) lock = std::unique_lock<std::mutex>(*t.queueMutex);
    r = t.vk.queueSubmit(t.queue, 1, &submit, p.fence);
    if (r == VK_SUCCESS) p.submitted = true;
    return r;
}

id<MTLDevice> metalDevice(const CopyTarget& t) {
    if (t.vk.exportMetalObjects) {
        VkExportMetalDeviceInfoEXT device{VK_STRUCTURE_TYPE_EXPORT_METAL_DEVICE_INFO_EXT};
        VkExportMetalObjectsInfoEXT info{VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT, &device};
        t.vk.exportMetalObjects(t.device, &info);
        if (device.mtlDevice) return device.mtlDevice;
    }
    static id<MTLDevice> fallback = MTLCreateSystemDefaultDevice();
    return fallback;
}

CVMetalTextureCacheRef textureCache(id<MTLDevice> device) {
    static std::mutex mutex;
    static std::map<void*, CVMetalTextureCacheRef>* caches = new std::map<void*, CVMetalTextureCacheRef>;
    std::lock_guard<std::mutex> lock(mutex);
    void* key = (__bridge void*)device;
    auto it = caches->find(key);
    if (it != caches->end()) return it->second;
    CVMetalTextureCacheRef cache = nullptr;
    if (CVMetalTextureCacheCreate(kCFAllocatorDefault, nullptr, device, nullptr, &cache) != kCVReturnSuccess)
        return nullptr;
    caches->emplace(key, cache);  // one per device, for the process's life
    return cache;
}

// One plane of the picture as a transfer-source image over its Metal texture.
VkResult importPlane(const CopyTarget& t, PendingCopy& p, CVPixelBufferRef picture, size_t plane,
                     unsigned bytesPerSample, VkImage* out) {
    id<MTLDevice> device = metalDevice(t);
    CVMetalTextureCacheRef cache = device ? textureCache(device) : nullptr;
    if (!cache) return VK_ERROR_INITIALIZATION_FAILED;
    const MTLPixelFormat pixel = plane == 0 ? (bytesPerSample == 1 ? MTLPixelFormatR8Unorm : MTLPixelFormatR16Unorm)
                                            : (bytesPerSample == 1 ? MTLPixelFormatRG8Unorm : MTLPixelFormatRG16Unorm);
    const size_t width = CVPixelBufferGetWidthOfPlane(picture, plane);
    const size_t height = CVPixelBufferGetHeightOfPlane(picture, plane);
    CVMetalTextureRef texture = nullptr;
    if (CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, picture, nullptr, pixel, width,
                                                  height, plane, &texture) != kCVReturnSuccess || !texture)
        return VK_ERROR_INITIALIZATION_FAILED;
    p.textures.push_back(texture);
    id<MTLTexture> metal = CVMetalTextureGetTexture(texture);
    if (!metal) return VK_ERROR_INITIALIZATION_FAILED;
    VkImportMetalTextureInfoEXT import{VK_STRUCTURE_TYPE_IMPORT_METAL_TEXTURE_INFO_EXT};
    import.plane = VK_IMAGE_ASPECT_PLANE_0_BIT;
    import.mtlTexture = metal;
    VkImageCreateInfo info{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, &import};
    info.imageType = VK_IMAGE_TYPE_2D;
    info.format = plane == 0 ? (bytesPerSample == 1 ? VK_FORMAT_R8_UNORM : VK_FORMAT_R16_UNORM)
                             : (bytesPerSample == 1 ? VK_FORMAT_R8G8_UNORM : VK_FORMAT_R16G16_UNORM);
    info.extent = {uint32_t(width), uint32_t(height), 1};
    info.mipLevels = info.arrayLayers = 1;
    info.samples = VK_SAMPLE_COUNT_1_BIT;
    info.tiling = VK_IMAGE_TILING_OPTIMAL;
    info.usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    // The texture already holds the picture: PREINITIALIZED keeps it across the transition.
    info.initialLayout = VK_IMAGE_LAYOUT_PREINITIALIZED;
    VkImage image = VK_NULL_HANDLE;
    const VkResult r = t.vk.createImage(t.device, &info, nullptr, &image);
    if (r != VK_SUCCESS) return r;
    p.sources.push_back(image);
    *out = image;
    return VK_SUCCESS;
}

uint32_t memoryType(const CopyTarget& t, uint32_t bits, VkMemoryPropertyFlags wanted) {
    VkPhysicalDeviceMemoryProperties properties;
    t.vk.getPhysicalDeviceMemoryProperties(t.physicalDevice, &properties);
    for (uint32_t i = 0; i < properties.memoryTypeCount; ++i)
        if ((bits & (1u << i)) && (properties.memoryTypes[i].propertyFlags & wanted) == wanted) return i;
    return UINT32_MAX;
}
}

bool formatHolds(VkFormat format, uint32_t planes, uint32_t bytesPerSample) {
    const Layout layout = layoutOf(format);
    return layout.shape != Shape::none && layout.bytesPerSample == bytesPerSample && planesOf(layout.shape) == planes;
}

VkResult copyPicture(const CopyTarget& t, CVPixelBufferRef picture, Pending* out) {
    out->reset();
    if (!t.vk.complete() || !t.metalObjects) return VK_ERROR_EXTENSION_NOT_PRESENT;
    const unsigned bps = biPlanarBytesPerSample(CVPixelBufferGetPixelFormatType(picture));
    if (!bps || CVPixelBufferGetPlaneCount(picture) != 2 || !formatHolds(t.format, t.planes, bps))
        return VK_ERROR_FORMAT_NOT_SUPPORTED;
    Pending pending(new PendingCopy(t));
    pending->picture = CVPixelBufferRetain(picture);
    std::vector<std::pair<size_t, VkImage>> planes;
    for (size_t plane = 0; plane < 2; ++plane) {
        if (!(t.planes & (plane == 0 ? kPlaneLuma : kPlaneChroma))) continue;
        VkImage source;
        const VkResult r = importPlane(t, *pending, picture, plane, bps, &source);
        if (r != VK_SUCCESS) return r;
        planes.emplace_back(plane, source);
    }
    VkResult r = begin(t, *pending);
    if (r != VK_SUCCESS) return r;
    std::vector<VkImageMemoryBarrier> sources;
    for (auto& [plane, source] : planes) {
        (void)plane;
        sources.push_back(barrier(source, VK_IMAGE_LAYOUT_PREINITIALIZED, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, 0,
                                  VK_ACCESS_TRANSFER_READ_BIT));
    }
    t.vk.cmdPipelineBarrier(pending->commands, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0,
                            0, nullptr, 0, nullptr, uint32_t(sources.size()), sources.data());
    for (auto& [plane, source] : planes) {
        const bool chroma = plane == 1;
        const VkExtent2D dst = destinationPlane(t, chroma);
        VkImageCopy region{};
        region.srcSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
        region.dstSubresource = {destinationAspect(t, chroma), 0, 0, 1};
        region.extent = {std::min<uint32_t>(dst.width, uint32_t(CVPixelBufferGetWidthOfPlane(picture, plane))),
                         std::min<uint32_t>(dst.height, uint32_t(CVPixelBufferGetHeightOfPlane(picture, plane))), 1};
        t.vk.cmdCopyImage(pending->commands, source, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, t.image,
                          VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
    }
    if ((r = finish(t, *pending)) != VK_SUCCESS) return r;
    *out = std::move(pending);
    return VK_SUCCESS;
}

VkResult copyPixels(const CopyTarget& t, const LatchEntry& e, Pending* out) {
    out->reset();
    if (!t.vk.complete()) return VK_ERROR_EXTENSION_NOT_PRESENT;
    const uint32_t bps = bytesPerSample(e.fourcc);
    if (e.kind != kPixels || e.planes != t.planes || !formatHolds(t.format, t.planes, bps))
        return VK_ERROR_FORMAT_NOT_SUPPORTED;
    Pending pending(new PendingCopy(t));
    VkBufferCreateInfo info{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
    info.size = e.pixelBytes;
    info.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
    info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    VkResult r = t.vk.createBuffer(t.device, &info, nullptr, &pending->buffer);
    if (r != VK_SUCCESS) return r;
    VkMemoryRequirements requirements;
    t.vk.getBufferMemoryRequirements(t.device, pending->buffer, &requirements);
    VkMemoryAllocateInfo allocate{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    allocate.allocationSize = requirements.size;
    allocate.memoryTypeIndex = memoryType(t, requirements.memoryTypeBits,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (allocate.memoryTypeIndex == UINT32_MAX) return VK_ERROR_OUT_OF_DEVICE_MEMORY;
    if ((r = t.vk.allocateMemory(t.device, &allocate, nullptr, &pending->memory)) != VK_SUCCESS) return r;
    if ((r = t.vk.bindBufferMemory(t.device, pending->buffer, pending->memory, 0)) != VK_SUCCESS) return r;
    void* mapped = nullptr;
    if ((r = t.vk.mapMemory(t.device, pending->memory, 0, VK_WHOLE_SIZE, 0, &mapped)) != VK_SUCCESS) return r;
    std::memcpy(mapped, e.pixels, size_t(e.pixelBytes));
    t.vk.unmapMemory(t.device, pending->memory);
    if ((r = begin(t, *pending)) != VK_SUCCESS) return r;
    VkDeviceSize offset = 0;
    std::vector<VkBufferImageCopy> regions;
    for (int plane = 0; plane < 2; ++plane) {
        const bool chroma = plane == 1;
        if (!(e.planes & (chroma ? kPlaneChroma : kPlaneLuma))) continue;
        const VkExtent2D dst = destinationPlane(t, chroma);
        const uint32_t rows = chroma ? (e.height + 1u) / 2u : e.height;
        const uint32_t columns = chroma ? (e.width + 1u) / 2u : e.width;
        VkBufferImageCopy region{};
        region.bufferOffset = offset;
        region.bufferRowLength = e.pitch / (bps * (chroma ? 2 : 1));
        region.imageSubresource = {destinationAspect(t, chroma), 0, 0, 1};
        region.imageExtent = {std::min(dst.width, columns), std::min(dst.height, rows), 1};
        regions.push_back(region);
        offset += VkDeviceSize(e.pitch) * rows;
    }
    t.vk.cmdCopyBufferToImage(pending->commands, pending->buffer, t.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                              uint32_t(regions.size()), regions.data());
    if ((r = finish(t, *pending)) != VK_SUCCESS) return r;
    *out = std::move(pending);
    return VK_SUCCESS;
}

struct Reclaimer::State {
    std::mutex mutex;
    std::condition_variable work, idle;
    std::deque<std::pair<Pending, std::shared_ptr<void>>> queue;
    bool busy = false;
};

Reclaimer& Reclaimer::instance() {
    static Reclaimer* reclaimer = new Reclaimer;  // its thread outlives every decoder
    return *reclaimer;
}

Reclaimer::State& Reclaimer::state() {
    static State* state = [] {
        auto* s = new State;
        std::thread([s] {
            for (;;) {
                std::pair<Pending, std::shared_ptr<void>> item;
                {
                    std::unique_lock<std::mutex> lock(s->mutex);
                    s->busy = false;
                    s->idle.notify_all();
                    s->work.wait(lock, [s] { return !s->queue.empty(); });
                    item = std::move(s->queue.front());
                    s->queue.pop_front();
                    s->busy = true;
                }
                if (item.first) item.first->wait();
                item.first.reset();   // resources first,
                item.second.reset();  // then the leases that kept their objects alive
            }
        }).detach();
        return s;
    }();
    return *state;
}

void Reclaimer::retire(Pending pending, std::shared_ptr<void> keepAlive) {
    State& s = state();
    {
        std::lock_guard<std::mutex> lock(s.mutex);
        s.queue.emplace_back(std::move(pending), std::move(keepAlive));
    }
    s.work.notify_one();
}

void Reclaimer::drain() {
    State& s = state();
    std::unique_lock<std::mutex> lock(s.mutex);
    s.idle.wait(lock, [&s] { return s.queue.empty() && !s.busy; });
}
}
