// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "headless_surface_internal.h"
#include "presentation_driver_lock.h"
#include <cerrno>
#include <new>

namespace caboose::gpuv2 {
struct HeadlessSurface {
    VkInstance instance = VK_NULL_HANDLE;
    VkSurfaceKHR surface = VK_NULL_HANDLE;
    PFN_vkDestroySurfaceKHR destroy = nullptr;
};
int createHeadlessSurface(VkInstance instance, HeadlessSurface** out, VkResult* vulkanResult) {
    if (!out || !vulkanResult) return EINVAL;
    *out = nullptr;
    if (!instance) return EINVAL;
    auto get = runtimeInstanceProcAddr();
    if (!get) return ENODEV;
    auto create = reinterpret_cast<PFN_vkCreateHeadlessSurfaceEXT>(get(instance, "vkCreateHeadlessSurfaceEXT"));
    auto destroy = reinterpret_cast<PFN_vkDestroySurfaceKHR>(get(instance, "vkDestroySurfaceKHR"));
    if (!create || !destroy) return ENOTSUP;
    auto* surface = new (std::nothrow) HeadlessSurface;
    if (!surface) return ENOMEM;
    surface->instance = instance;
    surface->destroy = destroy;
    VkHeadlessSurfaceCreateInfoEXT info{};
    info.sType = VK_STRUCTURE_TYPE_HEADLESS_SURFACE_CREATE_INFO_EXT;
    {
        DriverLock driver;
        *vulkanResult = create(instance, &info, nullptr, &surface->surface);
    }
    if (*vulkanResult != VK_SUCCESS) { delete surface; return EIO; }
    *out = surface;
    return 0;
}
int destroyHeadlessSurface(HeadlessSurface** surface) {
    if (!surface || !*surface) return EINVAL;
    HeadlessSurface* owned = *surface;
    {
        DriverLock driver;
        owned->destroy(owned->instance, owned->surface, nullptr);
    }
    delete owned;
    *surface = nullptr;
    return 0;
}
VkSurfaceKHR headlessSurfaceHandle(const HeadlessSurface* surface) {
    return surface ? surface->surface : VK_NULL_HANDLE;
}
}
