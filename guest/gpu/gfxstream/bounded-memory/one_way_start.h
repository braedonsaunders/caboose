// SPDX-License-Identifier: MIT
#pragma once
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <string>
#include <thread>
#include <vector>
#include <vulkan/vulkan_core.h>

#include "completion_feed.h"
#include "device_answers.h"
#include "silent_success.h"
#include "static_query_cache.h"

// One-way start (docs/gpu-live.md, "One-way start"). With hello feature 0x1000000, granted with
// silent success, the process names its instances, physical devices, devices and queues itself
// (0xCA handles), and the commands that make them may go without their reply: the device
// stream switches to REPLY_MODE(3) for the one command and back to REPLY_MODE(1) after it. The
// process sends such a command one-way only when an identical one succeeded earlier in the
// executor session, so it predicts the answer (success, a queue that exists); a prediction the phone does not bear out is a FAULT on the feed, and the
// process's device is lost (silent_success.h, fault). The first command of its kind in a
// session is asked as before, and its success is kept in the session's instance scope
// (static_query_cache.h), which a new executor connection starts empty.
namespace caboose::one_way {

inline constexpr uint32_t kHelloBit = silent::kOneWayStartBit;
// REPLY_MODE(3): silent success and silent start.
inline constexpr uint32_t kModeStart = silent::kModeSilentSuccess | 2u;

// The commands REPLY_MODE(3) silences beside silent success's, by opcode. The decoder's list
// is apps/ios/GPUStream/gfxstream/silent_replies.h; test_silent_success_list.py fails when the
// two differ.
inline constexpr uint32_t kStartOpcodes[] = {
    20000u,  // vkCreateInstance
    20002u,  // vkEnumeratePhysicalDevices
    20011u,  // vkCreateDevice
    20017u,  // vkGetDeviceQueue
    20155u,  // vkGetDeviceQueue2
};
inline bool startOpcode(uint32_t opcode) {
    return std::find(std::begin(kStartOpcodes), std::end(kStartOpcodes), opcode) != std::end(kStartOpcodes);
}

// The executor connection's hello: whether one-way start and silent success were granted
// (SocketStream.cpp sets it). Only then does the process name these objects itself: a decoder
// without one-way start mints their handles whatever the process wrote.
//
// CABOOSE_ONE_WAY_START=0 asks every start command. CABOOSE_ONE_WAY_START=predict, for checks
// only, predicts every start command the process can key, as if an identical one had
// succeeded, so that a check can send a prediction the phone does not bear out
// (driver/sync-check, one_way_misprediction).
enum class Policy { off, earned, predict };
inline Policy policy() {
    static const Policy value = [] {
        const char* setting = std::getenv("CABOOSE_ONE_WAY_START");
        if (setting && !std::strcmp(setting, "0")) return Policy::off;
        if (setting && !std::strcmp(setting, "predict")) return Policy::predict;
        return Policy::earned;
    }();
    return value;
}
inline bool granted() { return policy() != Policy::off && silent::replyMode().startGranted(); }

// With CABOOSE_CAPABILITY_CACHE_DIAGNOSTICS, a line for each command sent one-way.
inline void sentOneWay(uint32_t opcode) {
    static const bool diagnostics = std::getenv("CABOOSE_CAPABILITY_CACHE_DIAGNOSTICS") != nullptr;
    if (diagnostics) std::fprintf(stderr, "CABOOSE_ONE_WAY_START opcode=%u\n", opcode);
}

// A stream switches to silent success once the process's feed runs (VkEncoder::lock). The feed
// connects locally right after the device stream's hello, so a process's first start command
// may come before it: wait for it this long before asking the command instead.
inline constexpr auto kFeedWait = std::chrono::milliseconds(100);
template <class Clock = std::chrono::steady_clock> inline bool awaitFeed(typename Clock::duration limit = kFeedWait) {
    const auto until = Clock::now() + limit;
    while (!completion::feedActive.load(std::memory_order_acquire)) {
        if (completion::executorLost.load(std::memory_order_acquire) || Clock::now() >= until) return false;
        std::this_thread::sleep_for(std::chrono::microseconds(200));
    }
    return true;
}

// The questions kept in the session's instance scope: an identical command that succeeded.
inline constexpr uint32_t kInstanceMade = 0xCAB00010u, kDeviceMade = 0xCAB00011u, kQueueNamed = 0xCAB00012u;

// An instance's creation parameters: its flags, application, layers, extensions (sorted) and
// API version. False when the creation chains a structure other than the loader's own, which
// the loader takes off before the driver sees it: such an instance is always asked.
inline bool instanceQuestion(const VkInstanceCreateInfo* info, std::string* out) {
    auto put = [out](const auto& value) { out->append(reinterpret_cast<const char*>(&value), sizeof(value)); };
    auto text = [out, &put](const char* value) {
        put(uint32_t(value ? 1 : 0));
        if (value) out->append(value, std::strlen(value) + 1);
    };
    auto names = [&put, out](uint32_t count, const char* const* list) {
        if (count && !list) return false;
        std::vector<std::string> sorted;
        for (uint32_t i = 0; i < count; ++i) {
            if (!list[i]) return false;
            sorted.emplace_back(list[i]);
        }
        std::sort(sorted.begin(), sorted.end());
        put(uint32_t(sorted.size()));
        for (const auto& name : sorted) out->append(name.c_str(), name.size() + 1);
        return true;
    };
    if (!info) return false;
    for (auto* next = static_cast<const VkBaseInStructure*>(info->pNext); next; next = next->pNext)
        if (next->sType != VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO &&
            next->sType != VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO)
            return false;
    put(info->flags);
    const VkApplicationInfo* app = info->pApplicationInfo;
    put(uint32_t(app ? 1 : 0));
    if (app) {
        if (app->pNext) return false;
        text(app->pApplicationName);
        put(app->applicationVersion);
        text(app->pEngineName);
        put(app->engineVersion);
        put(app->apiVersion);
    }
    return names(info->enabledLayerCount, info->ppEnabledLayerNames) &&
           names(info->enabledExtensionCount, info->ppEnabledExtensionNames);
}

inline std::string instanceKey(const std::string& question) {
    const auto digest = memory::DeviceFingerprints::of(1, question.data(), question.size());
    return memory::StaticQueryCache::key(kInstanceMade, memory::StaticQueryCache::kInstanceScope, digest.high,
                                         digest.low);
}
// A session has one GPU: a device's fingerprint names its creation on it.
inline std::string deviceKey(const memory::DeviceFingerprints::Fingerprint& fingerprint) {
    return memory::StaticQueryCache::key(kDeviceMade, memory::StaticQueryCache::kInstanceScope, fingerprint.high,
                                         fingerprint.low);
}
inline std::string queueKey(const memory::DeviceFingerprints::Fingerprint& fingerprint, uint32_t flags,
                            uint32_t family, uint32_t index) {
    return memory::StaticQueryCache::key(kQueueNamed, memory::StaticQueryCache::kInstanceScope, fingerprint.high,
                                         fingerprint.low, flags, family, index);
}

// Whether an identical command succeeded earlier in the session.
inline bool succeededBefore(const std::string& key, memory::StaticQueryCache& cache = memory::staticQueryCache) {
    if (policy() == Policy::predict) return true;
    std::string value;
    return cache.peekBytes(key, &value) && value == std::string(1, '\1');
}

// Keeps an asked command's success for the session it was asked in: `epoch` is the cache's
// connection epoch before it was sent. Nothing is kept once the executor is lost, or for a
// connection that has since been replaced.
inline void keep(const std::string& key, const std::string& value, uint64_t epoch,
                 memory::StaticQueryCache& cache = memory::staticQueryCache) {
    if (completion::executorLost.load(std::memory_order_acquire) || cache.epoch() != epoch) return;
    std::string known;
    cache.peekBytes(key, &known);  // this thread's lookup epoch, which storeBytes checks
    cache.storeBytes(key, value);
}
inline void succeeded(const std::string& key, uint64_t epoch, memory::StaticQueryCache& cache = memory::staticQueryCache) {
    keep(key, std::string(1, '\1'), epoch, cache);
}

}  // namespace caboose::one_way
