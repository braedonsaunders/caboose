// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// Experimental private presenter. No production route may call this until the
// wire, provider, ownership, and physical-device checks have all passed.
#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>
#include "presentation_api_draft.h"
#include "metal_surface_internal.h"
#include "presentation_copy_internal.h"
#include "presentation_query_internal.h"
#include "presentation_swapchain_internal.h"
#ifdef CABOOSE_GPU_INDEXED_WSI
#include "presentation_swapchain_api_draft.h"
#include "presentation_index_state.h"
#include "presentation_virtual_swapchain_internal.h"
#endif
#include "process_registry_presentation.h"
#include "vk_decoder_global_state.h"
#include <algorithm>
#include <cerrno>
#include <cstring>
#include <memory>
#include <mutex>
#include <new>
#include <thread>
#include <system_error>
#include <vector>

namespace caboose::gpuv2 { caboose_gfx_registry* virtualWsiRegistry(); }
using namespace caboose::gpuv2;
using gfxstream::host::vk::CaboosePresentationDevice;
using gfxstream::host::vk::CaboosePresentationInstance;
using gfxstream::host::vk::CaboosePresentationObjects;

struct caboose_gpu_surface_capabilities {
    caboose_gpu_surface_capabilities_view view{};
    std::vector<caboose_gpu_surface_format> formats;
    std::vector<caboose_gpu_candidate_format> candidates;
    std::vector<uint32_t> modes;
    std::vector<caboose_gpu_surface_queue_family> queues;
};
namespace {
constexpr uint64_t kFenceTimeoutNs = 5000000000ull;
std::mutex ownersMutex;
std::vector<caboose_gpu_surface*> owners;
bool nonzero(const uint8_t (&bytes)[16]) { for (auto byte : bytes) if (byte) return true; return false; }
bool same(const caboose_gpu_surface_identity& a, const caboose_gpu_surface_identity& b) {
    return a.process_token == b.process_token && a.window_id == b.window_id &&
        a.generation == b.generation && !std::memcmp(a.grant, b.grant, 16) &&
        !std::memcmp(a.compositor_epoch, b.compositor_epoch, 16);
}
int errorFor(VkResult result) {
    if (result == VK_ERROR_OUT_OF_HOST_MEMORY || result == VK_ERROR_OUT_OF_DEVICE_MEMORY) return ENOMEM;
    if (result == VK_ERROR_DEVICE_LOST) return ENODEV;
    if (result == VK_TIMEOUT || result == VK_NOT_READY) return ETIMEDOUT;
    if (result == VK_ERROR_FEATURE_NOT_PRESENT || result == VK_ERROR_FORMAT_NOT_SUPPORTED ||
        result == VK_ERROR_EXTENSION_NOT_PRESENT) return ENOTSUP;
    return EIO;
}
caboose_gpu_submit_result rejected(int error) {
    return {CABOOSE_GPU_SUBMIT_REJECTED, error, 0, 0};
}
caboose_gpu_submit_result driverResult(caboose_gpu_submit_disposition disposition, VkResult result) {
    return {disposition, (result == VK_SUCCESS || result == VK_SUBOPTIMAL_KHR) ? 0 : errorFor(result), 1, static_cast<int32_t>(result)};
}
caboose_gpu_submit_result operationResult(caboose_gpu_submit_disposition disposition, VkResult result,
                                           const PresentationProviderResult& provider) {
    if (provider.present) return driverResult(disposition, provider.value);
    return {disposition, disposition == CABOOSE_GPU_SUBMIT_QUEUED ? 0 : errorFor(result), 0, 0};
}
struct Frame {
    std::unique_ptr<CaboosePresentationObjects> source;
    VkCommandPool pool = VK_NULL_HANDLE;
    VkCommandBuffer command = VK_NULL_HANDLE;
    VkSemaphore acquired = VK_NULL_HANDLE, ready = VK_NULL_HANDLE;
    VkFence copyFence = VK_NULL_HANDLE, presentFence = VK_NULL_HANDLE;
    bool gotImage = false, submitted = false, presentQueued = false;
    bool sourceReleased = false, presentRetired = false, deviceLost = false;
    bool failureReported = false;
    bool reportedDeviceLoss = false;
    uint64_t serial = 0;
    caboose_gpu_present_callback callback = nullptr;
    void* context = nullptr;
};
}
struct caboose_gpu_surface {
    std::mutex mutex;
    std::mutex operations;
    caboose_gpu_surface_bind_info bind{};
    std::unique_ptr<CaboosePresentationInstance> instance;
    MetalSurface* metal = nullptr;
    bool attached = false, revoked = false, retired = false;
    uint64_t physicalBox = 0, lastSerial = 0;
    VkPhysicalDevice physical = VK_NULL_HANDLE;
    std::unique_ptr<CaboosePresentationDevice> device;
    VkSwapchainKHR swapchain = VK_NULL_HANDLE;
    std::vector<VkImage> images;
    VkFormat format = VK_FORMAT_UNDEFINED;
    uint64_t boxedDevice = 0, boxedQueue = 0;
    uint32_t queueFamily = 0;
    std::unique_ptr<Frame> frame;
    std::thread worker;
    bool frameDone = false;
#ifdef CABOOSE_GPU_INDEXED_WSI
    uint64_t nextSwapchainId = 1;
    caboose_gpu_virtual_swapchain* indexed = nullptr;
#endif
};
namespace {
void destroyFrameResources(caboose_gpu_surface& s, Frame& f) {
    auto* vk = s.device->vk;
    if (f.copyFence) vk->vkDestroyFence(s.device->device, f.copyFence, nullptr);
    if (f.presentFence) vk->vkDestroyFence(s.device->device, f.presentFence, nullptr);
    if (f.acquired) vk->vkDestroySemaphore(s.device->device, f.acquired, nullptr);
    if (f.ready) vk->vkDestroySemaphore(s.device->device, f.ready, nullptr);
    if (f.pool) vk->vkDestroyCommandPool(s.device->device, f.pool, nullptr);
    f.source.reset();
}
VkResult allocateFrame(caboose_gpu_surface& s, Frame& f, PresentationProviderResult* provider) {
    *provider = {};
    auto driverFailure = [provider](VkResult result) { return provider->record(result); };
    auto* vk = s.device->vk;
    if (!vk || !vk->vkCreateCommandPool || !vk->vkDestroyCommandPool || !vk->vkAllocateCommandBuffers ||
        !vk->vkCreateSemaphore || !vk->vkDestroySemaphore || !vk->vkCreateFence || !vk->vkDestroyFence)
        return VK_ERROR_INITIALIZATION_FAILED;
    VkCommandPoolCreateInfo pi{}; pi.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    pi.queueFamilyIndex = s.queueFamily; pi.flags = VK_COMMAND_POOL_CREATE_TRANSIENT_BIT;
    VkResult r = vk->vkCreateCommandPool(s.device->device, &pi, nullptr, &f.pool);
    if (r != VK_SUCCESS) return driverFailure(r);
    VkCommandBufferAllocateInfo ai{}; ai.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    ai.commandPool = f.pool; ai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; ai.commandBufferCount = 1;
    r = vk->vkAllocateCommandBuffers(s.device->device, &ai, &f.command);
    if (r != VK_SUCCESS) return driverFailure(r);
    VkSemaphoreCreateInfo si{}; si.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    r = vk->vkCreateSemaphore(s.device->device, &si, nullptr, &f.acquired);
    if (r != VK_SUCCESS) return driverFailure(r);
    r = vk->vkCreateSemaphore(s.device->device, &si, nullptr, &f.ready);
    if (r != VK_SUCCESS) return driverFailure(r);
    VkFenceCreateInfo fi{}; fi.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    r = vk->vkCreateFence(s.device->device, &fi, nullptr, &f.copyFence);
    if (r != VK_SUCCESS) return driverFailure(r);
    return provider->record(vk->vkCreateFence(s.device->device, &fi, nullptr, &f.presentFence));
}
// Caller is the frame worker or a serialized retire worker. Callbacks are not
// made while the surface mutex is held. An uncertain frame is never destroyed.
int advanceFrame(caboose_gpu_surface& s, Frame& f) {
    if (f.deviceLost) {
        if (!f.reportedDeviceLoss && f.callback) {
            f.reportedDeviceLoss = true;
            f.callback(f.context, f.serial, CABOOSE_GPU_DEVICE_LOST,
                       driverResult(CABOOSE_GPU_SUBMIT_UNCERTAIN, VK_ERROR_DEVICE_LOST));
        }
        return 0;
    }
    if (!s.device || !s.device->vk || !s.device->vk->vkWaitForFences || !s.device->device ||
        (f.submitted && !f.copyFence) || (f.presentQueued && !f.presentFence)) {
        if (!f.failureReported && f.callback) {
            f.failureReported = true;
            f.callback(f.context, f.serial, CABOOSE_GPU_FAILED_UNRETIRED,
                       {CABOOSE_GPU_SUBMIT_UNCERTAIN, EIO, 0, 0});
        }
        return EIO;
    }
    if ((!f.submitted || !f.presentQueued) && !f.failureReported && f.callback) {
        f.failureReported = true;
        f.callback(f.context, f.serial, CABOOSE_GPU_FAILED_UNRETIRED,
                   {CABOOSE_GPU_SUBMIT_UNCERTAIN, EIO, 0, 0});
    }
    if (f.submitted && !f.sourceReleased && !f.deviceLost) {
        VkResult r = waitPresentationFence(*s.device, f.copyFence, kFenceTimeoutNs);
        if (r == VK_SUCCESS) {
            f.sourceReleased = true;
            f.source.reset();
            if (f.callback) f.callback(f.context, f.serial, CABOOSE_GPU_SOURCE_RELEASED,
                                        driverResult(CABOOSE_GPU_SUBMIT_QUEUED, r));
        } else if (r == VK_ERROR_DEVICE_LOST) {
            f.deviceLost = true;
            if (f.callback) f.callback(f.context, f.serial, CABOOSE_GPU_DEVICE_LOST,
                                        driverResult(CABOOSE_GPU_SUBMIT_UNCERTAIN, r));
        } else {
            if (!f.failureReported && f.callback) {
                f.failureReported = true;
                f.callback(f.context, f.serial, CABOOSE_GPU_FAILED_UNRETIRED,
                           driverResult(CABOOSE_GPU_SUBMIT_UNCERTAIN, r));
            }
            return errorFor(r);
        }
    }
    if (f.deviceLost) return 0;
    if (!f.submitted || !f.presentQueued) return EBUSY;
    if (!f.presentRetired) {
        VkResult r = waitPresentationFence(*s.device, f.presentFence, kFenceTimeoutNs);
        if (r == VK_SUCCESS) f.presentRetired = true;
        else if (r == VK_ERROR_DEVICE_LOST) {
            f.deviceLost = true;
            if (!f.reportedDeviceLoss && f.callback) {
                f.reportedDeviceLoss = true;
                f.callback(f.context, f.serial, CABOOSE_GPU_DEVICE_LOST,
                           driverResult(CABOOSE_GPU_SUBMIT_UNCERTAIN, r));
            }
        } else return errorFor(r);
    }
    return f.deviceLost || (f.sourceReleased && f.presentRetired) ? 0 : EBUSY;
}
}

