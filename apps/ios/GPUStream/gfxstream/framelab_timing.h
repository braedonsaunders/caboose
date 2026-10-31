#pragma once
// Frame lab (guest/framelab) on the phone: when each live GPU present reached the display.
//
// With CABOOSE_FRAMELAB=1 the decoder enables VK_GOOGLE_display_timing on the device
// (the gfxstream fork's "Caboose: enable VK_GOOGLE_display_timing for frame lab"), every native present carries its present serial as the present ID, and
// after a frame's present fence completes the presentation engine's past timings are
// printed to standard error:
//   caboose-framelab: present window=W seq=S presented_ns=P now_ns=N
// P is when the image was shown and N when the line was written, both in nanoseconds of
// MoltenVK's presentation clock (mach_absolute_time, as CACurrentMediaTime); frame lab's
// driver uses N - P to place P on its own clock. Without the variable, or a device without the extension,
// nothing is chained or printed.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <unordered_map>
#include <vulkan/vulkan.h>
#include <mach/mach_time.h>

namespace caboose::framelab {

inline bool enabled() {
    static const bool on = [] {
        const char* value = std::getenv("CABOOSE_FRAMELAB");
        return value && std::strcmp(value, "1") == 0;
    }();
    return on;
}

// The device's vkGetPastPresentationTimingGOOGLE, or null when the extension is off.
template <class Dispatch>
PFN_vkGetPastPresentationTimingGOOGLE pastTiming(const Dispatch* vk, VkDevice device) {
    if (!enabled() || !vk || !vk->vkGetDeviceProcAddr || !device) return nullptr;
    static std::mutex mutex;
    static std::unordered_map<VkDevice, PFN_vkGetPastPresentationTimingGOOGLE> known;
    std::lock_guard<std::mutex> lock(mutex);
    auto found = known.find(device);
    if (found != known.end()) return found->second;
    auto fn = reinterpret_cast<PFN_vkGetPastPresentationTimingGOOGLE>(
        vk->vkGetDeviceProcAddr(device, "vkGetPastPresentationTimingGOOGLE"));
    known.emplace(device, fn);
    return fn;
}

// Prints the timings the presentation engine has for a swapchain (each is returned once).
template <class Dispatch>
void reportPresented(const Dispatch* vk, VkDevice device, VkSwapchainKHR swapchain, uint64_t window) {
    auto fn = pastTiming(vk, device);
    if (!fn || !swapchain) return;
    VkPastPresentationTimingGOOGLE timings[16];
    uint32_t count = 16;
    VkResult result = fn(device, swapchain, &count, timings);
    if (result != VK_SUCCESS && result != VK_INCOMPLETE) return;
    mach_timebase_info_data_t base{};
    mach_timebase_info(&base);
    const uint64_t now = mach_absolute_time() * base.numer / base.denom;
    for (uint32_t i = 0; i < count; ++i) {
        if (!timings[i].actualPresentTime) continue;
        std::fprintf(stderr, "caboose-framelab: present window=%llu seq=%u presented_ns=%llu now_ns=%llu\n",
                     static_cast<unsigned long long>(window), timings[i].presentID,
                     static_cast<unsigned long long>(timings[i].actualPresentTime),
                     static_cast<unsigned long long>(now));
    }
}

}  // namespace caboose::framelab
