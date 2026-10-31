// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>

namespace caboose::gpuv2 {

// Completion feedback for one guest process (docs/gpu-live.md, "Completion feed").
//
// COMPLETION_WATCH(queue, serial) arrives on a device stream right after a queue
// submission. The watch submits a marker behind that submission and returns without
// waiting; a watcher thread waits for markers in order and queues one record per watch.
// COMPLETION_FEED turns another stream of the same process into the writer of those
// records. Records queued before the feed stream attaches are kept for it.
class CompletionFeed {
public:
    static constexpr uint32_t kFeedOpcode = 0x4342FE01;
    static constexpr uint32_t kWatchOpcode = 0x4342FE02;
    static constexpr uint32_t kFeedVersion = 1;
    static constexpr uint32_t kFeedPacketSize = 16;
    static constexpr uint32_t kWatchPacketSize = 24;
    static constexpr size_t kRecordSize = 16;
    static constexpr int32_t kCompleted = 0;
    static constexpr int32_t kDeviceLost = -4;
    static constexpr int32_t kUnwatched = 1;
    // Outstanding watches a process may have; beyond it a watch is reported unwatched.
    static constexpr size_t kMaxOutstanding = 4096;

    static bool isFeedOpcode(uint32_t opcode) { return opcode == kFeedOpcode || opcode == kWatchOpcode; }

    // The marker backend: submits a marker behind `boxedQueue`'s work and returns a waiter
    // that blocks until it completes (returning the VkResult) and then releases it, or an
    // empty function when the queue cannot be watched.
    using Waiter = std::function<int32_t()>;
    using Submit = std::function<Waiter(uint64_t boxedQueue)>;

    explicit CompletionFeed(Submit submit);
    ~CompletionFeed();
    CompletionFeed(const CompletionFeed&) = delete;
    CompletionFeed& operator=(const CompletionFeed&) = delete;

    // From a device stream. Never waits for the GPU.
    void watch(uint64_t boxedQueue, uint64_t serial);
    // Runs the feed on `fd` until the guest closes it (0), `stop` is set or the socket is
    // shut down (0), or an error (errno). Only one feed stream may attach, once.
    int run(int fd, const std::atomic_bool& stop);
    // Ends the watcher once outstanding markers complete; called before destruction and
    // on process stop. Records after this are dropped.
    void close();

    // Parses a complete WATCH packet; false if malformed.
    static bool parseWatch(const unsigned char* packet, size_t size, uint64_t* queue, uint64_t* serial);
    // Parses a complete FEED packet; false if malformed or an unknown version.
    static bool parseFeed(const unsigned char* packet, size_t size);

private:
    struct Pending { uint64_t serial; Waiter wait; };
    struct Record { uint64_t serial; int32_t status; };
    void watcherLoop();
    void push(uint64_t serial, int32_t status);

    Submit submit_;
    std::mutex mutex_;
    std::condition_variable markersChanged_;
    std::deque<Pending> markers_;
    std::deque<Record> records_;
    int wake_[2] = {-1, -1};
    bool attached_ = false;
    bool detached_ = false;
    bool closing_ = false;
    std::thread watcher_;
};

}  // namespace caboose::gpuv2
