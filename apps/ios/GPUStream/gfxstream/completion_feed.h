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
#include <unordered_map>
#include <vector>

namespace caboose::gpuv2 {

// Completion feedback for one guest process (docs/gpu-live.md, "Completion feed").
//
// COMPLETION_WATCH(queue, serial) arrives on a device stream right after a queue
// submission. The watch submits a marker behind that submission and returns without
// waiting. Each queue has its own watcher lane, which waits for that queue's markers in
// order and queues one record per watch the moment its marker completes, so a queue with
// long work never holds back the records of another queue.
// COMPLETION_FEED turns another stream of the same process into the writer of those
// records. Records queued before the feed stream attaches are kept for it.
class CompletionFeed {
public:
    static constexpr uint32_t kFeedOpcode = 0x4342FE01;
    static constexpr uint32_t kWatchOpcode = 0x4342FE02;
    static constexpr uint32_t kOrderOpcode = 0x4342FE03;
    static constexpr uint32_t kFeedVersion = 1;
    static constexpr uint32_t kFeedPacketSize = 16;
    static constexpr uint32_t kWatchPacketSize = 24;
    static constexpr uint32_t kOrderPacketSize = 16;
    static constexpr size_t kRecordSize = 16;
    static constexpr int32_t kCompleted = 0;
    static constexpr int32_t kDeviceLost = -4;
    static constexpr int32_t kUnwatched = 1;
    // Outstanding watches a process may have; beyond it a watch is reported unwatched.
    static constexpr size_t kMaxOutstanding = 4096;
    // Watcher lanes (threads) a process may have. A marker of a queue past this joins the
    // lane with the fewest markers.
    static constexpr size_t kMaxLanes = 8;

    static bool isFeedOpcode(uint32_t opcode) {
        return opcode == kFeedOpcode || opcode == kWatchOpcode || opcode == kOrderOpcode;
    }
    static size_t packetSize(uint32_t opcode) {
        return opcode == kFeedOpcode ? kFeedPacketSize : opcode == kWatchOpcode ? kWatchPacketSize : kOrderPacketSize;
    }

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
    // From a device stream: every command before this ORDER mark has been decoded.
    void ordered(uint64_t serial);
    // Blocks until the ORDER mark `serial` (or a later one) has been decoded: 0, or
    // ECANCELED once the process stops. CPU ordering only; it never waits for the GPU.
    int waitOrdered(uint64_t serial);
    // Wakes every order wait with ECANCELED and refuses later ones (process stop).
    void cancelOrders();
    // Runs the feed on `fd` until the guest closes it (0), `stop` is set or the socket is
    // shut down (0), or an error (errno). A later feed stream takes over from an earlier one.
    int run(int fd, const std::atomic_bool& stop);
    // Ends the watcher lanes once outstanding markers complete; called before destruction
    // and on process stop. Records after this are dropped.
    void close();

    // Where completion stands, for a stalled-completion report (process_registry): the oldest
    // marker still waited for, the last completion and the last record the guest was sent.
    // Times are steady-clock milliseconds; 0 when it never happened.
    struct State {
        uint64_t watches = 0, unwatched = 0;
        size_t outstanding = 0;
        size_t lanes = 0;
        uint64_t oldestSerial = 0, oldestQueue = 0;
        int64_t oldestWatchedMs = 0;
        uint64_t lastCompletedSerial = 0;
        int32_t lastStatus = 0;
        int64_t lastCompletedMs = 0;
        uint64_t lastWrittenSerial = 0;
        int64_t lastWrittenMs = 0;
        size_t unwritten = 0;
        bool feedAttached = false;
        uint64_t ordered = 0;
    };
    State state();
    static int64_t nowMs();

    // Parses a complete WATCH packet; false if malformed.
    static bool parseWatch(const unsigned char* packet, size_t size, uint64_t* queue, uint64_t* serial);
    // Parses a complete ORDER packet; false if malformed.
    static bool parseOrder(const unsigned char* packet, size_t size, uint64_t* serial);
    // Parses a complete FEED packet; false if malformed or an unknown version.
    static bool parseFeed(const unsigned char* packet, size_t size);

private:
    struct Pending { uint64_t serial = 0; Waiter wait; uint64_t queue = 0; int64_t watchedMs = 0; };
    struct Record { uint64_t serial; int32_t status; };
    // One watcher thread and the markers it waits for, in submission order.
    struct Lane {
        std::condition_variable changed;
        std::deque<Pending> markers;
        Pending waiting;  // the marker the lane waits for (no waiter), serial 0 when none
        std::thread thread;
    };
    Lane& laneForLocked(uint64_t queue);
    void watcherLoop(Lane& lane);
    void push(uint64_t serial, int32_t status);

    Submit submit_;
    std::mutex mutex_;
    std::vector<std::unique_ptr<Lane>> lanes_;
    std::unordered_map<uint64_t, size_t> laneOfQueue_;  // queues with a lane of their own
    size_t outstanding_ = 0;  // markers queued or waited for, over every lane
    std::deque<Record> records_;
    int wake_[2] = {-1, -1};
    uint64_t generation_ = 0;  // the current feed stream's run; earlier ones return
    bool detached_ = false;
    bool closing_ = false;
    bool attached_ = false;
    uint64_t watches_ = 0, unwatched_ = 0;
    uint64_t lastCompletedSerial_ = 0, lastWrittenSerial_ = 0;
    int32_t lastStatus_ = 0;
    int64_t lastCompletedMs_ = 0, lastWrittenMs_ = 0;
    std::mutex orderMutex_;
    std::condition_variable orderChanged_;
    uint64_t ordered_ = 0;
    bool ordersCancelled_ = false;
};

}  // namespace caboose::gpuv2
