// SPDX-License-Identifier: MIT
// Included by gfxstream_vk_device.cpp only in the separately prepared private tree.
#if defined(CABOOSE_GFXSTREAM_PRIVATE_LIVE) && !defined(GFXSTREAM_VK_WAYLAND)
#error Private live surface queries require a native Wayland Mesa build
#endif
#if defined(CABOOSE_GFXSTREAM_PRIVATE_LIVE) && defined(GFXSTREAM_VK_WAYLAND)
#ifndef CABOOSE_GFXSTREAM_PRIVATE_ICD
#error Private surface queries require the private ICD and v3 handshake
#endif
#include "caboose-wsi/client.h"
#include <wayland-client-core.h>
#include <map>
#include <memory>
#include <mutex>
#include <system_error>
#include "goldfish_vk_private_defs.h"
#if defined(CABOOSE_GFXSTREAM_PRIVATE_INDEXED_WSI)
#include "SocketStream.h"
#endif

namespace caboose_surface {
using namespace caboose::wsi;
static bool active() { return std::getenv("CABOOSE_GFXSTREAM_SOCKET") != nullptr; }
static bool profileReady() {
#if defined(CABOOSE_GFXSTREAM_PRIVATE_INDEXED_WSI)
    if (!active()) return true;
    auto* tracker=gfxstream::vk::ResourceTracker::get();
    return tracker->cabooseSynchronousProfile() && !tracker->usingDirectMapping() &&
        tracker->getStreamFeatures()==VULKAN_STREAM_FEATURE_NULL_OPTIONAL_STRINGS_BIT;
#else
    return true;
#endif
}
static bool indexed() {
#if defined(CABOOSE_GFXSTREAM_PRIVATE_INDEXED_WSI)
    if (!active()) return false;
    auto* manager=getConnectionManager();
    auto* stream=manager ? dynamic_cast<CabooseSocketStream*>(manager->getStream()) : nullptr;
    return stream && stream->indexedHandshakeReady() && profileReady();
#else
    return false;
#endif
}
struct Surface {
    std::recursive_mutex operationMutex;
    VkInstance instance;
    uint64_t boxedInstance;
    uint32_t object;
    VkAllocationCallbacks allocator{};
    bool customAllocator=false, attempted=false, bound=false, poisoned=false;
    uint64_t query=0, presentSerial=0;
    Client client;
};
static std::mutex mutex;
static std::map<VkSurfaceKHR,std::shared_ptr<Surface>> surfaces;
static std::shared_ptr<Surface> lookup(VkSurfaceKHR handle) {
    std::lock_guard<std::mutex> lock(mutex);
    auto found=surfaces.find(handle);
    return found==surfaces.end() ? nullptr : found->second;
}
static Client::Deadline deadline() { return std::chrono::steady_clock::now()+std::chrono::seconds(10); }
// Native errno is not a fictional provider VkResult. This is the local WSI API's
// surface-loss result; the control client retains the original native status.
static VkResult apiStatus(Status s) {
    if (s.nativeError) return VK_ERROR_SURFACE_LOST_KHR;
    return s.hasVk ? VkResult(s.vk) : VK_SUCCESS;
}
template<class F> static VkResult guarded(F f) {
    try { return f(); }
    catch (const std::bad_alloc&) { return VK_ERROR_OUT_OF_HOST_MEMORY; }
    catch (const std::exception&) { return VK_ERROR_SURFACE_LOST_KHR; }
}
static VkResult query(VkPhysicalDevice physical, VkSurfaceKHR handle, Bytes& caps) {
    auto retained=lookup(handle);
    if (!retained) return VK_ERROR_SURFACE_LOST_KHR;
    auto& surface=*retained;
    std::lock_guard<std::recursive_mutex> lock(surface.operationMutex);
    VK_FROM_HANDLE(gfxstream_vk_physical_device, device, physical);
    if (surface.instance!=gfxstream_vk_instance_to_handle(device->instance) || surface.poisoned)
        return VK_ERROR_SURFACE_LOST_KHR;
    try {
        if (!surface.bound) {
            if (surface.attempted) return VK_ERROR_SURFACE_LOST_KHR;
            surface.attempted=true; // no retry after an uncertain sent bind
            surface.client.connect(std::getenv("CABOOSE_GFXSTREAM_SURFACE_SOCKET"),deadline());
            auto reply=surface.client.bind(surface.boxedInstance,surface.object,0,0,deadline());
            auto result=apiStatus(status(reply.body,48));
            if (result!=VK_SUCCESS) { surface.poisoned=true; return result; }
            surface.bound=true;
        }
        if (surface.query==UINT64_MAX) throw ProtocolError("query ID exhausted");
        auto reply=surface.client.query(++surface.query,
            uint64_t(reinterpret_cast<uintptr_t>(device->internal_object)),deadline());
        auto result=apiStatus(status(reply.body,48));
        if (result==VK_SUCCESS) caps=std::move(reply.body);
        return result;
    } catch (...) { surface.poisoned=true; throw; }
}
static VkResult VKAPI_CALL create(VkInstance instance, const VkWaylandSurfaceCreateInfoKHR* info,
    const VkAllocationCallbacks* allocator, VkSurfaceKHR* out) {
    return guarded([&]() -> VkResult {
        if (!info || !out || !info->display || !info->surface || info->flags || info->pNext ||
            info->sType!=VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR)
            return VK_ERROR_INITIALIZATION_FAILED;
        auto* proxy=reinterpret_cast<wl_proxy*>(info->surface);
        if (strcmp(wl_proxy_get_class(proxy),"wl_surface") || !wl_proxy_get_id(proxy))
            return VK_ERROR_INITIALIZATION_FAILED;
        std::lock_guard<std::mutex> lock(mutex);
        if (surfaces.size()>=64) return VK_ERROR_OUT_OF_HOST_MEMORY;
        auto surface=std::make_shared<Surface>();
        surface->instance=instance;
        VK_FROM_HANDLE(gfxstream_vk_instance, owner, instance);
        surface->boxedInstance=uint64_t(reinterpret_cast<uintptr_t>(owner->internal_object));
        surface->object=wl_proxy_get_id(proxy);
        if (allocator) { surface->allocator=*allocator; surface->customAllocator=true; }
        // The private WSI never creates a Linux presentation buffer. Keep the
        // standard ICD Wayland identity without depending on a common-Wayland build.
        auto* wrapper=static_cast<VkIcdSurfaceWayland*>(vk_zalloc2(&owner->vk.alloc,allocator,
            sizeof(VkIcdSurfaceWayland),8,VK_SYSTEM_ALLOCATION_SCOPE_OBJECT));
        if (!wrapper) return VK_ERROR_OUT_OF_HOST_MEMORY;
        wrapper->base.platform=VK_ICD_WSI_PLATFORM_WAYLAND;
        wrapper->display=info->display; wrapper->surface=info->surface;
        auto handle=reinterpret_cast<VkSurfaceKHR>(wrapper);
        try { surfaces.emplace(handle,std::move(surface)); }
        catch (...) { vk_free2(&owner->vk.alloc,allocator,wrapper); throw; }
        *out=handle;
        return VK_SUCCESS;
    });
}
static bool retire(Surface& surface) {
    if (!surface.attempted) return true;
    if (!surface.bound) return false; // uncertain bind still retains the instance
    if (surface.client.retired()) return true;
    try { return apiStatus(status(surface.client.retire(deadline()).body,40))==VK_SUCCESS; }
    catch (...) { surface.poisoned=true; return false; }
}
static void VKAPI_CALL destroy(VkInstance instance, VkSurfaceKHR handle, const VkAllocationCallbacks*) {
    try {
    if (handle==VK_NULL_HANDLE) return;
    auto retained=lookup(handle);
    if (!retained || retained->instance!=instance) return;
    auto& surface=*retained;
    std::lock_guard<std::recursive_mutex> lock(surface.operationMutex);
    if (!retire(surface)) return;
    VK_FROM_HANDLE(gfxstream_vk_instance, owner, instance);
    vk_free2(&owner->vk.alloc,surface.customAllocator ? &surface.allocator : nullptr,
        reinterpret_cast<void*>(handle));
    std::lock_guard<std::mutex> registryLock(mutex);
    surfaces.erase(handle);
    } catch (...) { /* A void destroy never turns an uncertain lease into a release. */ }
}
static bool beforeDestroyInstance(VkInstance instance) {
    try {
    if (!active()) return true;
    std::vector<std::pair<VkSurfaceKHR,std::shared_ptr<Surface>>> retained;
    {
        std::lock_guard<std::mutex> lock(mutex);
        for (auto& item:surfaces) if (item.second->instance==instance) retained.push_back(item);
    }
    // First obtain every retirement proof. Do not partially destroy the instance.
    for (auto& item:retained) {
        std::lock_guard<std::recursive_mutex> lock(item.second->operationMutex);
        if (!retire(*item.second)) return false;
    }
    for (auto& item:retained) destroy(instance,item.first,nullptr);
    return true;
    } catch (...) { return false; }
}
static VkResult VKAPI_CALL capabilities(VkPhysicalDevice physical, VkSurfaceKHR surface, VkSurfaceCapabilitiesKHR* out) {
    return guarded([&]() -> VkResult {
        if (!out) return VK_ERROR_INITIALIZATION_FAILED;
        Bytes b; auto result=query(physical,surface,b); if (result!=VK_SUCCESS) return result;
        const auto values=providerCaps(b).values;
        VkSurfaceCapabilitiesKHR c{};
        c.minImageCount=values[0]; c.maxImageCount=values[1];
        c.currentExtent={values[2],values[3]};
        c.minImageExtent={values[4],values[5]}; c.maxImageExtent={values[6],values[7]};
        c.maxImageArrayLayers=values[8]; c.supportedTransforms=values[9];
        c.currentTransform=VkSurfaceTransformFlagBitsKHR(values[10]);
        c.supportedCompositeAlpha=values[11]; c.supportedUsageFlags=values[12];
        *out=c; return VK_SUCCESS;
    });
}
static VkResult VKAPI_CALL formats(VkPhysicalDevice physical, VkSurfaceKHR surface,
    uint32_t* count, VkSurfaceFormatKHR* out) {
    return guarded([&]() -> VkResult {
        if (!count) return VK_ERROR_INITIALIZATION_FAILED;
        Bytes b; auto result=query(physical,surface,b); if (result!=VK_SUCCESS) return result;
        const auto values=providerCaps(b).formats;
        uint32_t total=values.size(), copied=out ? std::min(*count,total) : total;
        if (out) for (uint32_t i=0;i<copied;++i)
            out[i]={VkFormat(values[i][0]),VkColorSpaceKHR(values[i][1])};
        *count=copied; return copied<total ? VK_INCOMPLETE : VK_SUCCESS;
    });
}
static VkResult VKAPI_CALL modes(VkPhysicalDevice physical, VkSurfaceKHR surface,
    uint32_t* count, VkPresentModeKHR* out) {
    return guarded([&]() -> VkResult {
        if (!count) return VK_ERROR_INITIALIZATION_FAILED;
        Bytes b; auto result=query(physical,surface,b); if (result!=VK_SUCCESS) return result;
        const auto values=providerCaps(b).modes;
        uint32_t total=values.size(), copied=out ? std::min(*count,total) : total;
        if (out) for (uint32_t i=0;i<copied;++i) out[i]=VkPresentModeKHR(values[i]);
        *count=copied; return copied<total ? VK_INCOMPLETE : VK_SUCCESS;
    });
}
static VkResult VKAPI_CALL support(VkPhysicalDevice physical, uint32_t family, VkSurfaceKHR surface, VkBool32* out) {
    return guarded([&]() -> VkResult {
        if (!out) return VK_ERROR_INITIALIZATION_FAILED;
        Bytes b; auto result=query(physical,surface,b); if (result!=VK_SUCCESS) return result;
        bool found=false;
        for (const auto& queue:providerCaps(b).queues) if (queue[0]==family) found=true;
        if (!found) return VK_ERROR_INITIALIZATION_FAILED;
        uint32_t chosen=UINT32_MAX;
        for (const auto& queue:providerCaps(b).queues)
            if (queue[3] && (queue[1]&VK_QUEUE_GRAPHICS_BIT)) chosen=std::min(chosen,queue[0]);
        *out=indexed() && family==chosen ? VK_TRUE : VK_FALSE; return VK_SUCCESS;
    });
}
static VkBool32 VKAPI_CALL waylandSupport(VkPhysicalDevice, uint32_t, wl_display*) { return VK_FALSE; }
static VkResult VKAPI_CALL presentRectangles(VkPhysicalDevice, VkSurfaceKHR, uint32_t*, VkRect2D*) {
    return VK_ERROR_FEATURE_NOT_PRESENT;
}
static void maskHostImageCopy(void* chain) {
    for (auto* item=static_cast<VkBaseOutStructure*>(chain);item;item=item->pNext) {
        if (item->sType==VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_HOST_IMAGE_COPY_FEATURES_EXT)
            reinterpret_cast<VkPhysicalDeviceHostImageCopyFeaturesEXT*>(item)->hostImageCopy=VK_FALSE;
        if (item->sType==VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_4_FEATURES)
            reinterpret_cast<VkPhysicalDeviceVulkan14Features*>(item)->hostImageCopy=VK_FALSE;
    }
}
static void VKAPI_CALL features2(VkPhysicalDevice physical, VkPhysicalDeviceFeatures2* features) {
    gfxstream_vk_physical_device_entrypoints.GetPhysicalDeviceFeatures2(physical,features);
    if (indexed() && features) maskHostImageCopy(features->pNext);
}
static void VKAPI_CALL features2KHR(VkPhysicalDevice physical, VkPhysicalDeviceFeatures2* features) {
    gfxstream_vk_physical_device_entrypoints.GetPhysicalDeviceFeatures2KHR(physical,features);
    if (indexed() && features) maskHostImageCopy(features->pNext);
}
static VkResult validateDeviceCreate(const VkDeviceCreateInfo* info) {
    if (!indexed()) return VK_SUCCESS;
    for (auto* item=static_cast<const VkBaseInStructure*>(info->pNext);item;item=item->pNext) {
        if (item->sType==VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_HOST_IMAGE_COPY_FEATURES_EXT &&
            reinterpret_cast<const VkPhysicalDeviceHostImageCopyFeaturesEXT*>(item)->hostImageCopy)
            return VK_ERROR_FEATURE_NOT_PRESENT;
        if (item->sType==VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_4_FEATURES &&
            reinterpret_cast<const VkPhysicalDeviceVulkan14Features*>(item)->hostImageCopy)
            return VK_ERROR_FEATURE_NOT_PRESENT;
    }
    for (uint32_t i=0;i<info->enabledExtensionCount;++i)
        if (strstr(info->ppEnabledExtensionNames[i],"host_image_copy")) return VK_ERROR_EXTENSION_NOT_PRESENT;
    return VK_SUCCESS;
}
static VkResult VKAPI_CALL capabilities2(VkPhysicalDevice physical,
    const VkPhysicalDeviceSurfaceInfo2KHR* info, VkSurfaceCapabilities2KHR* out) {
    if (!info || !out || info->pNext || out->pNext ||
        info->sType!=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SURFACE_INFO_2_KHR ||
        out->sType!=VK_STRUCTURE_TYPE_SURFACE_CAPABILITIES_2_KHR) return VK_ERROR_EXTENSION_NOT_PRESENT;
    return capabilities(physical,info->surface,&out->surfaceCapabilities);
}
static VkResult VKAPI_CALL formats2(VkPhysicalDevice physical,
    const VkPhysicalDeviceSurfaceInfo2KHR* info, uint32_t* count, VkSurfaceFormat2KHR* out) {
    return guarded([&]() -> VkResult {
        if (!info || !count || info->pNext || info->sType!=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SURFACE_INFO_2_KHR)
            return VK_ERROR_EXTENSION_NOT_PRESENT;
        if (!out) return formats(physical,info->surface,count,nullptr);
        // A caller's capacity does not authorize an unbounded allocation.
        uint32_t copied=std::min(*count,uint32_t(4096));
        for (uint32_t i=0;i<copied;++i)
            if (out[i].pNext || out[i].sType!=VK_STRUCTURE_TYPE_SURFACE_FORMAT_2_KHR)
                return VK_ERROR_EXTENSION_NOT_PRESENT;
        std::vector<VkSurfaceFormatKHR> values(copied);
        // vector::data may be null for zero capacity; retain enumeration semantics.
        VkSurfaceFormatKHR dummy{};
        auto result=formats(physical,info->surface,&copied,values.empty()?&dummy:values.data());
        if (result==VK_SUCCESS || result==VK_INCOMPLETE) {
            for (uint32_t i=0;i<copied;++i) out[i].surfaceFormat=values[i];
            *count=copied;
        }
        return result;
    });
}
static void install(vk_instance_dispatch_table& table) {
    if (!active()) return;
    table.CreateWaylandSurfaceKHR=create; table.DestroySurfaceKHR=destroy;
}
static void install(vk_physical_device_dispatch_table& table) {
    if (!active()) return;
    table.GetPhysicalDeviceSurfaceSupportKHR=support;
    table.GetPhysicalDeviceWaylandPresentationSupportKHR=waylandSupport;
    table.GetPhysicalDeviceSurfaceCapabilitiesKHR=capabilities;
    table.GetPhysicalDeviceSurfaceFormatsKHR=formats;
    table.GetPhysicalDeviceSurfacePresentModesKHR=modes;
    table.GetPhysicalDeviceSurfaceCapabilities2KHR=capabilities2;
    table.GetPhysicalDeviceSurfaceFormats2KHR=formats2;
    table.GetPhysicalDevicePresentRectanglesKHR=presentRectangles;
    if (indexed()) {
        table.GetPhysicalDeviceFeatures2=features2;
        table.GetPhysicalDeviceFeatures2KHR=features2KHR;
    }
}
static void gate(vk_device_extension_table& extensions) {
    if (!active()) return;
    for (uint32_t i=0;i<VK_DEVICE_EXTENSION_COUNT;++i) {
        const char* name=vk_device_extensions[i].extensionName;
        if (!strcmp(name,"VK_KHR_swapchain") && indexed()) continue;
        if (strstr(name,"swapchain") || strstr(name,"present") || strstr(name,"display") ||
            !strcmp(name,"VK_KHR_device_group") || (indexed() && strstr(name,"host_image_copy")) ||
            !strcmp(name,"VK_EXT_hdr_metadata") || !strcmp(name,"VK_GOOGLE_display_timing") ||
            !strcmp(name,"VK_EXT_full_screen_exclusive") || !strcmp(name,"VK_AMD_display_native_hdr"))
            extensions.extensions[i]=false;
    }
}
static void gate(vk_instance_extension_table& extensions) {
    if (!active()) return;
    for (uint32_t i=0;i<VK_INSTANCE_EXTENSION_COUNT;++i) {
        const char* name=vk_instance_extensions[i].extensionName;
        if ((strstr(name,"surface") || strstr(name,"display")) &&
            strcmp(name,"VK_KHR_surface") && strcmp(name,"VK_KHR_wayland_surface") &&
            strcmp(name,"VK_KHR_get_surface_capabilities2")) extensions.extensions[i]=false;
    }
}
#include "mesa_swapchain.inc"
}
#else
namespace caboose_surface {
template<class T> static void install(T&) {}
template<class T> static void gate(T&) {}
static bool beforeDestroyInstance(VkInstance) { return true; }
static bool beforeDestroyDevice(VkDevice) { return true; }
static bool profileReady() { return true; }
static VkResult validateDeviceCreate(const VkDeviceCreateInfo*) { return VK_SUCCESS; }
}
#endif
