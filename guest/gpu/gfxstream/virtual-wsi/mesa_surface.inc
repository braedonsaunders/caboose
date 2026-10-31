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
#include <wayland-client-protocol.h>
#include <map>
#include <dlfcn.h>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <system_error>
#include "goldfish_vk_private_defs.h"
#include "Resources.h"
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
    Client::Space space=Client::WaylandSurface;
    VkAllocationCallbacks allocator{};
    bool customAllocator=false, attempted=false, bound=false, poisoned=false;
    uint64_t query=0, presentSerial=0;
    // A refused bind (the window does not exist yet) is tried again from this time on;
    // a bind the phone answered with a failure, not before `nextPhoneBind`.
    std::chrono::steady_clock::time_point nextBind{}, nextPhoneBind{};
    uint32_t bindAttempts=0, phoneFailures=0;
    // The provider's last capability reply, for the physical device it answered.
    Bytes caps;
    uint64_t capsPhysical=0;
    std::chrono::steady_clock::time_point capsTime{};
    Client client;
};
static std::mutex mutex;
static std::map<VkSurfaceKHR,std::shared_ptr<Surface>> surfaces;
static std::shared_ptr<Surface> lookup(VkSurfaceKHR handle) {
    std::lock_guard<std::mutex> lock(mutex);
    auto found=surfaces.find(handle);
    return found==surfaces.end() ? nullptr : found->second;
}
static const bool peerGoneHook=[] { Client::peerGone=caboose::completion::executorEndedIfGone; return true; }();
extern "C" int caboose_gfxstream_guest_images;
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
// Toolkits create a surface, query it and even create a swapchain before its window
// exists: GTK does so for a wl_surface that has no xdg_toplevel yet, and X11 toolkits for
// windows not yet mapped. The compositor grants a bind only for an existing window, and
// the broker closes the connection of a bind it refused, so a refused bind is tried again
// later on a new connection. Until a bind succeeds, queries are answered locally.
constexpr auto kBindRetry=std::chrono::milliseconds(100);
// Toolkits ask for capabilities every frame (Zink's Kopper does), so the provider's last
// reply answers at once; once it is this old, a refresh is sent and its reply used when
// it arrives.
constexpr auto kCapsReuse=std::chrono::milliseconds(500);
static bool lazyBind() { return caboose_gfxstream_guest_images==1; }
// A bind the phone answered with a failure (it could not take the window's layer) is
// retried after a delay that doubles up to this, even by presents: each costs the phone's
// own wait for the layer.
constexpr auto kPhoneBindRetryMax=std::chrono::seconds(4);
static void logBind(const Surface& surface, const char* outcome, int error, int vk) {
    // The first attempts, then every 32nd: enough to see why a window never binds.
    if (surface.bindAttempts>4 && surface.bindAttempts%32) return;
    std::fprintf(stderr,"CABOOSE_GPU_SURFACE_BIND object=0x%x space=%u attempt=%u %s errno=%d vk=%d\n",
        surface.object,unsigned(surface.space),surface.bindAttempts,outcome,error,vk);
}
// Binds the surface if its window exists. The bind goes out at once; a query waits up to
// kQueryBindWait for its reply and a present not at all, and a reply that has not arrived
// is collected by a later call, so nothing blocks on the phone's own wait for the
// window's layer. A transport error before the reply leaves nothing bound: the broker
// closed the connection, which it does for a refused bind. Queries (`present` false) retry a refused bind at most every kBindRetry; a present
// always does, since on Wayland nothing else maps the window (no buffer is ever attached
// to the wl_surface), so a dropped first frame would leave the application waiting for a
// frame callback.
constexpr auto kQueryBindWait=std::chrono::milliseconds(250);
static bool tryBind(Surface& surface, bool present=false) {
    if (surface.bound) return true;
    const auto now=std::chrono::steady_clock::now();
    try {
        if (!surface.client.bindPending()) {
            if ((!present && now<surface.nextBind) || now<surface.nextPhoneBind) return false;
            surface.attempted=true; ++surface.bindAttempts;
            surface.client.connect(std::getenv("CABOOSE_GFXSTREAM_SURFACE_SOCKET"),deadline());
            surface.client.beginBind(surface.boxedInstance,surface.object,0,0,deadline(),surface.space);
        }
        Record reply;
        if (!surface.client.awaitBind(present ? now : now+kQueryBindWait,&reply)) return false;
        const auto answer=status(reply.body,48);
        if (apiStatus(answer)==VK_SUCCESS) {
            surface.bound=true;
            if (surface.bindAttempts>1 || surface.phoneFailures) logBind(surface,"bound",0,0);
            return true;
        }
        const auto delay=std::min<std::chrono::steady_clock::duration>(kPhoneBindRetryMax,
            kBindRetry*(1u<<std::min(surface.phoneFailures,6u)));
        ++surface.phoneFailures;
        surface.nextPhoneBind=std::chrono::steady_clock::now()+delay;
        logBind(surface,"failed",answer.nativeError,answer.hasVk ? answer.vk : 0);
    } catch (const std::system_error& error) {
        logBind(surface,"refused",error.code().value(),0);
    }
    surface.client.reset();
    surface.attempted=false;
    surface.nextBind=now+kBindRetry;
    return false;
}
// Capabilities of a surface not bound yet, in the provider's reply format: the formats
// and image counts the phone's presentation layer offers, and no fixed extent, as for a
// Wayland surface whose size the application chooses.
static Bytes localCaps() {
    Bytes b(40,1);
    put64(b,1); for (uint32_t v:{0u,1u,0u,0u}) put32(b,v);
    const uint32_t values[13]={2,0,UINT32_MAX,UINT32_MAX,1,1,16384,16384,1,
        VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR,VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR,
        VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR|VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR,
        VK_IMAGE_USAGE_TRANSFER_SRC_BIT|VK_IMAGE_USAGE_TRANSFER_DST_BIT|VK_IMAGE_USAGE_SAMPLED_BIT|
        VK_IMAGE_USAGE_STORAGE_BIT|VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT};
    for (uint32_t v:values) put32(b,v);
    put32(b,2); put32(b,1); put32(b,1);
    put32(b,VK_FORMAT_B8G8R8A8_UNORM); put32(b,VK_COLOR_SPACE_SRGB_NONLINEAR_KHR);
    put32(b,VK_FORMAT_B8G8R8A8_SRGB); put32(b,VK_COLOR_SPACE_SRGB_NONLINEAR_KHR);
    put32(b,VK_PRESENT_MODE_FIFO_KHR);
    put32(b,0); put32(b,VK_QUEUE_GRAPHICS_BIT|VK_QUEUE_COMPUTE_BIT|VK_QUEUE_TRANSFER_BIT); put32(b,1); put32(b,1);
    return b;
}
// `fresh` asks the provider even when a recent reply exists.
static VkResult query(VkPhysicalDevice physical, VkSurfaceKHR handle, Bytes& caps, bool fresh=false) {
    auto retained=lookup(handle);
    if (!retained) return VK_ERROR_SURFACE_LOST_KHR;
    auto& surface=*retained;
    std::lock_guard<std::recursive_mutex> lock(surface.operationMutex);
    VK_FROM_HANDLE(gfxstream_vk_physical_device, device, physical);
    if (surface.instance!=gfxstream_vk_instance_to_handle(device->instance) || surface.poisoned)
        return VK_ERROR_SURFACE_LOST_KHR;
    try {
        if (!tryBind(surface)) {
            if (!lazyBind()) return VK_ERROR_SURFACE_LOST_KHR;
            caps=localCaps();
            return VK_SUCCESS;
        }
        const uint64_t boxed=get_host_u64_VkPhysicalDevice(device->internal_object);
        const auto now=std::chrono::steady_clock::now();
        // A refresh sent earlier replaces the reply once it arrived.
        surface.client.pump();
        Record refreshed;
        if (surface.client.takeQuery(&refreshed) && apiStatus(status(refreshed.body,48))==VK_SUCCESS) {
            surface.caps=std::move(refreshed.body); surface.capsTime=now;
        }
        if (!fresh && !surface.caps.empty() && surface.capsPhysical==boxed) {
            // An older reply still answers at once; its refresh goes out without a wait.
            if (now-surface.capsTime>=kCapsReuse && !surface.client.queryPending() && surface.query<UINT64_MAX)
                surface.client.beginQuery(++surface.query,boxed,deadline());
            caps=surface.caps;
            return VK_SUCCESS;
        }
        if (surface.query==UINT64_MAX) throw ProtocolError("query ID exhausted");
        auto reply=surface.client.query(++surface.query,boxed,deadline());
        auto result=apiStatus(status(reply.body,48));
        if (result==VK_SUCCESS) {
            caps=std::move(reply.body);
            surface.caps=caps; surface.capsPhysical=boxed; surface.capsTime=now;
        }
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
        surface->boxedInstance=get_host_u64_VkInstance(owner->internal_object);
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
#ifdef VK_USE_PLATFORM_XCB_KHR
static VkResult VKAPI_CALL createXcb(VkInstance instance, const VkXcbSurfaceCreateInfoKHR* info,
    const VkAllocationCallbacks* allocator, VkSurfaceKHR* out) {
    return guarded([&]() -> VkResult {
        if (!info || !out || !info->connection || !info->window || info->flags || info->pNext ||
            info->sType!=VK_STRUCTURE_TYPE_XCB_SURFACE_CREATE_INFO_KHR)
            return VK_ERROR_INITIALIZATION_FAILED;
        std::lock_guard<std::mutex> lock(mutex);
        if (surfaces.size()>=64) return VK_ERROR_OUT_OF_HOST_MEMORY;
        auto surface=std::make_shared<Surface>();
        surface->instance=instance;
        VK_FROM_HANDLE(gfxstream_vk_instance, owner, instance);
        surface->boxedInstance=get_host_u64_VkInstance(owner->internal_object);
        surface->object=info->window;
        surface->space=Client::X11Window;
        if (allocator) { surface->allocator=*allocator; surface->customAllocator=true; }
        auto* wrapper=static_cast<VkIcdSurfaceXcb*>(vk_zalloc2(&owner->vk.alloc,allocator,
            sizeof(VkIcdSurfaceXcb),8,VK_SYSTEM_ALLOCATION_SCOPE_OBJECT));
        if (!wrapper) return VK_ERROR_OUT_OF_HOST_MEMORY;
        wrapper->base.platform=VK_ICD_WSI_PLATFORM_XCB;
        wrapper->connection=info->connection; wrapper->window=info->window;
        auto handle=reinterpret_cast<VkSurfaceKHR>(wrapper);
        try { surfaces.emplace(handle,std::move(surface)); }
        catch (...) { vk_free2(&owner->vk.alloc,allocator,wrapper); throw; }
        *out=handle;
        return VK_SUCCESS;
    });
}
#endif
// Xlib clients (Wine, SDL) name the same X11 window through their Display; the surface is
// the window's, exactly as for XCB, and the Display itself is never used. The Vulkan Xlib
// types are restated here, as the Vulkan registry defines them, because Xlib's headers
// define macros (Status among them) that collide with this driver's names.
struct XlibSurfaceCreateInfo {
    VkStructureType sType;
    const void* pNext;
    VkFlags flags;
    void* dpy;
    unsigned long window;
};
struct IcdSurfaceXlib {
    VkIcdSurfaceBase base;
    void* dpy;
    unsigned long window;
};
static VkResult VKAPI_CALL createXlib(VkInstance instance, const XlibSurfaceCreateInfo* info,
    const VkAllocationCallbacks* allocator, VkSurfaceKHR* out) {
    return guarded([&]() -> VkResult {
        if (!info || !out || !info->dpy || !info->window || info->flags || info->pNext ||
            info->sType!=VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR || info->window>UINT32_MAX)
            return VK_ERROR_INITIALIZATION_FAILED;
        std::lock_guard<std::mutex> lock(mutex);
        if (surfaces.size()>=64) return VK_ERROR_OUT_OF_HOST_MEMORY;
        auto surface=std::make_shared<Surface>();
        surface->instance=instance;
        VK_FROM_HANDLE(gfxstream_vk_instance, owner, instance);
        surface->boxedInstance=get_host_u64_VkInstance(owner->internal_object);
        surface->object=static_cast<uint32_t>(info->window);
        surface->space=Client::X11Window;
        if (allocator) { surface->allocator=*allocator; surface->customAllocator=true; }
        auto* wrapper=static_cast<IcdSurfaceXlib*>(vk_zalloc2(&owner->vk.alloc,allocator,
            sizeof(IcdSurfaceXlib),8,VK_SYSTEM_ALLOCATION_SCOPE_OBJECT));
        if (!wrapper) return VK_ERROR_OUT_OF_HOST_MEMORY;
        wrapper->base.platform=VK_ICD_WSI_PLATFORM_XLIB;
        wrapper->dpy=info->dpy; wrapper->window=info->window;
        auto handle=reinterpret_cast<VkSurfaceKHR>(wrapper);
        try { surfaces.emplace(handle,std::move(surface)); }
        catch (...) { vk_free2(&owner->vk.alloc,allocator,wrapper); throw; }
        *out=handle;
        return VK_SUCCESS;
    });
}
static bool retire(Surface& surface) {
    // An outstanding bind is answered first: a granted one is retired like any other.
    if (surface.client.bindPending()) {
        try {
            Record reply;
            if (surface.client.awaitBind(deadline(),&reply) && surface.client.bound()) surface.bound=true;
        } catch (const std::system_error&) {}
        if (!surface.bound) { surface.client.reset(); surface.attempted=false; }
    }
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
#ifdef VK_USE_PLATFORM_XCB_KHR
// An X11 surface's current extent is its window's size (Vulkan's X11 surface semantics;
// Zink sizes its swapchain from it, where the phone's layer may not have an extent yet).
// The application holds libxcb, so its functions are looked up rather than linked.
// X11 client libraries' functions, from the copy the application already uses: clients
// such as SDL load libX11 privately (RTLD_LOCAL), so they are not in the global scope.
static void* x11Function(const char* library, const char* name) {
    if (void* found=dlsym(RTLD_DEFAULT,name)) return found;
    void* handle=dlopen(library,RTLD_NOW|RTLD_LOCAL);
    return handle ? dlsym(handle,name) : nullptr;
}
// An Xlib surface's Display carries its XCB connection.
static xcb_connection_t* xlibConnection(void* display) {
    using Get=xcb_connection_t*(*)(void*);
    static const auto get=reinterpret_cast<Get>(x11Function("libX11-xcb.so.1","XGetXCBConnection"));
    return get && display ? get(display) : nullptr;
}
static bool x11WindowExtent(VkSurfaceKHR handle, VkExtent2D& out) {
    const auto platform=reinterpret_cast<VkIcdSurfaceBase*>(handle)->platform;
    xcb_connection_t* connection=nullptr;
    xcb_window_t window=0;
    if (platform==VK_ICD_WSI_PLATFORM_XCB) {
        auto* xcb=reinterpret_cast<VkIcdSurfaceXcb*>(handle);
        connection=xcb->connection; window=xcb->window;
    } else if (platform==VK_ICD_WSI_PLATFORM_XLIB) {
        auto* xlib=reinterpret_cast<IcdSurfaceXlib*>(handle);
        connection=xlibConnection(xlib->dpy); window=xcb_window_t(xlib->window);
    } else return false;
    using Get=xcb_get_geometry_cookie_t(*)(xcb_connection_t*,xcb_drawable_t);
    using Reply=xcb_get_geometry_reply_t*(*)(xcb_connection_t*,xcb_get_geometry_cookie_t,xcb_generic_error_t**);
    static const auto get=reinterpret_cast<Get>(x11Function("libxcb.so.1","xcb_get_geometry"));
    static const auto reply=reinterpret_cast<Reply>(x11Function("libxcb.so.1","xcb_get_geometry_reply"));
    if (!get || !reply || !connection) return false;
    auto* geometry=reply(connection,get(connection,window),nullptr);
    if (!geometry) return false;
    out={geometry->width,geometry->height};
    std::free(geometry);
    return out.width && out.height;
}
#else
static bool x11WindowExtent(VkSurfaceKHR, VkExtent2D&) { return false; }
#endif
// A window system's present commits the application's surface with the new buffer, which
// applies the state the application set for the frame: Wayland toolkits (GTK, Qt, SDL)
// request their frame callback, regions and geometry before presenting and pace drawing on
// that callback. The phone shows the frame, so the surface is committed without a buffer.
static void commitWayland(VkSurfaceKHR handle) {
    if (reinterpret_cast<VkIcdSurfaceBase*>(handle)->platform!=VK_ICD_WSI_PLATFORM_WAYLAND) return;
    auto* wayland=reinterpret_cast<VkIcdSurfaceWayland*>(handle);
    wl_surface_commit(wayland->surface);
    wl_display_flush(wayland->display);
}
static VkResult VKAPI_CALL capabilities(VkPhysicalDevice physical, VkSurfaceKHR surface, VkSurfaceCapabilitiesKHR* out) {
    return guarded([&]() -> VkResult {
        if (!out) return VK_ERROR_INITIALIZATION_FAILED;
        Bytes b; auto result=query(physical,surface,b); if (result!=VK_SUCCESS) return result;
        const auto values=providerCaps(b).values;
        VkSurfaceCapabilitiesKHR c{};
        c.minImageCount=values[0]; c.maxImageCount=values[1];
        // Guest-owned images: the guest keeps its own pool and the phone takes native images.
        if (caboose_gfxstream_guest_images==1) { c.minImageCount=4; c.maxImageCount=8; }
        c.currentExtent={values[2],values[3]};
        c.minImageExtent={values[4],values[5]}; c.maxImageExtent={values[6],values[7]};
        c.maxImageArrayLayers=values[8]; c.supportedTransforms=values[9];
        c.currentTransform=VkSurfaceTransformFlagBitsKHR(values[10]);
        c.supportedCompositeAlpha=values[11]; c.supportedUsageFlags=values[12];
        VkExtent2D window;
        if (x11WindowExtent(surface,window)) {
            if (c.maxImageExtent.width && c.maxImageExtent.height) {
                window.width=std::clamp(window.width,c.minImageExtent.width,c.maxImageExtent.width);
                window.height=std::clamp(window.height,c.minImageExtent.height,c.maxImageExtent.height);
            }
            c.currentExtent=window;
        }
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
        auto values=providerCaps(b).modes;
        // Guest-owned images offer mailbox: the phone drops a frame that finds no free image.
        if (caboose_gfxstream_guest_images==1 &&
            std::find(values.begin(),values.end(),uint32_t(VK_PRESENT_MODE_MAILBOX_KHR))==values.end())
            values.push_back(VK_PRESENT_MODE_MAILBOX_KHR);
        uint32_t total=values.size(), copied=out ? std::min(*count,total) : total;
        if (out) for (uint32_t i=0;i<copied;++i) out[i]=VkPresentModeKHR(values[i]);
        *count=copied; return copied<total ? VK_INCOMPLETE : VK_SUCCESS;
    });
}
// Presentation support needs no window: as for the platform queries below, the phone
// presents from its first queue family, so this is answered without binding the surface.
static VkResult VKAPI_CALL support(VkPhysicalDevice, uint32_t family, VkSurfaceKHR surface, VkBool32* out) {
    return guarded([&]() -> VkResult {
        if (!out) return VK_ERROR_INITIALIZATION_FAILED;
        auto retained=lookup(surface);
        if (!retained || retained->poisoned) return VK_ERROR_SURFACE_LOST_KHR;
        *out=indexed() && family==0 ? VK_TRUE : VK_FALSE; return VK_SUCCESS;
    });
}
static VkBool32 VKAPI_CALL waylandSupport(VkPhysicalDevice, uint32_t family, wl_display*) {
    return indexed() && family == 0 ? VK_TRUE : VK_FALSE;
}
#ifdef VK_USE_PLATFORM_XCB_KHR
static VkBool32 VKAPI_CALL xcbSupport(VkPhysicalDevice, uint32_t family, xcb_connection_t*, xcb_visualid_t) {
    return indexed() && family == 0 ? VK_TRUE : VK_FALSE;
}
#endif
static VkBool32 VKAPI_CALL xlibSupport(VkPhysicalDevice, uint32_t family, void*, unsigned long) {
    return indexed() && family == 0 ? VK_TRUE : VK_FALSE;
}
static VkResult VKAPI_CALL presentRectangles(VkPhysicalDevice, VkSurfaceKHR, uint32_t*, VkRect2D*) {
    return VK_ERROR_FEATURE_NOT_PRESENT;
}
static void maskHostImageCopy(void* chain) {
    for (auto* item=static_cast<VkBaseOutStructure*>(chain);item;item=item->pNext) {
        if (item->sType==VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_HOST_IMAGE_COPY_FEATURES_EXT)
            reinterpret_cast<VkPhysicalDeviceHostImageCopyFeaturesEXT*>(item)->hostImageCopy=VK_FALSE;
        if (item->sType==VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_4_FEATURES)
            reinterpret_cast<VkPhysicalDeviceVulkan14Features*>(item)->hostImageCopy=VK_FALSE;
        if (item->sType==VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROVOKING_VERTEX_FEATURES_EXT) {
            auto* pv=reinterpret_cast<VkPhysicalDeviceProvokingVertexFeaturesEXT*>(item);
            pv->provokingVertexLast=VK_TRUE;
            pv->transformFeedbackPreservesProvokingVertex=VK_TRUE;
        }
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
// The platform presentation queries are physical-device entry points the loader asks for
// by name; Mesa's trampolines for them exist only for platforms its common code was built
// with, so they are returned here directly.
static PFN_vkVoidFunction procAddr(const char* name) {
    if (!active() || !name) return nullptr;
#ifdef VK_USE_PLATFORM_XCB_KHR
    if (!strcmp(name,"vkGetPhysicalDeviceXcbPresentationSupportKHR")) return reinterpret_cast<PFN_vkVoidFunction>(xcbSupport);
#endif
    if (!strcmp(name,"vkGetPhysicalDeviceXlibPresentationSupportKHR")) return reinterpret_cast<PFN_vkVoidFunction>(xlibSupport);
    if (!strcmp(name,"vkGetPhysicalDeviceWaylandPresentationSupportKHR")) return reinterpret_cast<PFN_vkVoidFunction>(waylandSupport);
    return nullptr;
}
static void install(vk_instance_dispatch_table& table) {
    if (!active()) return;
    table.CreateWaylandSurfaceKHR=create;
#ifdef VK_USE_PLATFORM_XCB_KHR
    table.CreateXcbSurfaceKHR=createXcb;
#endif
    table.CreateXlibSurfaceKHR=reinterpret_cast<decltype(table.CreateXlibSurfaceKHR)>(createXlib);
    table.DestroySurfaceKHR=destroy;
}
static void install(vk_physical_device_dispatch_table& table) {
    if (!active()) return;
    table.GetPhysicalDeviceSurfaceSupportKHR=support;
    table.GetPhysicalDeviceWaylandPresentationSupportKHR=waylandSupport;
#ifdef VK_USE_PLATFORM_XCB_KHR
    table.GetPhysicalDeviceXcbPresentationSupportKHR=xcbSupport;
#endif
    table.GetPhysicalDeviceXlibPresentationSupportKHR=
        reinterpret_cast<decltype(table.GetPhysicalDeviceXlibPresentationSupportKHR)>(xlibSupport);
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
            strcmp(name,"VK_KHR_xcb_surface") && strcmp(name,"VK_KHR_xlib_surface") &&
            strcmp(name,"VK_EXT_headless_surface") &&
            strcmp(name,"VK_KHR_get_surface_capabilities2")) extensions.extensions[i]=false;
    }
}
#include "mesa_swapchain.inc"
}
#else
namespace caboose_surface {
template<class T> static void install(T&) {}
template<class T> static void gate(T&) {}
static PFN_vkVoidFunction procAddr(const char*) { return nullptr; }
static bool beforeDestroyInstance(VkInstance) { return true; }
static bool beforeDestroyDevice(VkDevice) { return true; }
static bool profileReady() { return true; }
static VkResult validateDeviceCreate(const VkDeviceCreateInfo*) { return VK_SUCCESS; }
}
#endif
