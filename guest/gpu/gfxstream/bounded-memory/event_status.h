// SPDX-License-Identifier: MIT
#pragma once
// Event status without a round trip when the completion tracker cannot answer
// (README.md, "Events").
//
// An event the tracker does not follow (no completion feed, or a batch the phone could not
// watch) is asked about with a request whose reply is read later with the deferred replies.
// A poll returns what the latest answered request found, VK_EVENT_RESET before any has,
// and sends a fresh request when none is outstanding. A set event stays set without further
// requests until something resets it: the host, or a submitted command buffer that sets or
// resets it, both of which forget what was found.
#include <cstdint>
#include <memory>
#include <mutex>
#include <unordered_map>

#include "query_results.h"

namespace caboose::memory {

class EventStatusReplies {
public:
    static constexpr int32_t kSet = 3, kReset = 4;  // VK_EVENT_SET, VK_EVENT_RESET
    static constexpr size_t kMaxEvents = 4096;

    // The status to report for `event` now, and whether a new request must be sent
    // (request() then records it).
    int32_t poll(uint64_t event, bool* send) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto& entry = entries_[event];
        if (entry.reply && entry.reply->done.load(std::memory_order_acquire)) {
            entry.status = entry.reply->result;
            entry.reply.reset();
        }
        *send = !entry.reply && entry.status != kSet;
        return entry.status;
    }
    void requested(uint64_t event, std::shared_ptr<QueryReply> reply) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!entries_.count(event) && entries_.size() >= kMaxEvents) entries_.erase(entries_.begin());
        entries_[event].reply = std::move(reply);
    }
    // The event changed (a host set or reset, a submitted batch that sets or resets it), or
    // was destroyed: what earlier requests found is stale.
    void forget(uint64_t event) {
        std::lock_guard<std::mutex> lock(mutex_);
        entries_.erase(event);
    }

private:
    struct Entry {
        std::shared_ptr<QueryReply> reply;  // the outstanding request, if any
        int32_t status = kReset;            // what the latest answered request found
    };
    std::mutex mutex_;
    std::unordered_map<uint64_t, Entry> entries_;
};

// Never destroyed: a process's exit runs static destructors while its other threads may
// still be inside the driver.
inline EventStatusReplies& eventStatusReplies = *new EventStatusReplies;

}  // namespace caboose::memory
