// SPDX-License-Identifier: MIT
#pragma once
// Frees held until the GPU work sent before them has completed (README.md, "Deferred
// frees").
//
// An application frees memory, or destroys a buffer, image or view, once the work it knows
// to use the object has completed. On the phone, work still running on any queue of the
// device can hold the object resident (a descriptor set bound in an argument buffer, a
// chunk-sized buffer under suballocations), and releasing it under that work loses the
// device. So with the completion feed each such destroy is held until every queue
// submission the process sent before it has completed: it carries the latest watch serial
// at the time, and is sent once no watch up to that serial is outstanding. A queue whose
// latest submissions no watch follows gets one first, so every submission is covered.
#include <cstdint>
#include <deque>
#include <iterator>
#include <mutex>
#include <unordered_map>
#include <vector>

namespace caboose::memory {

class DeferredDestroys {
public:
    // Held destroys beyond this wait for the oldest to become ready.
    static constexpr size_t kLimit = 8192;

    // One destroy, as sent: its opcode and the host's device and object handles. `memory` is
    // the guest key of freed device memory, whose allocation budget is released when the free
    // is sent (async_allocation.h), or 0.
    struct Destroy {
        uint32_t opcode = 0;
        uint64_t device = 0, handle = 0, memory = 0;
    };
    struct Queue {
        uint64_t queue = 0, hostQueue = 0, device = 0;
    };
    struct Taken {
        std::vector<Destroy> send;     // ready, in the order they were held
        std::vector<Destroy> dropped;  // held under an executor that is gone: never sent
    };

    // A submission to `queue` that no completion watch follows.
    void submittedUnwatched(uint64_t queue, uint64_t hostQueue, uint64_t device) {
        std::lock_guard<std::mutex> lock(mutex_);
        unwatched_[queue] = Queue{queue, hostQueue, device};
    }
    // A watch was sent on `queue` after its latest submission.
    void watched(uint64_t queue) {
        std::lock_guard<std::mutex> lock(mutex_);
        unwatched_.erase(queue);
    }
    // The queues whose latest submissions no watch follows; they count as watched from now.
    std::vector<Queue> takeUnwatched() {
        std::lock_guard<std::mutex> lock(mutex_);
        std::vector<Queue> out;
        out.reserve(unwatched_.size());
        for (const auto& entry : unwatched_) out.push_back(entry.second);
        unwatched_.clear();
        return out;
    }
    // The device of these queues (its guest key) is destroyed: its queues need no watch.
    void deviceDestroyed(uint64_t device) {
        std::lock_guard<std::mutex> lock(mutex_);
        for (auto it = unwatched_.begin(); it != unwatched_.end();)
            it = it->second.device == device ? unwatched_.erase(it) : std::next(it);
    }

    // Holds `destroy` until every watch up to `serial` has completed; `generation` names the
    // executor connection it was asked under.
    void hold(uint64_t serial, uint64_t generation, const Destroy& destroy) {
        std::lock_guard<std::mutex> lock(mutex_);
        held_.push_back(Held{serial, generation, destroy});
    }
    // The held destroys that may be sent now: those whose serial is below `outstandingFrom`,
    // the oldest watch serial still outstanding, in order. Any of `device` is taken whatever
    // its serial (the device is being destroyed, so it is idle). Destroys held under another
    // `generation` are dropped.
    Taken take(uint64_t outstandingFrom, uint64_t generation, uint64_t device = 0) {
        Taken out;
        std::lock_guard<std::mutex> lock(mutex_);
        if (held_.empty()) return out;
        std::deque<Held> keep;
        bool blocked = false;  // a held destroy that stays keeps every later one behind it
        for (auto& entry : held_) {
            if (entry.generation != generation) {
                out.dropped.push_back(entry.destroy);
            } else if (device && entry.destroy.device == device) {
                out.send.push_back(entry.destroy);
            } else if (!blocked && entry.serial < outstandingFrom) {
                out.send.push_back(entry.destroy);
            } else {
                blocked = true;
                keep.push_back(entry);
            }
        }
        held_.swap(keep);
        return out;
    }
    size_t size() {
        std::lock_guard<std::mutex> lock(mutex_);
        return held_.size();
    }
    bool empty() { return size() == 0; }
    // The serial the oldest held destroy waits for, or 0 when none is held.
    uint64_t oldestSerial() {
        std::lock_guard<std::mutex> lock(mutex_);
        return held_.empty() ? 0 : held_.front().serial;
    }

private:
    struct Held {
        uint64_t serial, generation;
        Destroy destroy;
    };
    std::mutex mutex_;
    std::deque<Held> held_;
    std::unordered_map<uint64_t, Queue> unwatched_;
};

// Never destroyed: a process's exit runs static destructors while its other threads may
// still be inside the driver.
inline DeferredDestroys& deferredDestroys = *new DeferredDestroys;

}  // namespace caboose::memory
