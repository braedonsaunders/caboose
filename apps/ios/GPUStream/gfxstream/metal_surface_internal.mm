// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CATransaction.h>
#include "metal_surface_internal.h"
#include <cerrno>
#include <new>
#ifdef CABOOSE_GPU_MEMORY_AUDIT
#include "frame_buffer.h"
#include "layer_extent_diagnostic.h"
#include <cstdio>
#endif

namespace caboose::gpuv2 {
namespace {
#ifdef CABOOSE_GPU_MEMORY_AUDIT
LayerExtentDiagnosticBudget layerExtentBudget;
uint32_t extentExceptionCategory(NSException* exception) {
    // Fixed categories only. Never emit name, reason, userInfo or object text.
    if ([exception.name isEqualToString:NSInvalidArgumentException]) return 1;
    if ([exception.name isEqualToString:NSRangeException]) return 2;
    if ([exception.name isEqualToString:NSInternalInconsistencyException]) return 3;
    return 4;
}
bool extentAuditEnabled() {
    // The attached surface retains its initialized decoder instance. Features
    // are immutable after startup; do not acquire the runtime mutex on main.
    const auto* fb = gfxstream::host::FrameBuffer::getFB();
    return fb && fb->getFeatures().CabooseMemoryAudit.enabled();
}
void traceExtent(bool enabled, CAMetalLayer* layer, uint32_t width, uint32_t height,
                 uint32_t stage, uint32_t event = 0, uint32_t exception = 0) {
    if (!enabled) return;
    const unsigned record = layerExtentBudget.take();
    if (record > 64) return;
    if (record == 64) {
        std::fprintf(stderr, "CABOOSE_GPU_LAYER_EXTENT overflow=1\n");
        return;
    }
    LayerExtentSnapshot snapshot({NAN, NAN, NAN, NAN, NAN});
    uint32_t sampleException = 0;
    @try {
        const CGSize bounds = layer.bounds.size;
        const CGFloat scale = layer.contentsScale;
        const CGSize drawable = layer.drawableSize;
        snapshot = LayerExtentSnapshot({double(bounds.width), double(bounds.height), double(scale),
                                       double(drawable.width), double(drawable.height)});
    } @catch (NSException* caught) {
        sampleException = extentExceptionCategory(caught);
    }
    std::fprintf(stderr,
        "CABOOSE_GPU_LAYER_EXTENT record=%u stage=%u event=%u exception=%u sample_exception=%u "
        "requested_width=%u requested_height=%u finite=%u bounds_width=%.17g bounds_height=%.17g "
        "contents_scale=%.17g drawable_width=%.17g drawable_height=%.17g\n",
        record, stage, event, exception, sampleException, width, height, snapshot.finite,
        snapshot.values[0], snapshot.values[1], snapshot.values[2], snapshot.values[3], snapshot.values[4]);
}
#else
bool extentAuditEnabled() { return false; }
uint32_t extentExceptionCategory(NSException*) { return 0; }
void traceExtent(bool, CAMetalLayer*, uint32_t, uint32_t, uint32_t, uint32_t = 0, uint32_t = 0) {}
#endif
}
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
int configureMetalSurfaceExtent(MetalSurface* surface, void* trustedLayer,
                                uint32_t width, uint32_t height) {
    if (![NSThread isMainThread]) return EPERM;
    if (!surface || !trustedLayer || surface->layer != (__bridge CAMetalLayer*)trustedLayer ||
        !width || !height) return EINVAL;
    const bool audit = extentAuditEnabled();
    // Stages: 0 initial, 1 bounds, 2 scale, 3 drawable, 4 commit, 5 readback.
    // Events: 0 snapshot, 1 mutation exception, 2 readback mismatch, 3 verified.
    uint32_t stage = 0;
    traceExtent(audit, surface->layer, width, height, stage);
    @try {
        [CATransaction begin];
        @try {
            [CATransaction setDisableActions:YES];
            CGRect bounds = surface->layer.bounds;
            bounds.size = CGSizeMake(width, height);
            stage = 1;
            surface->layer.bounds = bounds;
            traceExtent(audit, surface->layer, width, height, stage);
            stage = 2;
            surface->layer.contentsScale = 1;
            traceExtent(audit, surface->layer, width, height, stage);
            stage = 3;
            surface->layer.drawableSize = bounds.size;
            traceExtent(audit, surface->layer, width, height, stage);
        } @finally {
            const uint32_t beforeCommit = stage;
            stage = 4;
            [CATransaction commit];
            traceExtent(audit, surface->layer, width, height, stage);
            // If a setter threw, a successful finally/commit must not obscure
            // which setter produced the exception caught below.
            stage = beforeCommit;
        }
        stage = 5;
        const CGSize natural = surface->layer.bounds.size;
        const CGSize drawable = surface->layer.drawableSize;
        if (surface->layer.contentsScale != 1 || natural.width != width || natural.height != height ||
            drawable.width != width || drawable.height != height) {
            traceExtent(audit, surface->layer, width, height, stage, 2);
            return EIO;
        }
        traceExtent(audit, surface->layer, width, height, stage, 3);
        return 0;
    } @catch (NSException* exception) {
        traceExtent(audit, surface->layer, width, height, stage, 1, extentExceptionCategory(exception));
        return EIO;
    }
}
bool metalSurfaceMatchesLayer(const MetalSurface* surface, void* trustedLayer) {
    return surface && trustedLayer && surface->layer == (__bridge CAMetalLayer*)trustedLayer;
}
}
