// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// Experimental private presenter. No production route may call this until the
// wire, provider, ownership, and physical-device checks have all passed.
#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>
#include "presentation_api_draft.h"
#include "metal_surface_internal.h"
#include "presentation_copy_internal.h"
#include "presentation_capture_internal.h"
#include "presentation_capture_state.h"
#include "presentation_query_internal.h"
#include "presentation_swapchain_internal.h"
#ifdef CABOOSE_GPU_INDEXED_WSI
#include "presentation_acquire_internal.h"
#include "presentation_swapchain_api_draft.h"
#include "presentation_index_state.h"
#include "presentation_extent_state.h"
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
#ifdef CABOOSE_GPU_INDEXED_WSI
namespace caboose::gpuv2 { caboose_gfx_registry* indexedWsiRegistry(); }
#endif
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
#ifdef CABOOSE_GPU_INDEXED_WSI
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
    std::shared_ptr<std::mutex> hostMutex;
    std::shared_ptr<void> lifetime;
    size_t requests = 0;
    bool quarantined = false;
    bool retiring = false;
    bool acquireBusy = false;
    bool hasQueueFamily = false;
    uint32_t queueFamily = 0;
    std::mutex mutex;
};
#endif
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
#ifdef CABOOSE_GPU_INDEXED_WSI
    caboose_gpu_virtual_swapchain* indexed = nullptr;
#endif
    std::unique_ptr<CaboosePresentationObjects> source;
    VkCommandPool pool = VK_NULL_HANDLE;
    VkCommandBuffer command = VK_NULL_HANDLE;
    VkSemaphore acquired = VK_NULL_HANDLE, ready = VK_NULL_HANDLE;
    VkFence copyFence = VK_NULL_HANDLE, presentFence = VK_NULL_HANDLE;
    bool gotImage = false, submitted = false, presentQueued = false;
    bool sourceReleased = false, presentRetired = false, deviceLost = false;
    bool failureReported = false;
    bool reportedDeviceLoss = false;
    bool resourcesDestroyed = false;
    uint64_t serial = 0;
    caboose_gpu_present_callback callback = nullptr;
    void* context = nullptr;
    bool captured = false; // a capture slot was written for this serial
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
    // Presented-picture captures for phone-owned scrolling. The ring lives on `device`.
    std::unique_ptr<PresentationCaptureRing> capture;
    PresentationCaptureState captureState;
    caboose_gpu_capture_callback captureCallback = nullptr;
    void* captureContext = nullptr;
    bool captureUnsupported = false;
#ifdef CABOOSE_GPU_INDEXED_WSI
    uint64_t nextSwapchainId = 1;
    caboose_gpu_virtual_swapchain* indexed = nullptr;
    PresentationExtentState extent;
