// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>
#include "metal_surface_internal.h"
#include <cerrno>
#include <new>

namespace caboose::gpuv2 {
struct MetalSurface {
    VkInstance instance = VK_NULL_HANDLE;
    VkSurfaceKHR surface = VK_NULL_HANDLE;
    PFN_vkDestroySurfaceKHR destroy = nullptr;
    __strong CAMetalLayer* layer = nil;
};
int createMetalSurface(VkInstance instance, void* metalLayer, MetalSurface** out,
                       VkResult* vulkanResult) {
    if (!out || !vulkanResult) return EINVAL;
    *out = nullptr;
    if (![NSThread isMainThread]) return EPERM;
    if (!instance || !metalLayer) return EINVAL;
    id value = (__bridge id)metalLayer;
    if (![value isKindOfClass:CAMetalLayer.class]) return EINVAL;
    auto get = runtimeInstanceProcAddr();
    if (!get) return ENODEV;
    auto create = reinterpret_cast<PFN_vkCreateMetalSurfaceEXT>(
        get(instance, "vkCreateMetalSurfaceEXT"));
    auto destroy = reinterpret_cast<PFN_vkDestroySurfaceKHR>(
        get(instance, "vkDestroySurfaceKHR"));
    if (!create || !destroy) return ENOTSUP;
    auto* surface = new (std::nothrow) MetalSurface;
    if (!surface) return ENOMEM;
    surface->instance = instance;
    surface->destroy = destroy;
    surface->layer = (CAMetalLayer*)value;
    VkMetalSurfaceCreateInfoEXT info{};
    info.sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT;
    info.pLayer = surface->layer;
    *vulkanResult = create(instance, &info, nullptr, &surface->surface);
    if (*vulkanResult != VK_SUCCESS) { delete surface; return EIO; }
    *out = surface;
    return 0;
}
int destroyMetalSurface(MetalSurface** surface) {
    if (!surface || !*surface) return EINVAL;
    if (![NSThread isMainThread]) return EPERM;
    MetalSurface* owned = *surface;
    owned->destroy(owned->instance, owned->surface, nullptr);
    delete owned;
    *surface = nullptr;
    return 0;
}
VkSurfaceKHR metalSurfaceHandle(const MetalSurface* surface) {
    return surface ? surface->surface : VK_NULL_HANDLE;
}
}