extern "C" int caboose_gpu_surface_prepare(const caboose_gpu_surface_bind_info* bind,
                                             caboose_gpu_surface** out) {
    if (!out) return EINVAL;
    *out = nullptr;
    if (!bind || !bind->identity.process_token || !bind->identity.window_id || !bind->identity.generation ||
        !nonzero(bind->identity.grant) || !nonzero(bind->identity.compositor_epoch) ||
        !bind->boxed_instance || !bind->width || !bind->height) return EINVAL;
    auto* registry = virtualWsiRegistry();
    if (!registry) return ENODEV;
    try {
        auto surface = std::make_unique<caboose_gpu_surface>();
        surface->bind = *bind;
        VkResult r = acquirePresentationInstance(registry, bind->identity.process_token,
                                                  bind->boxed_instance, &surface->instance);
        if (r != VK_SUCCESS) return errorFor(r);
        std::lock_guard<std::mutex> lock(ownersMutex);
        for (auto* owner : owners) {
            if (owner->bind.identity.window_id == bind->identity.window_id &&
                !std::memcmp(owner->bind.identity.compositor_epoch, bind->identity.compositor_epoch, 16))
                return EBUSY;
        }
        owners.push_back(surface.get());
        *out = surface.release();
        return 0;
    } catch (const std::bad_alloc&) { return ENOMEM; }
}
extern "C" int caboose_gpu_surface_attach(caboose_gpu_surface* surface, CAMetalLayer* layer) {
    if (!surface || !layer || ![NSThread isMainThread]) return EINVAL;
    std::unique_lock<std::mutex> operation(surface->operations, std::try_to_lock);
    if (!operation.owns_lock()) return EBUSY;
    std::lock_guard<std::mutex> lock(surface->mutex);
    if (surface->revoked || surface->attached) return EBUSY;
    VkResult r = VK_SUCCESS;
    const int result = createMetalSurface(surface->instance->instance, (__bridge void*)layer,
                                           &surface->metal, &r);
    if (result) return result;
    surface->attached = true;
    return 0;
}
extern "C" int caboose_gpu_surface_query(caboose_gpu_surface* surface, uint64_t boxedPhysical,
                                           caboose_gpu_surface_capabilities** out,
                                           caboose_gpu_query_status* status) {
    if (!status) return EINVAL;
    *status = {};
    if (!out) { status->native_error = EINVAL; return EINVAL; }
    *out = nullptr;
    auto fail = [status](int error) { status->native_error = error; return error; };
    if (!surface || !boxedPhysical) return fail(EINVAL);
    std::lock_guard<std::mutex> operation(surface->operations);
    auto* registry = virtualWsiRegistry();
    if (!registry) return fail(ENODEV);
    try {
        std::lock_guard<std::mutex> lock(surface->mutex);
        if (!surface->attached || surface->revoked || surface->swapchain ||
            (surface->physicalBox && surface->physicalBox != boxedPhysical)) return fail(EBUSY);
        std::unique_ptr<gfxstream::host::vk::CaboosePresentationPhysicalDevice> physical;
        VkResult r = acquirePresentationPhysicalDevice(registry, surface->bind.identity.process_token,
            surface->bind.boxed_instance, boxedPhysical, &physical);
        if (r != VK_SUCCESS) return fail(errorFor(r));
        PresentationSurfaceCapabilities raw{};
        PresentationQueryStatus queryStatus{};
        r = queryPresentationSurface(*physical, metalSurfaceHandle(surface->metal), &raw, &queryStatus);
        if (r != VK_SUCCESS) {
            if (queryStatus.hasDriverResult) {
                status->has_vulkan_result = 1;
                status->vulkan_result = static_cast<int32_t>(queryStatus.driverResult);
            }
            return fail(errorFor(r));
        }
        auto result = std::make_unique<caboose_gpu_surface_capabilities>();
        auto& v = result->view; auto& c = raw.capabilities;
        v.min_image_count = c.minImageCount; v.max_image_count = c.maxImageCount;
        v.current_width = c.currentExtent.width; v.current_height = c.currentExtent.height;
        v.min_width = c.minImageExtent.width; v.min_height = c.minImageExtent.height;
        v.max_width = c.maxImageExtent.width; v.max_height = c.maxImageExtent.height;
        v.max_image_array_layers = c.maxImageArrayLayers; v.supported_transforms = c.supportedTransforms;
        v.current_transform = c.currentTransform; v.supported_composite_alpha = c.supportedCompositeAlpha;
        v.supported_usage_flags = c.supportedUsageFlags;
        for (const auto& f : raw.formats) result->formats.push_back({static_cast<uint32_t>(f.surface.format),
            static_cast<uint32_t>(f.surface.colorSpace), f.properties.linearTilingFeatures,
            f.properties.optimalTilingFeatures, f.properties.bufferFeatures, f.propertiesQueried ? 1u : 0u});
        for (const auto& f : raw.candidateFormats) result->candidates.push_back({static_cast<uint32_t>(f.format),
            f.properties.linearTilingFeatures, f.properties.optimalTilingFeatures, f.properties.bufferFeatures});
        for (auto mode : raw.modes) result->modes.push_back(static_cast<uint32_t>(mode));
        for (const auto& q : raw.queueFamilies) result->queues.push_back({q.properties.queueFlags,
            q.properties.queueCount, q.presentSupported});
        v.format_count = static_cast<uint32_t>(result->formats.size());
        v.candidate_format_count = static_cast<uint32_t>(result->candidates.size());
        v.present_mode_count = static_cast<uint32_t>(result->modes.size());
        v.queue_family_count = static_cast<uint32_t>(result->queues.size());
        v.formats = result->formats.data(); v.candidate_formats = result->candidates.data();
        v.present_modes = result->modes.data(); v.queue_families = result->queues.data();
        surface->physicalBox = boxedPhysical;
        surface->physical = physical->physicalDevice;
        *out = result.release();
        status->has_vulkan_result = 1;
        status->vulkan_result = static_cast<int32_t>(queryStatus.driverResult);
        return 0;
    } catch (const std::bad_alloc&) { return fail(ENOMEM); }
}
extern "C" const caboose_gpu_surface_capabilities_view* caboose_gpu_surface_capabilities_get(
    const caboose_gpu_surface_capabilities* capabilities) { return capabilities ? &capabilities->view : nullptr; }
