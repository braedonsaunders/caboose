// SPDX-License-Identifier: MIT
#pragma once
// Query results without a round trip (README.md, "Query results").
//
// vkGetQueryPoolResults without VK_QUERY_RESULT_WAIT_BIT may report VK_NOT_READY. The
// first such call sends its request and returns VK_NOT_READY at once; the reply is read
// later with the deferred replies. The next identical call returns what that request
// found, and sends a fresh one. A fetched result is dropped when a reset of an
// overlapping range is recorded, or submitted, or done on the host, so a result from
// before a reset is never reported after it.
#include <atomic>
#include <cstdint>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <tuple>
#include <unordered_map>
#include <vector>

namespace caboose::memory {

// One request's reply, filled when the deferred replies reach it.
struct QueryReply {
    std::vector<uint8_t> data;
    int32_t result = 0;
    std::atomic<bool> done{false};
};

class QueryResults {
public:
    static constexpr size_t kMaxEntries = 8192, kMaxRecorded = 1024;
    struct Key {
        uint64_t pool; uint32_t first, count; uint64_t size, stride; uint32_t flags;
        bool operator<(const Key& o) const {
            return std::tie(pool, first, count, size, stride, flags) <
                   std::tie(o.pool, o.first, o.count, o.size, o.stride, o.flags);
        }
    };
    // The reply of an earlier request for `key`, if it has arrived and is still valid; it
    // is taken. Otherwise nullptr, and `pending` tells whether a request is outstanding.
    std::shared_ptr<QueryReply> take(const Key& key, bool* pending) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto found = entries_.find(key);
        *pending = false;
        if (found == entries_.end()) return nullptr;
        if (!found->second->done.load(std::memory_order_acquire)) { *pending = true; return nullptr; }
        auto reply = found->second;
        entries_.erase(found);
        return reply;
    }
    void requested(const Key& key, std::shared_ptr<QueryReply> reply) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!entries_.count(key) && entries_.size() >= kMaxEntries) {
            auto victim = entries_.end();
            for (auto it = entries_.begin(); it != entries_.end(); ++it) {
                if (it->second->done.load(std::memory_order_relaxed)) {
                    victim = it;
                    break;
                }
            }
            entries_.erase(victim != entries_.end() ? victim : entries_.begin());
        }
        entries_[key] = std::move(reply);
    }
    // Queries [first, first+count) of `pool` were reset: results fetched before are stale.
    void reset(uint64_t pool, uint32_t first, uint32_t count) {
        std::lock_guard<std::mutex> lock(mutex_);
        resetLocked(pool, first, count);
    }
    void poolDestroyed(uint64_t pool) { reset(pool, 0, UINT32_MAX); }
    // A command buffer records a reset; it applies again whenever the buffer is submitted.
    void recordReset(uint64_t commandBuffer, uint64_t pool, uint32_t first, uint32_t count) {
        std::lock_guard<std::mutex> lock(mutex_);
        resetLocked(pool, first, count);
        auto& list = recorded_[commandBuffer];
        if (list.size() < kMaxRecorded) list.push_back({pool, first, count});
        else list.back() = {pool, 0, UINT32_MAX};  // overflow: the whole pool, conservatively
    }
    void commandBufferBegun(uint64_t commandBuffer) {
        std::lock_guard<std::mutex> lock(mutex_);
        recorded_.erase(commandBuffer);
    }
    void submitted(uint64_t commandBuffer) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto found = recorded_.find(commandBuffer);
        if (found == recorded_.end()) return;
        for (const auto& r : found->second) resetLocked(r.pool, r.first, r.count);
    }

private:
    struct Reset { uint64_t pool; uint32_t first, count; };
    void resetLocked(uint64_t pool, uint32_t first, uint32_t count) {
        const uint64_t end = uint64_t(first) + count;
        for (auto it = entries_.begin(); it != entries_.end();) {
            const auto& k = it->first;
            if (k.pool == pool && k.first < end && first < uint64_t(k.first) + k.count) it = entries_.erase(it);
            else ++it;
        }
    }
    std::mutex mutex_;
    std::map<Key, std::shared_ptr<QueryReply>> entries_;
    std::unordered_map<uint64_t, std::vector<Reset>> recorded_;
};

inline QueryResults queryResults;

}  // namespace caboose::memory