#endif
};
namespace {
void destroyFrameResources(caboose_gpu_surface& s, Frame& f) {
    if (f.resourcesDestroyed) return;
    auto* vk = s.device->vk;
    if (f.copyFence) vk->vkDestroyFence(s.device->device, f.copyFence, nullptr);
    if (f.presentFence) vk->vkDestroyFence(s.device->device, f.presentFence, nullptr);
    if (f.acquired) vk->vkDestroySemaphore(s.device->device, f.acquired, nullptr);
    if (f.ready) vk->vkDestroySemaphore(s.device->device, f.ready, nullptr);
    if (f.pool) vk->vkDestroyCommandPool(s.device->device, f.pool, nullptr);
    f.source.reset();
    f.resourcesDestroyed = true;
}
constexpr uint32_t kCaptureSlots = 2;
// Caller holds s.operations, after the previous frame's copy has completed. Returns the
// image this present's copy also writes, or null to present without a capture.
VkImage reserveCapture(caboose_gpu_surface& s, const CaboosePresentationObjects& source, uint64_t serial) {
    {
        std::lock_guard<std::mutex> lock(s.mutex);
        if (!s.captureCallback || s.captureUnsupported || !s.device) return VK_NULL_HANDLE;
        if (s.capture && (s.capture->device != source.device || s.capture->format != source.format ||
                          s.capture->extent.width != source.extent.width ||
                          s.capture->extent.height != source.extent.height)) {
            // A resized or reformatted picture gets a new ring once no copy writes the old one.
            if (!s.captureState.idle()) return VK_NULL_HANDLE;
            destroyCaptureRing(*s.capture);
            s.capture.reset();
        }
    }
    if (!s.capture) {
        std::unique_ptr<PresentationCaptureRing> ring;
        VkResult r = createCaptureRing(source.vk, source.physicalDevice, source.device, source.format,
                                       source.extent, kCaptureSlots, &ring);
        std::lock_guard<std::mutex> lock(s.mutex);
        if (r != VK_SUCCESS) { s.captureUnsupported = true; return VK_NULL_HANDLE; }
        s.capture = std::move(ring);
        s.captureState.reset(kCaptureSlots);
    }
    std::lock_guard<std::mutex> lock(s.mutex);
    const int slot = s.captureState.reserve(serial);
    return slot < 0 ? VK_NULL_HANDLE : s.capture->images[static_cast<size_t>(slot)];
}
// The copy fence of `f` signaled: lend its capture to the compositor. Never under a lock.
void deliverCapture(caboose_gpu_surface& s, Frame& f) {
    if (!f.captured) return;
    f.captured = false;
    uint32_t token = 0;
    void* texture = nullptr;
    caboose_gpu_capture_callback callback = nullptr;
    void* context = nullptr;
    {
        std::lock_guard<std::mutex> lock(s.mutex);
        if (!s.captureState.complete(f.serial, &token) || !s.capture) return;
        texture = s.capture->textures[token & 0xff];
        callback = s.captureCallback; context = s.captureContext;
        if (!callback) { s.captureState.release(token); return; }
    }
    callback(context, f.serial, token, texture);
}
// The copy's outcome is unknown: its slot is never written again.
void quarantineCapture(caboose_gpu_surface& s, Frame& f) {
    if (!f.captured) return;
    f.captured = false;
    std::lock_guard<std::mutex> lock(s.mutex);
    s.captureState.quarantine(f.serial);
}
// Caller holds s.operations; every frame on the ring's device has retired.
void destroyCapture(caboose_gpu_surface& s) {
    std::lock_guard<std::mutex> lock(s.mutex);
    if (s.capture) destroyCaptureRing(*s.capture);
    s.capture.reset();
    s.captureState.reset(0);
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
#ifdef CABOOSE_GPU_INDEXED_WSI
        if (f.indexed) { std::lock_guard<std::mutex> lock(f.indexed->mutex); f.indexed->quarantined = true; }
#endif
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
            deliverCapture(s, f);
#ifdef CABOOSE_GPU_INDEXED_WSI
            if (f.indexed) {
                std::lock_guard<std::mutex> lock(f.indexed->mutex);
                if (!f.indexed->indices->markSourceReleased(f.serial)) f.indexed->quarantined = true;
            }
#endif
            if (f.callback) f.callback(f.context, f.serial, CABOOSE_GPU_SOURCE_RELEASED,
                                        driverResult(CABOOSE_GPU_SUBMIT_QUEUED, r));
        } else if (r == VK_ERROR_DEVICE_LOST) {
            f.deviceLost = true;
            quarantineCapture(s, f);
#ifdef CABOOSE_GPU_INDEXED_WSI
            if (f.indexed) { std::lock_guard<std::mutex> lock(f.indexed->mutex); f.indexed->quarantined = true; }
#endif
            if (f.callback) f.callback(f.context, f.serial, CABOOSE_GPU_DEVICE_LOST,
                                        driverResult(CABOOSE_GPU_SUBMIT_UNCERTAIN, r));
        } else {
            quarantineCapture(s, f);
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
        if (r == VK_SUCCESS) {
            f.presentRetired = true;
#ifdef CABOOSE_GPU_INDEXED_WSI
            if (f.indexed) {
                std::lock_guard<std::mutex> lock(f.indexed->mutex);
                if (!f.indexed->indices->markPresentRetired(f.serial)) f.indexed->quarantined = true;
            }
#endif
        }
        else if (r == VK_ERROR_DEVICE_LOST) {
            f.deviceLost = true;
#ifdef CABOOSE_GPU_INDEXED_WSI
            if (f.indexed) { std::lock_guard<std::mutex> lock(f.indexed->mutex); f.indexed->quarantined = true; }
#endif
            if (!f.reportedDeviceLoss && f.callback) {
                f.reportedDeviceLoss = true;
                f.callback(f.context, f.serial, CABOOSE_GPU_DEVICE_LOST,
                           driverResult(CABOOSE_GPU_SUBMIT_UNCERTAIN, r));
            }
        } else return errorFor(r);
    }
    return f.deviceLost || (f.sourceReleased && f.presentRetired) ? 0 : EBUSY;
}
#ifdef CABOOSE_GPU_INDEXED_WSI
// Called by the frame worker, or the serialized retirement worker, only after
// both real fences completed. No later callback may be issued for this serial.
int finishIndexedFrame(caboose_gpu_surface& surface, Frame& frame) {
    if (!frame.indexed || frame.deviceLost || !frame.sourceReleased || !frame.presentRetired)
        return EBUSY;
    destroyFrameResources(surface, frame);
    {
        std::lock_guard<std::mutex> lock(frame.indexed->mutex);
        if (!frame.indexed->indices->forgetRetired(frame.serial)) {
            frame.indexed->quarantined = true;
            return EBUSY;
        }
    }
    // Publish capacity before the final callback. A concurrent present joins
    // this worker before reusing the frame, so no callback can outlive it.
    {
        std::lock_guard<std::mutex> lock(surface.mutex);
        surface.frameDone = true;
    }
    if (frame.callback) frame.callback(frame.context, frame.serial, CABOOSE_GPU_PRESENT_RETIRED,
                                       driverResult(CABOOSE_GPU_SUBMIT_QUEUED, VK_SUCCESS));
    return 0;
}
#endif
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
            if (s->indexed || s->extent.enabled()) return rejected(EBUSY);
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
            VkImage capture = reserveCapture(*s, *frame->source, frame->serial);
            r = submitPresentationCopy(*frame->source, s->images[index], frame->acquired,
                                       frame->ready, frame->copyFence, frame->command, &provider, capture);
            frame->submitted = r == VK_SUCCESS;
            if (capture) {
                if (frame->submitted) frame->captured = true;
                else { std::lock_guard<std::mutex> lock(s->mutex); s->captureState.abort(frame->serial); }
            }
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
    {
        std::lock_guard<std::mutex> lock(s->mutex);
        s->captureCallback = nullptr; s->captureContext = nullptr;
    }
    destroyCapture(*s);
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

