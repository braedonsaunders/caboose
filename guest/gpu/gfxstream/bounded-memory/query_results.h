// SPDX-License-Identifier: MIT
#pragma once
// Query results without a round trip (README.md, "Query results").
//
// vkGetQueryPoolResults without VK_QUERY_RESULT_WAIT_BIT may report VK_NOT_READY. The
// first such call sends its request and returns VK_NOT_READY at once; the reply is read
// later with the deferred replies. The next identical call returns what that request
// found, and sends a fresh one. A fetched result is dropped when a reset of an
// overlapping range is recorded, or submitted, or done on the host, so a result from
// before a reset is never reported after it. With the completion feed no request goes out
// while the result cannot be there yet; such a polled range is "wanted", and asked for as
// soon as the batch that ends it completes, so the next poll finds the answer.
#include <atomic>
#include <cstdint>
#include <cstring>
#include <iterator>
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
    static constexpr size_t kMaxEntries = 8192, kMaxRecorded = 1024, kMaxWanted = 1024;
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
    void poolDestroyed(uint64_t pool) {
        reset(pool, 0, UINT32_MAX);
        std::lock_guard<std::mutex> lock(mutex_);
        for (auto it = wanted_.begin(); it != wanted_.end();)
            it = it->first.pool == pool ? wanted_.erase(it) : std::next(it);
    }
    // The application polled `key` (on `device`) before its result could be there.
    void want(const Key& key, uint64_t device) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!wanted_.count(key) && wanted_.size() >= kMaxWanted) wanted_.erase(wanted_.begin());
        wanted_[key] = device;
    }
    // The wanted keys `available(key)` says can be asked for now, with their devices; they
    // are no longer wanted.
    template <class Available>
    std::vector<std::pair<Key, uint64_t>> takeWanted(Available available) {
        std::lock_guard<std::mutex> lock(mutex_);
        std::vector<std::pair<Key, uint64_t>> out;
        for (auto it = wanted_.begin(); it != wanted_.end();) {
            if (available(it->first)) {
                out.push_back(*it);
                it = wanted_.erase(it);
            } else {
                ++it;
            }
        }
        return out;
    }
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
    void commandBufferExecutes(uint64_t primary, const uint64_t* secondaries, uint32_t count) {
        std::lock_guard<std::mutex> lock(mutex_);
        for (uint32_t i = 0; i < count; ++i) {
            auto found = recorded_.find(secondaries[i]);
            if (found == recorded_.end()) continue;
            const auto resets = found->second;
            auto& into = recorded_[primary];
            for (const auto& r : resets) {
                if (into.size() < kMaxRecorded) into.push_back(r);
                else into.back() = {r.pool, 0, UINT32_MAX};
            }
        }
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
    std::map<Key, uint64_t> wanted_;
    std::unordered_map<uint64_t, std::vector<Reset>> recorded_;
};

inline QueryResults queryResults;

}  // namespace caboose::memory
