#pragma once
// SPDX-License-Identifier: MIT
//
// What this process has sent that can make the device write memory: every queue command
// (submissions, sparse binds, command flushes) and the host-side copies, builds and layout
// transitions that write without a queue. Two questions are answered from it without asking the
// device:
//
//  - Has `memory` been written by the device since it was allocated? Not when nothing that
//    writes was sent since: its mapped bytes are then what this process put there (the device's
//    contents of new memory are undefined), so an invalidate of it reads nothing.
//  - Is `queue` idle? Yes when nothing was sent to it since the device last reported it idle,
//    or ever: a vkQueueWaitIdle then has nothing to wait for.
//
// Both only ever answer "nothing happened" for what provably did not: a command counted that
// writes nothing makes an answer ask the device as before.

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <mutex>
#include <unordered_map>

namespace caboose::memory {

class DeviceWork {
public:
    // A command that may make the device write memory, sent on no queue.
    void sent() { epoch_.fetch_add(1, std::memory_order_acq_rel); }
    // A command sent to `queue`.
    void sentOn(uint64_t queue) {
        sent();
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = queues_.find(queue);
        if (it == queues_.end()) {
            if (queues_.size() >= kMaxQueues) {
                untracked_ = true;
                return;
            }
            it = queues_.emplace(queue, Queue{}).first;
        }
        ++it->second.sent;
    }
    // A value that changes whenever a command that may write is sent.
    uint64_t epoch() const { return epoch_.load(std::memory_order_acquire); }
    // Whether nothing that may write was sent since epoch() returned `since`.
    bool unchangedSince(uint64_t since) const { return since != kNever && epoch() == since; }
    // The commands sent to `queue` so far: what an idle wait sent now covers.
    uint64_t sentTo(uint64_t queue) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = queues_.find(queue);
        return it == queues_.end() ? 0 : it->second.sent;
    }
    // The device reported `queue` idle for a wait sent after `through` of its commands.
    void idle(uint64_t queue, uint64_t through) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = queues_.find(queue);
        if (it == queues_.end()) return;
        it->second.idle = std::max(it->second.idle, through);
    }
    // Whether `queue` has had nothing sent to it since the device last reported it idle.
    bool idleNow(uint64_t queue) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (untracked_) return false;
        auto it = queues_.find(queue);
        return it == queues_.end() || it->second.sent == it->second.idle;
    }

    // An epoch no memory is unchanged since: its contents are never assumed.
    static constexpr uint64_t kNever = ~0ull;
    static constexpr size_t kMaxQueues = 1024;

private:
    struct Queue {
        uint64_t sent = 0;
        uint64_t idle = 0;
    };
    std::atomic<uint64_t> epoch_{0};
    std::mutex mutex_;
    std::unordered_map<uint64_t, Queue> queues_;
    // More queues than are kept: none is known idle.
    bool untracked_ = false;
};

inline DeviceWork deviceWork;

}  // namespace caboose::memory