extern "C" int caboose_gpu_surface_set_capture(caboose_gpu_surface* s, caboose_gpu_capture_callback callback,
                                                void* context) {
    if (!s || (callback == nullptr) != (context == nullptr)) return EINVAL;
    std::lock_guard<std::mutex> lock(s->mutex);
    if (callback && (s->revoked || s->retired)) return EBUSY;
    if (callback && s->captureUnsupported) return ENOTSUP;
    s->captureCallback = callback;
    s->captureContext = context;
    return 0;
}

extern "C" int caboose_gpu_surface_release_capture(caboose_gpu_surface* s, uint32_t token) {
    if (!s) return EINVAL;
    std::lock_guard<std::mutex> lock(s->mutex);
    return s->captureState.release(token) ? 0 : ESTALE;
}

#ifdef CABOOSE_GPU_INDEXED_WSI
// This private path is off by default and requires explicit compile-only opt-in;
// it is not approved for runtime activation before review and provider tests.

extern "C" int caboose_gpu_surface_query_indexed(caboose_gpu_surface* surface, uint64_t physical,
    caboose_gpu_surface_capabilities** out, caboose_gpu_query_status* status) {
    if (!status) return EINVAL;
    *status = {};
    if (!out) { status->native_error = EINVAL; return EINVAL; }
    *out = nullptr;
    if (!indexedWsiRegistry()) { status->native_error = ENODEV; return ENODEV; }
    caboose_gpu_surface_capabilities* raw = nullptr;
    int result = caboose_gpu_surface_query(surface, physical, &raw, status);
    if (result) return result;
    std::unique_ptr<caboose_gpu_surface_capabilities> snapshot(raw);
    auto fail = [status](int error) {
        *status = {}; status->native_error = error; return error;
    };
    auto& view = snapshot->view;
    if (view.min_image_count > 256 || !view.max_image_array_layers ||
        !(view.supported_usage_flags & VK_IMAGE_USAGE_TRANSFER_DST_BIT) ||
        view.current_transform != VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR ||
        !(view.supported_transforms & VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR)) return fail(ENOTSUP);
    if (view.max_image_count == 0 || view.max_image_count > 256) view.max_image_count = 256;
    if (view.min_image_count > view.max_image_count) return fail(ENOTSUP);
    if (std::find(snapshot->modes.begin(), snapshot->modes.end(), VK_PRESENT_MODE_FIFO_KHR) == snapshot->modes.end())
        return fail(ENOTSUP);
    try {
        const uint32_t transfer = VK_FORMAT_FEATURE_TRANSFER_SRC_BIT | VK_FORMAT_FEATURE_TRANSFER_DST_BIT;
        std::vector<caboose_gpu_surface_format> accepted;
        for (const auto& f : snapshot->formats) {
            if (f.format == VK_FORMAT_UNDEFINED) {
                for (const auto& candidate : snapshot->candidates) {
                    if ((candidate.optimal_features & transfer) == transfer)
                        accepted.push_back({candidate.format, f.color_space, candidate.linear_features,
                            candidate.optimal_features, candidate.buffer_features, 1});
                }
            } else {
                auto candidate = std::find_if(snapshot->candidates.begin(), snapshot->candidates.end(),
                    [&](const caboose_gpu_candidate_format& item) { return item.format == f.format; });
                if (candidate != snapshot->candidates.end() && f.properties_queried &&
                    (f.optimal_features & transfer) == transfer) accepted.push_back(f);
            }
        }
        if (accepted.empty()) return fail(ENOTSUP);
        snapshot->formats = std::move(accepted);
        snapshot->modes.assign(1, VK_PRESENT_MODE_FIFO_KHR);
        view.max_image_array_layers = 1;
        view.supported_transforms = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
        view.format_count = static_cast<uint32_t>(snapshot->formats.size());
        view.present_mode_count = 1;
        view.formats = snapshot->formats.data(); view.present_modes = snapshot->modes.data();
        *out = snapshot.release();
        return 0;
    } catch (const std::bad_alloc&) { return fail(ENOMEM); }
}
extern "C" int caboose_gpu_surface_query_variable_extent(caboose_gpu_surface* surface,
    uint64_t physical, caboose_gpu_surface_capabilities** out, caboose_gpu_query_status* status) {
    if (!status) return EINVAL;
    *status = {};
    auto fail = [status](int error) { *status = {}; status->native_error = error; return error; };
    if (!out) return fail(EINVAL);
    *out = nullptr;
    if (!surface || [NSThread isMainThread]) return fail(EINVAL);
    caboose_gpu_surface_capabilities* raw = nullptr;
    int result = caboose_gpu_surface_query_indexed(surface, physical, &raw, status);
    if (result) return result;
    std::unique_ptr<caboose_gpu_surface_capabilities> snapshot(raw);
    std::lock_guard<std::mutex> operation(surface->operations);
    std::lock_guard<std::mutex> lock(surface->mutex);
    if (!surface->attached || surface->revoked || surface->retired || surface->swapchain ||
        surface->physicalBox != physical || surface->extent.quarantined()) return fail(EBUSY);
    auto& view = snapshot->view;
    const bool idle = !surface->indexed && !surface->frame && !surface->worker.joinable();
    if (!surface->extent.enabled() && !idle) return fail(EBUSY);
    // Live queries do not reset the configured extent or its admission state.
    // Refresh configuration limits only at the no-resource boundary.
    if (idle && !surface->extent.enable(view.min_width, view.min_height, view.max_width, view.max_height))
        return fail(ENOTSUP);
    view.current_width = UINT32_MAX;
    view.current_height = UINT32_MAX;
    *out = snapshot.release();
    return 0;
}

