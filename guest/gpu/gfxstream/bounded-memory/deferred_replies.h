// SPDX-License-Identifier: MIT
#pragma once
#include <atomic>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <mutex>
#include <unordered_map>

namespace caboose::memory {

// Commands whose result the caller does not need (flush, fence reset, queue
// submit) are sent without waiting; their 4-byte results stay queued on the
// stream. Every later encoder call drains them before writing its own command,
// so replies are consumed in stream order and only one round-trip is paid.
// A non-success deferred result cannot be returned to its caller any more; it
// is reported once on stderr. A transport failure invalidates the stream.
template<class Stream>
bool drainDeferredReplies(uint32_t& pending, Stream* stream) {
    while (pending) {
        int32_t result = 0;
        if (!stream->tryRead(&result, sizeof(result))) {
            pending = 0;
            stream->invalidate();
            return false;
        }
        --pending;
        if (result != 0) std::fprintf(stderr, "CABOOSE_GPU_DEFERRED_REPLY result=%" PRId32 "\n", result);
    }
    return true;
}

// The device link holds about 1 MiB of unacknowledged data and closes the
// stream beyond it, so deferred commands stay under this many bytes in flight.
inline constexpr uint64_t deferredByteLimit = 960 * 1024;

// Pending replies and their commands' bytes per encoder, kept outside the
// encoder so its layout, which other objects allocate, never changes. Callers
// hold the encoder lock.
class DeferredReplies {
public:
    // Before sending a deferred command of `bytes`, drain if it would exceed the limit.
    template<class Stream>
    bool reserve(const void* encoder, Stream* stream, uint64_t bytes,
                 uint64_t limit = deferredByteLimit) {
        if (!total_.load(std::memory_order_relaxed)) return true;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            auto found = pending_.find(encoder);
            if (found == pending_.end() || found->second.bytes + bytes <= limit) return true;
        }
        return drain(encoder, stream);
    }

    void add(const void* encoder, uint32_t replies, uint64_t bytes) {
        if (!replies) return;
        std::lock_guard<std::mutex> lock(mutex_);
        auto& entry = pending_[encoder];
        entry.replies += replies;
        entry.bytes += bytes;
        total_.fetch_add(replies, std::memory_order_relaxed);
    }

    template<class Stream>
    bool drain(const void* encoder, Stream* stream) {
        if (!total_.load(std::memory_order_relaxed)) return true;
        uint32_t replies = 0;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            auto found = pending_.find(encoder);
            if (found == pending_.end()) return true;
            replies = found->second.replies;
            pending_.erase(found);
            total_.fetch_sub(replies, std::memory_order_relaxed);
        }
        return drainDeferredReplies(replies, stream);
    }

    uint64_t pending() const { return total_.load(std::memory_order_relaxed); }

private:
    struct Entry { uint32_t replies = 0; uint64_t bytes = 0; };
    std::mutex mutex_;
    std::unordered_map<const void*, Entry> pending_;
    std::atomic<uint64_t> total_{0};
};

inline DeferredReplies deferredReplies;

} // namespace caboose::memory
