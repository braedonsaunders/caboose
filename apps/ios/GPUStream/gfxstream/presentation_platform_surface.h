// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// The native surface a presentation surface presents into: a CAMetalLayer's Metal surface
// on Apple platforms, a headless surface elsewhere (the Linux executor). Included by
// presentation_api.cpp only, which Apple builds compile as Objective-C++.
#pragma once
#include <vulkan/vulkan.h>
#if defined(__APPLE__)
#ifndef __OBJC__
#error "presentation_api.cpp must be compiled as Objective-C++ on Apple platforms"
#endif
#import <Foundation/Foundation.h>
#include "metal_surface_internal.h"
#else
#include "headless_surface_internal.h"
#endif

namespace caboose::gpuv2 {
#if defined(__APPLE__)
using PlatformSurface = MetalSurface;
inline VkSurfaceKHR platformSurfaceHandle(const PlatformSurface* surface) { return metalSurfaceHandle(surface); }
inline int destroyPlatformSurface(PlatformSurface** surface) { return destroyMetalSurface(surface); }
// Layer attachment and detachment run on main; GPU work never does.
inline bool onMainThread() { return [NSThread isMainThread]; }
// A Metal surface's current extent is its layer's drawable size, which configure_extent sets.
constexpr bool kPlatformSurfaceFixedExtent = true;
#else
using PlatformSurface = HeadlessSurface;
inline VkSurfaceKHR platformSurfaceHandle(const PlatformSurface* surface) { return headlessSurfaceHandle(surface); }
inline int destroyPlatformSurface(PlatformSurface** surface) { return destroyHeadlessSurface(surface); }
// No thread is reserved for a user interface.
inline bool onMainThread() { return false; }
// A headless surface takes the extent of the swapchain created on it.
constexpr bool kPlatformSurfaceFixedExtent = false;
#endif
}