extern "C" int caboose_gpu_surface_configure_extent(caboose_gpu_surface* surface,
    const caboose_gpu_surface_identity* identity, CAMetalLayer* layer, uint32_t width, uint32_t height) {
    if (!surface || !identity || !layer || ![NSThread isMainThread] ||
        !same(surface->bind.identity, *identity)) return EINVAL;
    std::unique_lock<std::mutex> operation(surface->operations, std::try_to_lock);
    if (!operation.owns_lock()) return EBUSY;
    std::unique_lock<std::mutex> lock(surface->mutex, std::try_to_lock);
    if (!lock.owns_lock()) return EBUSY;
    if (!surface->attached || surface->revoked || surface->retired || !surface->physical ||
        surface->swapchain || surface->indexed || surface->frame || surface->worker.joinable()) return EBUSY;
    if (!metalSurfaceMatchesLayer(surface->metal, (__bridge void*)layer) ||
        !surface->extent.accepts(width, height)) return EINVAL;
    if (!surface->extent.begin(width, height)) return EINVAL;
    const int result = configureMetalSurfaceExtent(surface->metal, (__bridge void*)layer, width, height);
    surface->extent.complete(result == 0);
    // All validation above precedes mutation. Any subsequent failure is an
    // uncertain layer state, never a reusable EINVAL/EBUSY rejection.
    return result ? EIO : 0;
}