extern "C" void caboose_gpu_surface_capabilities_release(caboose_gpu_surface_capabilities* capabilities) {
    delete capabilities;
}

extern "C" caboose_gpu_submit_result caboose_gpu_surface_present(
    caboose_gpu_surface* s, const caboose_gpu_present_info* p,
    caboose_gpu_present_callback callback, void* context) {
    if (!s || !p || !callback || !same(s->bind.identity, p->identity) || !p->present_serial ||
        !p->boxed_device || !p->boxed_queue || !p->boxed_image ||
        p->width != s->bind.width || p->height != s->bind.height ||
        p->vk_image_layout != VK_IMAGE_LAYOUT_GENERAL ||
        p->wait_semaphore_count > CABOOSE_GPU_PRESENT_MAX_WAIT_SEMAPHORES ||
        (p->wait_semaphore_count && !p->boxed_wait_semaphores)) return rejected(EINVAL);
    std::lock_guard<std::mutex> operation(s->operations);
    auto* registry = virtualWsiRegistry();
    if (!registry) return rejected(ENODEV);
    try {
        {
            std::lock_guard<std::mutex> lock(s->mutex);
            if (!s->attached || s->revoked || !s->physical || p->present_serial <= s->lastSerial)
                return rejected(EBUSY);
#ifdef CABOOSE_GPU_INDEXED_WSI
            if (s->indexed) return rejected(EBUSY);
#endif
            if (s->frame && !s->frameDone) return rejected(EBUSY);
        }
        if (s->worker.joinable()) s->worker.join();
        if (s->frame) { destroyFrameResources(*s, *s->frame); s->frame.reset(); s->frameDone = false; }
        if (s->device && (s->boxedDevice != p->boxed_device || s->boxedQueue != p->boxed_queue ||
                          s->queueFamily != p->queue_family || s->format != static_cast<VkFormat>(p->vk_format)))
            return rejected(ENOTSUP);
        std::unique_ptr<CaboosePresentationObjects> source;
        PresentationProviderResult provider{};
        VkResult r = acquirePresentationObjects(registry, s->bind.boxed_instance, *p, &source);
        if (r != VK_SUCCESS) return rejected(errorFor(r));
        if (!s->device) {
            std::unique_ptr<CaboosePresentationDevice> device;
            r = acquirePresentationDevice(registry, p->identity.process_token, s->bind.boxed_instance,
                                           p->boxed_device, p->boxed_queue, p->queue_family, &device);
            if (r != VK_SUCCESS) return rejected(errorFor(r));
            if (device->physicalDevice != s->physical) return rejected(EINVAL);
            s->device = std::move(device);
            s->boxedDevice = p->boxed_device; s->boxedQueue = p->boxed_queue;
            s->queueFamily = p->queue_family; s->format = static_cast<VkFormat>(p->vk_format);
            r = createPresentationSwapchain(*s->device, metalSurfaceHandle(s->metal), s->format,
                                            s->bind.width, s->bind.height, &s->swapchain, &s->images, &provider);
            if (r != VK_SUCCESS) { s->device.reset(); return operationResult(CABOOSE_GPU_SUBMIT_REJECTED, r, provider); }
        }
        if (source->device != s->device->device || source->queue != s->device->queue ||
            source->physicalDevice != s->physical) return rejected(EINVAL);
        auto frame = std::make_unique<Frame>();
        frame->source = std::move(source); frame->serial = p->present_serial;
        frame->callback = callback; frame->context = context;
        r = allocateFrame(*s, *frame, &provider);
        if (r != VK_SUCCESS) { destroyFrameResources(*s, *frame); return operationResult(CABOOSE_GPU_SUBMIT_REJECTED, r, provider); }
        uint32_t index = 0;
        r = acquirePresentationImage(*s->device, s->swapchain, 0, frame->acquired, &index, &provider);
        if (r != VK_SUCCESS && r != VK_SUBOPTIMAL_KHR) {
            destroyFrameResources(*s, *frame); return operationResult(CABOOSE_GPU_SUBMIT_REJECTED, r, provider);
        }
        frame->gotImage = true;
        s->lastSerial = p->present_serial;
        if (index < s->images.size()) {
            r = submitPresentationCopy(*frame->source, s->images[index], frame->acquired,
                                       frame->ready, frame->copyFence, frame->command, &provider);
            frame->submitted = r == VK_SUCCESS;
            if (frame->submitted) {
                r = queuePresentation(*frame->source, s->swapchain, index, frame->ready, frame->presentFence, &provider);
                frame->presentQueued = r == VK_SUCCESS || r == VK_SUBOPTIMAL_KHR;
            }
        } else { r = VK_ERROR_INITIALIZATION_FAILED; provider = {}; }
        frame->deviceLost = provider.present && provider.value == VK_ERROR_DEVICE_LOST;
        const bool accepted = frame->submitted && frame->presentQueued;
        s->frame = std::move(frame);
        try {
            s->worker = std::thread([s] {
                int result = advanceFrame(*s, *s->frame);
                std::lock_guard<std::mutex> lock(s->mutex);
                s->frameDone = result == 0;
            });
        } catch (const std::system_error&) {
            return {CABOOSE_GPU_SUBMIT_UNCERTAIN, EAGAIN, provider.present ? 1u : 0u,
                    provider.present ? static_cast<int32_t>(provider.value) : 0};
        }
        return operationResult(accepted ? CABOOSE_GPU_SUBMIT_QUEUED : CABOOSE_GPU_SUBMIT_UNCERTAIN, r, provider);
    } catch (const std::bad_alloc&) { return rejected(ENOMEM); }
}

