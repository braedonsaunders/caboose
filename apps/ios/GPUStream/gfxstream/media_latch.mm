// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "media_latch.h"
#include "media_apple.h"
#include "media_copy.h"
#include "media_stats.h"
#include "vk_decoder_global_state.h"
#include <atomic>
#include <cstdio>

namespace caboose::gpuv2 {
namespace {
using gfxstream::host::vk::CabooseMediaLatchObjects;
using gfxstream::host::vk::VkDecoderGlobalState;

// Bounded diagnostics: a skipped entry is logged, at most 64 times per process.
void skipped(const char* why, int detail) {
    media::Stats::instance().count(media::Stats::instance().latchSkips);
    static std::atomic_uint lines{0};
    const unsigned n = lines.fetch_add(1);
    if (n < 64) std::fprintf(stderr, "CABOOSE_GPU_MEDIA_LATCH skipped=%s detail=%d\n", why, detail);
    else if (n == 64) std::fprintf(stderr, "CABOOSE_GPU_MEDIA_LATCH limit=64\n");
}
}

int executeLatch(uint32_t contextId, const uint8_t* data, size_t size) {
    media::Latch latch;
    if (media::parseLatch(data, size, &latch) != 0) return EPROTO;
    media::Stats::instance().count(media::Stats::instance().latchPackets);
    auto* state = VkDecoderGlobalState::get();
    if (!state) { skipped("decoder", 0); return 0; }
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(kLatchWaitMilliseconds);
    for (const auto& entry : latch.entries) {
        std::unique_ptr<CabooseMediaLatchObjects> objects;
        VkResult r = state->acquireCabooseMediaLatchObjects(contextId,
            reinterpret_cast<VkQueue>(static_cast<uintptr_t>(latch.queue)),
            reinterpret_cast<VkImage>(static_cast<uintptr_t>(entry.image)), &objects);
        if (r != VK_SUCCESS) { skipped("objects", r); continue; }
        media::CopyTarget target;
        target.vk = media::functionsFrom(*objects->vk);
        target.vk.exportMetalObjects = objects->vk->vkExportMetalObjectsEXT;
        target.physicalDevice = objects->physicalDevice;
        target.device = objects->device;
        target.queue = objects->queue;
        target.queueFamily = objects->queueFamily;
        target.queueMutex = objects->queueMutex.get();
        target.image = objects->image;
        target.format = objects->format;
        target.extent = {objects->extent.width, objects->extent.height};
        target.planes = entry.planes;
        target.metalObjects = objects->metalObjects;
        media::Pending pending;
        if (entry.kind == media::kPicture) {
            std::shared_ptr<media::Picture> picture;
            const auto wait = media::Registry::instance().waitFor(entry.token, entry.surface, entry.serial,
                                                                  deadline, &picture);
            if (wait != media::Registry::Wait::ready) { skipped("picture", int(wait)); continue; }
            r = media::copyPicture(target, static_cast<media::PixelBufferPicture&>(*picture).buffer(), &pending);
        } else {
            r = media::copyPixels(target, entry, &pending);
        }
        if (r != VK_SUCCESS) { skipped(entry.kind == media::kPicture ? "copy-picture" : "copy-pixels", r); continue; }
        // The leases keep the image, its memory and the device alive until the copy completes.
        std::shared_ptr<void> leases(objects.release(), [](void* p) { delete static_cast<CabooseMediaLatchObjects*>(p); });
        media::Reclaimer::instance().retire(std::move(pending), std::move(leases));
        auto& stats = media::Stats::instance();
        stats.count(entry.kind == media::kPicture ? stats.latchedPictures : stats.latchedPixels);
    }
    return 0;
}
}