extern "C" int caboose_gpu_virtual_swapchain_create(caboose_gpu_surface* surface,
    const caboose_gpu_swapchain_create_info* info, caboose_gpu_virtual_swapchain** out,
    uint64_t* swapchainId, uint32_t* imageCount, caboose_gpu_query_status* status) {
    if (!status) return EINVAL;
    *status = {};
    auto fail = [status](int error) { status->native_error = error; return error; };
    if (!out || !swapchainId || !imageCount) return fail(EINVAL);
    *out = nullptr; *swapchainId = 0; *imageCount = 0;
    if (!surface || !info || !same(surface->bind.identity, info->identity) ||
        !info->boxed_device) return fail(EINVAL);
    std::lock_guard<std::mutex> operation(surface->operations);
    auto* registry = indexedWsiRegistry();
    if (!registry) return fail(ENODEV);
    try {
        {
            std::lock_guard<std::mutex> lock(surface->mutex);
            if (!surface->attached || surface->revoked || !surface->physical ||
                surface->swapchain || surface->indexed) return fail(EBUSY);
            if (surface->extent.enabled()) {
                if (!surface->extent.matches(info->width, info->height)) return fail(EINVAL);
            } else if (info->width != surface->bind.width || info->height != surface->bind.height) {
                return fail(EINVAL);
            }
        }
        if (!surface->nextSwapchainId) return fail(EOVERFLOW);
        auto result = std::make_unique<caboose_gpu_virtual_swapchain>();
        result->hostMutex = std::make_shared<std::mutex>();
        result->lifetime = std::make_shared<int>(0);
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
                                   &result->handle, &result->nativeImages, &provider,
                                   surface->extent.enabled());
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
    if (swapchain->surface->revoked || swapchain->sources || swapchain->retiring) return EBUSY;
    auto* registry = indexedWsiRegistry();
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
extern "C" caboose_gpu_submit_result caboose_gpu_virtual_swapchain_present(
    caboose_gpu_virtual_swapchain* swapchain, const caboose_gpu_mapped_present_info* info,
    caboose_gpu_present_callback callback, void* context) {
    if (!swapchain || !info || !callback || !same(swapchain->info.identity, info->identity) ||
        !info->present_serial || !info->boxed_queue || info->image_index >= swapchain->nativeImages.size() ||
        info->vk_image_layout != VK_IMAGE_LAYOUT_GENERAL ||
        info->wait_semaphore_count > CABOOSE_GPU_PRESENT_MAX_WAIT_SEMAPHORES ||
        (info->wait_semaphore_count && !info->boxed_wait_semaphores)) return rejected(EINVAL);
    auto* surface = swapchain->surface;
    std::lock_guard<std::mutex> surfaceOperation(surface->operations);
    auto* registry = indexedWsiRegistry();
    if (!registry) return rejected(ENODEV);
    bool reserved = false;
    auto abortReservation = [&] {
        if (!reserved) return;
        std::lock_guard<std::mutex> lock(swapchain->mutex);
        swapchain->indices->abortBeforeSubmit(info->present_serial);
        reserved = false;
    };
    try {
        {
            std::lock_guard<std::mutex> lock(surface->mutex);
            if (surface->revoked || surface->indexed != swapchain || info->present_serial <= surface->lastSerial ||
                (surface->frame && !surface->frameDone)) return rejected(EBUSY);
        }
        if (surface->worker.joinable()) surface->worker.join();
        if (surface->frame) {
            destroyFrameResources(*surface, *surface->frame);
            surface->frame.reset(); surface->frameDone = false;
        }
        {
            std::lock_guard<std::mutex> lock(swapchain->mutex);
            if (swapchain->retiring || swapchain->quarantined || !swapchain->sources ||
                (swapchain->hasQueueFamily && swapchain->queueFamily != info->queue_family) ||
                !swapchain->indices->beginPresent(info->image_index, info->present_serial)) return rejected(EBUSY);
            swapchain->hasQueueFamily = true;
            swapchain->queueFamily = info->queue_family;
            reserved = true;
        }
        surface->lastSerial = info->present_serial;
        caboose_gpu_present_info input{};
        input.identity = info->identity; input.present_serial = info->present_serial;
        input.boxed_device = swapchain->info.boxed_device; input.boxed_queue = info->boxed_queue;
        input.boxed_image = swapchain->boxedImages[info->image_index];
        input.vk_format = swapchain->info.vk_format; input.width = swapchain->info.width;
        input.height = swapchain->info.height; input.vk_image_layout = info->vk_image_layout;
        input.queue_family = info->queue_family; input.wait_semaphore_count = info->wait_semaphore_count;
        input.boxed_wait_semaphores = info->boxed_wait_semaphores;
        std::unique_ptr<CaboosePresentationObjects> source;
        VkResult r = acquirePresentationObjects(registry, surface->bind.boxed_instance, input, &source);
        if (r != VK_SUCCESS) { abortReservation(); return rejected(errorFor(r)); }
        if (surface->device && (surface->boxedDevice != input.boxed_device ||
            surface->boxedQueue != input.boxed_queue || surface->queueFamily != input.queue_family)) {
            destroyCapture(*surface);
            surface->device.reset(); // prior frame is fully retired above
        }
        if (!surface->device) {
            r = acquirePresentationDevice(registry, input.identity.process_token, surface->bind.boxed_instance,
                input.boxed_device, input.boxed_queue, input.queue_family, &surface->device);
            if (r != VK_SUCCESS) { abortReservation(); return rejected(errorFor(r)); }
            surface->boxedDevice = input.boxed_device; surface->boxedQueue = input.boxed_queue;
            surface->queueFamily = input.queue_family; surface->format = static_cast<VkFormat>(input.vk_format);
        }
        if (surface->device->device != swapchain->device->device || source->queue != surface->device->queue) {
            abortReservation(); return rejected(EINVAL);
        }
        PresentationProviderResult provider{};
        r = validateVirtualPresentQueue(*surface->device, metalSurfaceHandle(surface->metal), &provider);
        if (r != VK_SUCCESS) { abortReservation(); return operationResult(CABOOSE_GPU_SUBMIT_REJECTED, r, provider); }
        auto frame = std::make_unique<Frame>();
        frame->indexed = swapchain; frame->source = std::move(source); frame->serial = info->present_serial;
        frame->callback = callback; frame->context = context;
        r = allocateFrame(*surface, *frame, &provider);
        if (r != VK_SUCCESS) { destroyFrameResources(*surface, *frame); abortReservation();
            return operationResult(CABOOSE_GPU_SUBMIT_REJECTED, r, provider); }
        // Real acquire fence was observed before sourceReusable admitted this index.
        VkImage capture = reserveCapture(*surface, *frame->source, frame->serial);
        r = submitPresentationCopy(*frame->source, swapchain->nativeImages[info->image_index], VK_NULL_HANDLE,
                                   frame->ready, frame->copyFence, frame->command, &provider, capture);
        frame->submitted = r == VK_SUCCESS;
        if (capture) {
            if (frame->submitted) frame->captured = true;
            else { std::lock_guard<std::mutex> lock(surface->mutex); surface->captureState.abort(frame->serial); }
        }
        {
            std::lock_guard<std::mutex> lock(swapchain->mutex);
            if (frame->submitted) swapchain->indices->markCopySubmitted(frame->serial);
            else { swapchain->indices->quarantine(info->image_index); swapchain->quarantined = true; }
        }
        reserved = false; // after a submit attempt, never roll back ownership
        if (frame->submitted) {
            std::lock_guard<std::mutex> lock(swapchain->mutex);
            {
                std::lock_guard<std::mutex> hostLock(*swapchain->hostMutex);
                r = queuePresentation(*frame->source, swapchain->handle, info->image_index,
                                      frame->ready, frame->presentFence, &provider);
            }
            frame->presentQueued = r == VK_SUCCESS || r == VK_SUBOPTIMAL_KHR;
            if (!frame->presentQueued || !swapchain->indices->markPresented(frame->serial)) {
                swapchain->indices->quarantine(info->image_index); swapchain->quarantined = true;
            }
        }
        frame->deviceLost = provider.present && provider.value == VK_ERROR_DEVICE_LOST;
        bool accepted = false;
        {
            std::lock_guard<std::mutex> lock(swapchain->mutex);
            accepted = frame->submitted && frame->presentQueued && !swapchain->quarantined;
        }
        surface->frame = std::move(frame);
        try {
            surface->worker = std::thread([surface] {
                int result = advanceFrame(*surface, *surface->frame);
                if (!result) result = finishIndexedFrame(*surface, *surface->frame);
                std::lock_guard<std::mutex> lock(surface->mutex);
                surface->frameDone = result == 0;
            });
        } catch (const std::system_error&) {
            return {CABOOSE_GPU_SUBMIT_UNCERTAIN, EAGAIN, provider.present ? 1u : 0u,
                    provider.present ? static_cast<int32_t>(provider.value) : 0};
        }
        return operationResult(accepted ? CABOOSE_GPU_SUBMIT_QUEUED : CABOOSE_GPU_SUBMIT_UNCERTAIN, r, provider);
    } catch (const std::bad_alloc&) { abortReservation(); return rejected(ENOMEM); }
}
struct caboose_gpu_acquire_request {
    caboose_gpu_virtual_swapchain* swapchain = nullptr;
    std::unique_ptr<PresentationAcquire> operation;
    std::mutex mutex;
    bool acquired = false, observed = false, cancelled = false, terminal = false;
    caboose_gpu_acquire_result saved{};
};
extern "C" int caboose_gpu_acquire_begin(caboose_gpu_virtual_swapchain* swapchain,
    const caboose_gpu_acquire_info* info, caboose_gpu_acquire_request** out,
    caboose_gpu_query_status* status) {
    if (!status) return EINVAL;
    *status = {};
    auto fail = [status](int error) { status->native_error = error; return error; };
    if (!out) return fail(EINVAL);
    *out = nullptr;
    if (!swapchain || !info || info->device_mask != 1 || (!info->boxed_binary_semaphore && !info->boxed_fence))
        return fail(EINVAL);
    std::lock_guard<std::mutex> surfaceOperation(swapchain->surface->operations);
    std::lock_guard<std::mutex> lock(swapchain->mutex);
    if (swapchain->surface->revoked || !swapchain->sources || swapchain->quarantined ||
        swapchain->retiring || swapchain->acquireBusy || swapchain->requests >= 256)
        return fail(EBUSY);
    auto* registry = indexedWsiRegistry();
    if (!registry) return fail(ENODEV);
    try {
        auto request = std::make_unique<caboose_gpu_acquire_request>();
        std::unique_ptr<gfxstream::host::vk::CabooseAcquireSync> sync;
        const auto& create = swapchain->info;
        VkResult r = acquirePresentationSync(registry, create.identity.process_token,
            swapchain->surface->bind.boxed_instance, create.boxed_device,
            info->boxed_binary_semaphore, info->boxed_fence, &sync);
        if (r != VK_SUCCESS) return fail(errorFor(r));
        PresentationProviderResult provider{};
        r = PresentationAcquire::create(std::move(sync), swapchain->handle, swapchain->lifetime,
                                         swapchain->hostMutex, &request->operation, &provider);
        if (r != VK_SUCCESS) {
            if (provider.present) {
                status->has_vulkan_result = 1; status->vulkan_result = provider.value;
                return errorFor(r); // API failure; raw provider status has errno zero
            }
            return fail(errorFor(r));
        }
        request->swapchain = swapchain;
        ++swapchain->requests;
        swapchain->acquireBusy = true;
        *out = request.release();
        return 0;
    } catch (const std::bad_alloc&) { return fail(ENOMEM); }
}
extern "C" caboose_gpu_acquire_result caboose_gpu_acquire_poll(caboose_gpu_acquire_request* request) {
    if (!request) return {EINVAL, 0, 0, 0, 0, 3};
    std::lock_guard<std::mutex> requestLock(request->mutex);
    if (request->acquired || request->terminal) return request->saved;
    if (request->cancelled) return {ECANCELED, 0, 0, 0, 0, 2};
    auto* swapchain = request->swapchain;
    std::lock_guard<std::mutex> lock(swapchain->mutex);
    bool revoked = false;
    {
        std::lock_guard<std::mutex> surfaceLock(swapchain->surface->mutex);
        revoked = swapchain->surface->revoked || swapchain->retiring;
    }
    if (revoked) {
        request->operation->cancel(); request->cancelled = true;
        swapchain->acquireBusy = false;
        return {ECANCELED, 0, 0, 0, 0, 2};
    }
    {
        auto result = request->operation->poll(); // real timeout-zero provider call
        caboose_gpu_acquire_result value{};
        if (result.fromProvider) {
            value.has_vulkan_result = 1; value.vulkan_result = result.value;
        } else { value.native_error = EIO; value.local_reason = 3; }
        if (result.hasIndex) {
            value.has_image_index = 1; value.image_index = result.index;
            request->acquired = true;
            swapchain->acquireBusy = false;
            if (!swapchain->indices->markAcquired(result.index)) {
                swapchain->indices->quarantine(result.index);
                swapchain->quarantined = true;
                value.native_error = EPROTO;
            }
            request->saved = value;
        } else if (!result.fromProvider || (result.value != VK_NOT_READY && result.value != VK_TIMEOUT)) {
            request->terminal = true; request->saved = value;
            swapchain->acquireBusy = false;
        }
        return value;
    }
}
extern "C" int caboose_gpu_acquire_cancel(caboose_gpu_acquire_request* request) {
    if (!request) return EINVAL;
    std::lock_guard<std::mutex> lock(request->mutex);
    if (request->acquired) return EALREADY;
    if (request->terminal) return EIO;
    if (!request->operation->cancel()) return EALREADY;
    request->cancelled = true;
    std::lock_guard<std::mutex> swapchainLock(request->swapchain->mutex);
    request->swapchain->acquireBusy = false;
    return 0;
}
extern "C" caboose_gpu_query_status caboose_gpu_acquire_observe(caboose_gpu_acquire_request* request) {
    if (!request) return {EINVAL, 0, 0};
    std::lock_guard<std::mutex> lock(request->mutex);
    if (!request->acquired) return {EINVAL, 0, 0};
    auto result = request->operation->signalComplete();
    if (!result.fromProvider) return {EIO, 0, 0};
    if (!request->observed && (result.value == VK_SUCCESS || result.value == VK_ERROR_DEVICE_LOST)) {
        std::lock_guard<std::mutex> swapchainLock(request->swapchain->mutex);
        if (result.value == VK_SUCCESS) {
            if (!request->swapchain->indices->markAcquireReady(request->saved.image_index))
                request->swapchain->quarantined = true;
        } else {
            request->swapchain->indices->quarantine(request->saved.image_index);
            request->swapchain->quarantined = true;
        }
        request->observed = true;
    }
    return {result.value < 0 ? errorFor(result.value) : 0, 1, result.value};
}
extern "C" int caboose_gpu_acquire_request_release(caboose_gpu_acquire_request** ptr) {
    if (!ptr || !*ptr) return EINVAL;
    auto* request = *ptr;
    std::unique_lock<std::mutex> requestLock(request->mutex);
    if (request->acquired && !request->observed) return EBUSY;
    if (!request->acquired && !request->cancelled && !request->terminal) return EBUSY;
    auto* swapchain = request->swapchain;
    {
        std::lock_guard<std::mutex> lock(swapchain->mutex);
        if (!swapchain->requests) return EINVAL;
        --swapchain->requests;
    }
    *ptr = nullptr;
    requestLock.unlock();
    delete request;
    return 0;
}
extern "C" int caboose_gpu_virtual_swapchain_retire(caboose_gpu_virtual_swapchain** ptr,
    caboose_gpu_query_status* status) {
    if (!status) return EINVAL;
    *status = {};
    auto fail = [status](int error) { status->native_error = error; return error; };
    if (!ptr || !*ptr || [NSThread isMainThread]) return fail(EINVAL);
    auto* swapchain = *ptr;
    auto* surface = swapchain->surface;
    std::unique_lock<std::mutex> surfaceOperation(surface->operations);
    {
        std::lock_guard<std::mutex> lock(swapchain->mutex);
        swapchain->retiring = true;
    }
    if (surface->frame && surface->frame->indexed == swapchain) {
        if (surface->worker.joinable()) {
            if (surface->worker.get_id() == std::this_thread::get_id()) return fail(EDEADLK);
            surface->worker.join();
        }
        if (!surface->frameDone) {
            int result = advanceFrame(*surface, *surface->frame);
            if (!result) result = finishIndexedFrame(*surface, *surface->frame);
            if (result) return fail(result);
        }
        destroyFrameResources(*surface, *surface->frame);
        surface->frame.reset(); surface->frameDone = false;
    }
    surface->device.reset();
    std::unique_lock<std::mutex> lock(swapchain->mutex);
    if (swapchain->requests || swapchain->quarantined) return fail(EBUSY);
    std::vector<uint32_t> acquired;
    try {
        if (!swapchain->indices->acquiredUnused(&acquired)) return fail(EBUSY);
    } catch (const std::bad_alloc&) { return fail(ENOMEM); }
    std::shared_ptr<GuestGpuCompletion> completion;
    GuestGpuCompletion::ReleaseGuard proof;
    if (!acquired.empty()) {
        // Coverage stays disabled until every submission path and cross-stream
        // admission are proven. The guard excludes admissions through release.
        completion = swapchain->device->guestCompletion;
        if (!completion) return fail(EBUSY);
        proof = completion->tryRelease();
        if (!proof.valid() && swapchain->device && swapchain->device->vk &&
            swapchain->device->vk->vkDeviceWaitIdle) {
            auto before = completion->beforeDeviceIdle();
            VkResult idleResult;
            {
                std::lock_guard<std::mutex> hostLock(*swapchain->hostMutex);
                idleResult = swapchain->device->vk->vkDeviceWaitIdle(swapchain->device->device);
            }
            completion->afterIdle(before, idleResult == VK_SUCCESS);
            proof = completion->tryRelease();
        }
        if (!proof.valid()) return fail(EBUSY);
        PresentationProviderResult provider{};
        VkResult result;
        {
            std::lock_guard<std::mutex> hostLock(*swapchain->hostMutex);
            result = releaseUnusedVirtualImages(*swapchain->device, swapchain->handle,
                static_cast<uint32_t>(swapchain->nativeImages.size()),
                static_cast<uint32_t>(acquired.size()), acquired.data(), &provider);
        }
        if (result != VK_SUCCESS) {
            if (provider.present) { status->has_vulkan_result = 1; status->vulkan_result = provider.value; }
            return fail(errorFor(result));
        }
        for (uint32_t index : acquired) {
            if (!swapchain->indices->markUnusedReleased(index)) {
                swapchain->quarantined = true;
                return fail(EIO);
            }
        }
    }
    if (!swapchain->indices->mayRetire()) return fail(EBUSY);
    if (surface->indexed != swapchain || !swapchain->device || !swapchain->device->vk ||
        !swapchain->device->vk->vkDestroySwapchainKHR) return fail(EIO);
    {
        std::lock_guard<std::mutex> hostLock(*swapchain->hostMutex);
        swapchain->device->vk->vkDestroySwapchainKHR(swapchain->device->device, swapchain->handle, nullptr);
    }
    surface->indexed = nullptr;
    *ptr = nullptr;
    lock.unlock();
    delete swapchain;
    return 0;
}
#endif