extern "C" int caboose_gpu_surface_retire(caboose_gpu_surface* s) {
    if (!s || [NSThread isMainThread]) return EINVAL;
    std::lock_guard<std::mutex> operation(s->operations);
    {
        std::lock_guard<std::mutex> lock(s->mutex);
        s->revoked = true;
    }
#ifdef CABOOSE_GPU_INDEXED_WSI
    if (s->indexed) return EBUSY;
#endif
    if (s->worker.joinable()) {
        if (s->worker.get_id() == std::this_thread::get_id()) return EDEADLK;
        s->worker.join();
    }
    if (s->frame) {
        if (!s->frameDone) {
            int result = advanceFrame(*s, *s->frame);
            if (result) return result;
        }
        destroyFrameResources(*s, *s->frame);
        s->frame.reset();
    }
    if (s->swapchain) {
        int result = destroyPresentationSwapchain(*s->device, s->swapchain);
        if (result) return result;
        s->swapchain = VK_NULL_HANDLE;
        s->images.clear();
    }
    s->device.reset();
    std::lock_guard<std::mutex> lock(s->mutex);
    s->retired = true;
    return 0;
}

extern "C" int caboose_gpu_surface_detach(caboose_gpu_surface** ptr) {
    if (!ptr || !*ptr || ![NSThread isMainThread]) return EINVAL;
    caboose_gpu_surface* s = *ptr;
    std::unique_lock<std::mutex> operation(s->operations, std::try_to_lock);
    if (!operation.owns_lock()) return EBUSY;
    {
        std::lock_guard<std::mutex> lock(s->mutex);
        if (!s->retired) return EBUSY;
        if (s->metal) {
            int result = destroyMetalSurface(&s->metal);
            if (result) return result;
        }
    }
    {
        std::lock_guard<std::mutex> lock(ownersMutex);
        auto it = std::find(owners.begin(), owners.end(), s);
        if (it == owners.end()) return EINVAL;
        owners.erase(it);
    }
    *ptr = nullptr;
    operation.unlock();
    delete s;
    return 0;
}

