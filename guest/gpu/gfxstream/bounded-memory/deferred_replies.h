// SPDX-License-Identifier: MIT
#pragma once
#include <algorithm>
#include <atomic>
#include <chrono>
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

// Told how long each drain that had replies to read blocked, in microseconds.
inline void (*drainObserver)(uint64_t us) = nullptr;

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
        entry.replies.back().bytes = bytes;
        entry.bytes += bytes;
        total_.fetch_add(replies, std::memory_order_relaxed);
    }

    // A create whose handle the guest assigned: its reply is the handle and a result.
    void addHandleCreate(const void* encoder, uint64_t handle, uint64_t bytes) {
        addHandleCreates(encoder, handle, 1, bytes);
    }
    // A create of `count` objects whose consecutive handles start at `first`: its reply
    // is those handles, then one result.
    void addHandleCreates(const void* encoder, uint64_t first, uint32_t count, uint64_t bytes) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto& entry = pending_[encoder];
        entry.replies.push_back({0, 0, first, false, count, bytes});
        entry.bytes += bytes;
        total_.fetch_add(1, std::memory_order_relaxed);
    }
    // A command whose failure the application can no longer observe: any failure is device loss.
    void addCheckedResult(const void* encoder, uint64_t bytes) {
        addCheckedResults(encoder, 1, bytes);
    }
    void addCheckedResults(const void* encoder, uint32_t results, uint64_t bytes) {
        if (!results) return;
        std::lock_guard<std::mutex> lock(mutex_);
        auto& entry = pending_[encoder];
        entry.replies.insert(entry.replies.end(), results, Reply{0, 0, 0, true});
        entry.replies.back().bytes = bytes;
        entry.bytes += bytes;
        total_.fetch_add(results, std::memory_order_relaxed);
    }
    void addFenceWait(const void* encoder, uint64_t fence, uint64_t bytes) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto& entry = pending_[encoder];
        entry.replies.push_back({fence, generations_[fence], 0, false, 1, bytes});
        entry.bytes += bytes;
        total_.fetch_add(1, std::memory_order_relaxed);
    }

    template<class Stream>
    bool drain(const void* encoder, Stream* stream) { return drainPrefix(encoder, stream, false); }

    // Reads replies only through the last pending create or submit, so the device has
    // created every object and accepted every submission this encoder sent; later fence
    // waits and plain results stay pending. Used before another channel names them.
    template<class Stream>
    bool drainObjects(const void* encoder, Stream* stream) { return drainPrefix(encoder, stream, true); }

    template<class Stream>
    bool drainPrefix(const void* encoder, Stream* stream, bool objectsOnly) {
        if (!total_.load(std::memory_order_relaxed)) return true;
        std::vector<Reply> replies;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            auto found = pending_.find(encoder);
            if (found == pending_.end()) return true;
            auto& queued = found->second.replies;
            size_t count = queued.size();
            if (objectsOnly) {
                while (count && !queued[count - 1].handle && !queued[count - 1].checked) --count;
                if (!count) return true;
            }
            if (count == queued.size()) {
                replies.swap(queued);
                pending_.erase(found);
            } else {
                replies.assign(queued.begin(), queued.begin() + count);
                queued.erase(queued.begin(), queued.begin() + count);
                uint64_t remaining = 0;
                for (const Reply& reply : queued) remaining += reply.bytes;
                found->second.bytes = remaining;
            }
            total_.fetch_sub(replies.size(), std::memory_order_relaxed);
        }
        struct Observe {
            void (*observer)(uint64_t);
            std::chrono::steady_clock::time_point started;
            ~Observe() {
                if (observer)
                    observer(std::chrono::duration_cast<std::chrono::microseconds>(
                        std::chrono::steady_clock::now() - started).count());
            }
        } observe{drainObserver, drainObserver ? std::chrono::steady_clock::now()
                                               : std::chrono::steady_clock::time_point{}};
        for (const Reply& reply : replies)
            if (!readReply(reply, stream)) return false;
        return true;
    }

    // Reads, without blocking, the leading replies whose bytes have fully arrived;
    // `available()` returns the reply bytes the transport holds unread. Replies stay in
    // order: the first one that has not fully arrived ends the drain.
    template<class Stream, class Available>
    bool drainAvailable(const void* encoder, Stream* stream, Available available) {
        if (!total_.load(std::memory_order_relaxed)) return true;
        size_t ready = available();
        for (;;) {
            Reply reply;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                auto found = pending_.find(encoder);
                if (found == pending_.end()) return true;
                auto& queued = found->second.replies;
                const size_t size = wireSize(queued.front());
                if (size > ready) return true;
                ready -= size;
                reply = queued.front();
                queued.erase(queued.begin());
                found->second.bytes -= std::min(found->second.bytes, reply.bytes);
                if (queued.empty()) pending_.erase(found);
                total_.fetch_sub(1, std::memory_order_relaxed);
            }
            if (!readReply(reply, stream)) return false;
        }
    }

    // True when a prefetched wait for the fence's current generation is still in flight.
    bool prefetchPending(const void* encoder, uint64_t fence) {
        if (!fence || !total_.load(std::memory_order_relaxed)) return false;
        std::lock_guard<std::mutex> lock(mutex_);
        auto found = pending_.find(encoder);
        if (found == pending_.end()) return false;
        auto generation = generations_.find(fence);
        const uint64_t current = generation == generations_.end() ? 0 : generation->second;
        for (const Reply& reply : found->second.replies)
            if (reply.fence == fence && reply.generation == current) return true;
        return false;
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
    struct Reply;
    static size_t wireSize(const Reply& reply) {
        return reply.handle ? size_t(reply.count) * sizeof(uint64_t) + sizeof(int32_t) : sizeof(int32_t);
    }
    template<class Stream>
    bool readReply(const Reply& reply, Stream* stream) {
        if (reply.handle) {
            for (uint32_t i = 0; i < reply.count; ++i) {
                uint64_t created = 0;
                if (!stream->tryRead(&created, sizeof(created))) {
                    stream->invalidate();
                    return false;
                }
                if (created != reply.handle + i) {
                    std::fprintf(stderr, "CABOOSE_GUEST_HANDLE_FAILED handle=0x%" PRIx64 " got=0x%" PRIx64 "\n",
                                 reply.handle + i, created);
                    stream->invalidate();
                    return false;
                }
            }
            int32_t createResult = 0;
            if (!stream->tryRead(&createResult, sizeof(createResult))) {
                stream->invalidate();
                return false;
            }
            if (createResult != 0) {
                // The guest already handed these handles out; a device that refused or
                // renamed them has diverged from the application's view: device loss.
                std::fprintf(stderr, "CABOOSE_GUEST_HANDLE_FAILED handle=0x%" PRIx64 " count=%u result=%" PRId32 "\n",
                             reply.handle, reply.count, createResult);
                stream->invalidate();
                return false;
            }
            return true;
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
            return true;
        }
        if (result != 0) return true;
        std::lock_guard<std::mutex> lock(mutex_);
        auto generation = generations_.find(reply.fence);
        if (generation != generations_.end() && generation->second == reply.generation) {
            signaled_.insert(reply.fence);
            signaledCount_.store(signaled_.size(), std::memory_order_relaxed);
        }
        return true;
    }
    struct Reply { uint64_t fence = 0; uint64_t generation = 0; uint64_t handle = 0; bool checked = false; uint32_t count = 1; uint64_t bytes = 0; };
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
