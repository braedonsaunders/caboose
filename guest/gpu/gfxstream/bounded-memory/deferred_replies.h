// SPDX-License-Identifier: MIT
#pragma once
#include <atomic>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <mutex>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace caboose::memory {
inline thread_local uint32_t lastOpcode = 0;

// Commands whose result the caller does not need (memory flush, fence reset)
// are sent without waiting; their 4-byte results stay queued on the stream.
// Every later encoder call drains them before it reads its own reply, so
// replies are consumed in stream order and only one round-trip is paid.
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

// A fence wait sent right after the submit that signals the fence, so its
// result arrives while the caller presents. Bounded so a fence that depends on
// later commands stalls the device stream briefly instead of forever.
inline constexpr uint64_t prefetchedFenceWaitNs = 250'000'000;

// Set while the encoder sends a prefetched fence wait instead of a real one.
inline thread_local bool sendingPrefetchedFenceWait = false;

// Pending replies and their commands' bytes per encoder. Callers
// hold the encoder lock. A prefetched fence wait that succeeds records its
// fence as signaled until the fence is reset, destroyed or imported; the
// fence's generation discards prefetches that complete after such a change.
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
        entry.replies.insert(entry.replies.end(), replies, Reply{});
        entry.bytes += bytes;
        total_.fetch_add(replies, std::memory_order_relaxed);
    }

    // A create whose handle the guest assigned: its reply is the handle and a result.
    void addHandleCreate(const void* encoder, uint64_t handle, uint64_t bytes) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto& entry = pending_[encoder];
        entry.replies.push_back({0, 0, handle});
        entry.bytes += bytes;
        total_.fetch_add(1, std::memory_order_relaxed);
    }
    // A command whose failure the application can no longer observe: any failure is device loss.
    void addCheckedResult(const void* encoder, uint64_t bytes) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto& entry = pending_[encoder];
        entry.replies.push_back({0, 0, 0, true});
        entry.bytes += bytes;
        total_.fetch_add(1, std::memory_order_relaxed);
    }
    void addFenceWait(const void* encoder, uint64_t fence, uint64_t bytes) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto& entry = pending_[encoder];
        entry.replies.push_back({fence, generations_[fence]});
        entry.bytes += bytes;
        total_.fetch_add(1, std::memory_order_relaxed);
    }

    template<class Stream>
    bool drain(const void* encoder, Stream* stream) {
        if (!total_.load(std::memory_order_relaxed)) return true;
        std::vector<Reply> replies;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            auto found = pending_.find(encoder);
            if (found == pending_.end()) return true;
            replies.swap(found->second.replies);
            pending_.erase(found);
            total_.fetch_sub(replies.size(), std::memory_order_relaxed);
        }
        for (const Reply& reply : replies) {
            if (reply.handle) {
                uint64_t created = 0;
                int32_t createResult = 0;
                if (!stream->tryRead(&created, sizeof(created)) ||
                    !stream->tryRead(&createResult, sizeof(createResult))) {
                    stream->invalidate();
                    return false;
                }
                if (created != reply.handle || createResult != 0) {
                    // The guest already handed this handle out; a device that refused or
                    // renamed it has diverged from the application's view: device loss.
                    std::fprintf(stderr, "CABOOSE_GUEST_HANDLE_FAILED handle=0x%" PRIx64 " got=0x%" PRIx64 " result=%" PRId32 "\n",
                                 reply.handle, created, createResult);
                    stream->invalidate();
                    return false;
                }
                continue;
            }
            int32_t result = 0;
            if (!stream->tryRead(&result, sizeof(result))) {
                stream->invalidate();
                return false;
            }
            if (!reply.fence) {
                if (result != 0) std::fprintf(stderr, "CABOOSE_GPU_DEFERRED_REPLY result=%" PRId32 "\n", result);
                if (result != 0 && reply.checked) {
                    stream->invalidate();
                    return false;
                }
                continue;
            }
            if (result != 0) continue;
            std::lock_guard<std::mutex> lock(mutex_);
            auto generation = generations_.find(reply.fence);
            if (generation != generations_.end() && generation->second == reply.generation) {
                signaled_.insert(reply.fence);
                signaledCount_.store(signaled_.size(), std::memory_order_relaxed);
            }
        }
        return true;
    }

    // True when the fences are known signaled: all of them, or any if !waitAll.
    template<class Handle>
    bool signaled(const Handle* fences, uint32_t count, bool waitAll) {
        if (!count || !signaledCount_.load(std::memory_order_relaxed)) return false;
        std::lock_guard<std::mutex> lock(mutex_);
        uint32_t known = 0;
        for (uint32_t i = 0; i < count; ++i)
            known += signaled_.count(uint64_t(uintptr_t(fences[i]))) ? 1 : 0;
        return waitAll ? known == count : known > 0;
    }

    void markSignaled(uint64_t fence) {
        if (!fence) return;
        std::lock_guard<std::mutex> lock(mutex_);
        signaled_.insert(fence);
        signaledCount_.store(signaled_.size(), std::memory_order_relaxed);
    }

    // The fence is reset, destroyed or imported: drop its known result and any
    // prefetch in flight. Generations are kept so a reused handle cannot match.
    void forgetFence(uint64_t fence) {
        if (!fence) return;
        std::lock_guard<std::mutex> lock(mutex_);
        signaled_.erase(fence);
        signaledCount_.store(signaled_.size(), std::memory_order_relaxed);
        ++generations_[fence];
    }

    bool singleEncoder(const void* encoder) {
        if (multiEncoder_.load(std::memory_order_relaxed)) return false;
        const void* first = firstEncoder_.load(std::memory_order_relaxed);
        if (first == encoder) return true;
        if (first == nullptr &&
            firstEncoder_.compare_exchange_strong(first, encoder, std::memory_order_relaxed)) {
            return true;
        }
        if (!multiEncoder_.exchange(true, std::memory_order_relaxed))
            std::fprintf(stderr, "CABOOSE_MULTI_ENCODER first=%p second=%p opcode=%u\n", first, encoder, lastOpcode);
        return false;
    }

    uint64_t pending() const { return total_.load(std::memory_order_relaxed); }

private:
    struct Reply { uint64_t fence = 0; uint64_t generation = 0; uint64_t handle = 0; bool checked = false; };
    struct Entry { std::vector<Reply> replies; uint64_t bytes = 0; };
    std::mutex mutex_;
    std::unordered_map<const void*, Entry> pending_;
    std::unordered_map<uint64_t, uint64_t> generations_;
    std::unordered_set<uint64_t> signaled_;
    std::atomic<const void*> firstEncoder_{nullptr};
    std::atomic<bool> multiEncoder_{false};
    std::atomic<uint64_t> total_{0};
    std::atomic<size_t> signaledCount_{0};
};

inline DeferredReplies deferredReplies;

} // namespace caboose::memory