#ifdef CABOOSE_GPU_INDEXED_WSI
// This incomplete private path is intentionally not enabled by any build target
// until indexed acquire, present and retirement are implemented and reviewed.
struct caboose_gpu_virtual_swapchain {
    caboose_gpu_surface* surface = nullptr;
    uint64_t id = 0;
    caboose_gpu_swapchain_create_info info{};
    std::unique_ptr<gfxstream::host::vk::CabooseSwapchainDevice> device;
    std::unique_ptr<gfxstream::host::vk::CabooseMappedSources> sources;
    VkSwapchainKHR handle = VK_NULL_HANDLE;
    std::vector<VkImage> nativeImages;
    std::vector<uint64_t> boxedImages;
    std::unique_ptr<PresentationIndexState> indices;
    std::mutex mutex;
};
extern "C" int caboose_gpu_virtual_swapchain_create(caboose_gpu_surface* surface,
    const caboose_gpu_swapchain_create_info* info, caboose_gpu_virtual_swapchain** out,
    uint64_t* swapchainId, uint32_t* imageCount, caboose_gpu_query_status* status) {
    if (!status) return EINVAL;
    *status = {};
    auto fail = [status](int error) { status->native_error = error; return error; };
    if (!out || !swapchainId || !imageCount) return fail(EINVAL);
    *out = nullptr; *swapchainId = 0; *imageCount = 0;
    if (!surface || !info || !same(surface->bind.identity, info->identity) ||
        !info->boxed_device || info->width != surface->bind.width ||
        info->height != surface->bind.height) return fail(EINVAL);
    std::lock_guard<std::mutex> operation(surface->operations);
    auto* registry = virtualWsiRegistry();
    if (!registry) return fail(ENODEV);
    try {
        {
            std::lock_guard<std::mutex> lock(surface->mutex);
            if (!surface->attached || surface->revoked || !surface->physical ||
                surface->swapchain || surface->indexed) return fail(EBUSY);
        }
        if (!surface->nextSwapchainId) return fail(EOVERFLOW);
        auto result = std::make_unique<caboose_gpu_virtual_swapchain>();
        result->surface = surface;
        result->info = *info;
        // Supported exclusive mode has no retained queue family array.
        result->info.queue_families = nullptr;
        VkResult r = acquireSwapchainDevice(registry, info->identity.process_token,
            surface->bind.boxed_instance, info->boxed_device, &result->device);
        if (r != VK_SUCCESS) return fail(errorFor(r));
        if (result->device->physicalDevice != surface->physical) return fail(EINVAL);
        PresentationProviderResult provider{};
        r = createVirtualSwapchain(*result->device, metalSurfaceHandle(surface->metal), *info,
                                   &result->handle, &result->nativeImages, &provider);
        if (r != VK_SUCCESS) {
            if (provider.present) { status->has_vulkan_result = 1; status->vulkan_result = provider.value; }
            return fail(errorFor(r));
        }
        try {
            result->indices = std::make_unique<PresentationIndexState>(
                static_cast<uint32_t>(result->nativeImages.size()));
        } catch (const std::bad_alloc&) {
            result->device->vk->vkDestroySwapchainKHR(result->device->device, result->handle, nullptr);
            return fail(ENOMEM);
        }
        result->id = surface->nextSwapchainId++;
        *swapchainId = result->id;
        *imageCount = static_cast<uint32_t>(result->nativeImages.size());
        status->has_vulkan_result = 1; status->vulkan_result = VK_SUCCESS;
        surface->indexed = result.get();
        *out = result.release();
        return 0;
    } catch (const std::bad_alloc&) { return fail(ENOMEM); }
}
extern "C" int caboose_gpu_virtual_swapchain_map(caboose_gpu_virtual_swapchain* swapchain,
    const uint64_t* boxedImages, uint32_t imageCount) {
    if (!swapchain || !boxedImages || !imageCount || imageCount != swapchain->nativeImages.size()) return EINVAL;
    std::lock_guard<std::mutex> operation(swapchain->surface->operations);
    std::lock_guard<std::mutex> lock(swapchain->mutex);
    if (swapchain->surface->revoked || swapchain->sources) return EBUSY;
    auto* registry = virtualWsiRegistry();
    if (!registry) return ENODEV;
    try {
        std::vector<uint64_t> copied(boxedImages, boxedImages + imageCount);
        std::unique_ptr<gfxstream::host::vk::CabooseMappedSources> sources;
        const auto& info = swapchain->info;
        VkResult r = acquireMappedSources(registry, info.identity.process_token,
            swapchain->surface->bind.boxed_instance, info.boxed_device, info.vk_format,
            info.width, info.height, info.image_usage, imageCount, copied.data(), &sources);
        if (r != VK_SUCCESS) return errorFor(r);
        swapchain->boxedImages = std::move(copied);
        swapchain->sources = std::move(sources);
        return 0;
    } catch (const std::bad_alloc&) { return ENOMEM; }
}
#endif
