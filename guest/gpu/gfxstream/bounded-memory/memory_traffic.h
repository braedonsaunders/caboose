// SPDX-License-Identifier: MIT
// What a process moves through its device streams, always counted: mapped memory flushed to
// the phone and read back from it, by who asked, what completion records delivered instead of
// a readback, the readbacks commands marked, every byte
// the process's sockets sent and received, what the coherent upkeep considered sending, what
// the upload cache's pieces went as, and how the flush shadow compared what it sent. Every
// five seconds in which anything moved, the first call after the window ends writes one
// CABOOSE_GPU_MEMORY_TRAFFIC line, followed by a CABOOSE_GPU_MEMORY_ALLOCATION line for each of
// the window's busiest allocations.
#pragma once
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <mutex>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace caboose::memory::traffic {

// Who a flush or invalidate is for: the application's own call, or the driver keeping its
// host-coherent memory type coherent (a flush before each submit, an invalidate after waits).
enum Origin : int { application, coherent, kOrigins };
// The commands whose destination buffer the driver reads back after the GPU wrote it.
enum Mark : int { copyImageToBuffer, copyBuffer, copyQueryResults, kMarks };
// What a 4096-byte piece of an upload-cache range went as (upload_cache.h): nothing, since the
// phone holds it unchanged; a key the phone holds; its bytes for the phone to store.
enum Piece : int { unchangedPiece, namedPiece, storedPiece, kPieces };
// How a flush knew what the host holds (flush_shadow.h): a copy of its bytes, a hash of
// each block, or not at all.
enum Shadow : int { copied, hashed, unshadowed, kShadows };

class Counters {
public:
    static constexpr int64_t kWindowMs = 5000;

    void flushed(Origin origin, uint64_t bytes) {
        flushedBytes_[origin].fetch_add(bytes, std::memory_order_relaxed);
        flushes_[origin].fetch_add(1, std::memory_order_relaxed);
    }
    void invalidated(Origin origin, uint64_t bytes) {
        invalidatedBytes_[origin].fetch_add(bytes, std::memory_order_relaxed);
        invalidates_[origin].fetch_add(1, std::memory_order_relaxed);
        uint64_t largest = largestInvalidate_.load(std::memory_order_relaxed);
        while (bytes > largest &&
               !largestInvalidate_.compare_exchange_weak(largest, bytes, std::memory_order_relaxed)) {}
    }
    // Ranges of GPU-written coherent memory the invalidate after a wait did not read back: the
    // completion record of the batch that wrote them delivered their bytes (completion_feed.h).
    void delivered(uint64_t bytes, uint64_t ranges = 1) {
        deliveredBytes_.fetch_add(bytes, std::memory_order_relaxed);
        deliveries_.fetch_add(ranges, std::memory_order_relaxed);
    }
    // Application invalidates of memory nothing sent since its allocation could have made the
    // device write (device_work.h): answered without reading.
    void unwrittenInvalidates(uint64_t ranges) { unwrittenInvalidates_.fetch_add(ranges, std::memory_order_relaxed); }
    // A range the coherent upkeep flushes: the blocks written since the last flush (`watched`,
    // write_watch.h), or the whole mapping where writes are not recorded.
    void considered(bool watched, uint64_t bytes) {
        (watched ? watchedBytes_ : wholeBytes_).fetch_add(bytes, std::memory_order_relaxed);
    }
    // Bytes a flush sent into memory whose buffers only transfer from it (image uploads).
    void staged(uint64_t bytes) { stagedBytes_.fetch_add(bytes, std::memory_order_relaxed); }
    // A flushed range of `considered` bytes of which the flush shadow sent `sent` in `runs`
    // fragments; `blockBytes` in `blockRuns` fragments would have gone as whole changed 256-byte
    // blocks, and `partial` bytes of hashed blocks went because a range covered only part of
    // them (flush_shadow.h). Kept per allocation too (`allocation`, of `allocationBytes` bytes,
    // whose buffers have the usage flags `usage`) for the window's busiest allocations.
    struct Shadowed {
        Shadow kind = unshadowed;
        uint64_t considered = 0, sent = 0, runs = 0, blockBytes = 0, blockRuns = 0, partial = 0;
        uint64_t allocation = 0, allocationBytes = 0;
        uint32_t usage = 0;
    };
    void shadowed(const Shadowed& s) {
        shadowConsidered_[s.kind].fetch_add(s.considered, std::memory_order_relaxed);
        shadowSent_[s.kind].fetch_add(s.sent, std::memory_order_relaxed);
        shadowRuns_[s.kind].fetch_add(s.runs, std::memory_order_relaxed);
        blockBytes_.fetch_add(s.blockBytes, std::memory_order_relaxed);
        blockRuns_.fetch_add(s.blockRuns, std::memory_order_relaxed);
        partialBytes_.fetch_add(s.partial, std::memory_order_relaxed);
        if (!s.allocation) return;
        std::lock_guard<std::mutex> lock(allocationsMutex_);
        auto found = allocations_.find(s.allocation);
        if (found == allocations_.end()) {
            // Past the bound, the window's further allocations are not kept apart.
            if (allocations_.size() >= kMaxAllocations) return;
            found = allocations_.emplace(s.allocation, Allocation{}).first;
        }
        Allocation& a = found->second;
        a.kind = s.kind; a.bytes = s.allocationBytes; a.usage |= s.usage;
        a.considered += s.considered; a.sent += s.sent; a.runs += s.runs; a.blockBytes += s.blockBytes;
        a.blockRuns += s.blockRuns;
    }
    void shadowed(Shadow kind, uint64_t considered, uint64_t sent) {
        Shadowed s; s.kind = kind; s.considered = considered; s.sent = sent; s.runs = sent ? 1 : 0;
        s.blockBytes = sent; s.blockRuns = s.runs;
        shadowed(s);
    }
    void piece(Piece kind) { pieces_[kind].fetch_add(1, std::memory_order_relaxed); }
    void marked(Mark mark, uint64_t bytes) { markedBytes_[mark].fetch_add(bytes, std::memory_order_relaxed); }
    void sent(uint64_t bytes) { sentBytes_.fetch_add(bytes, std::memory_order_relaxed); }
    // Lazy readback (write_watch.h): bytes an invalidate left to be filled on first use, and
    // the bytes and round trips the fills of first uses read.
    void lazy(uint64_t made, uint64_t filled, uint64_t fills) {
        lazyBytes_.fetch_add(made, std::memory_order_relaxed);
        lazyFilledBytes_.fetch_add(filled, std::memory_order_relaxed);
        lazyFills_.fetch_add(fills, std::memory_order_relaxed);
    }
    void received(uint64_t bytes) { receivedBytes_.fetch_add(bytes, std::memory_order_relaxed); }

    // The line for the window that ended by `nowMs`, once, and empty otherwise: before the
    // window ends, when another thread took it, or when nothing moved in it.
    std::string take(int64_t nowMs) {
        int64_t start = windowStart_.load(std::memory_order_relaxed);
        if (start < 0) {
            windowStart_.compare_exchange_strong(start, nowMs, std::memory_order_relaxed);
            return {};
        }
        if (nowMs - start < kWindowMs ||
            !windowStart_.compare_exchange_strong(start, nowMs, std::memory_order_relaxed)) return {};
        uint64_t flushedBytes[kOrigins], flushes[kOrigins], invalidatedBytes[kOrigins], invalidates[kOrigins];
        uint64_t moved = 0;
        for (int i = 0; i < kOrigins; ++i) {
            flushedBytes[i] = flushedBytes_[i].exchange(0, std::memory_order_relaxed);
            flushes[i] = flushes_[i].exchange(0, std::memory_order_relaxed);
            invalidatedBytes[i] = invalidatedBytes_[i].exchange(0, std::memory_order_relaxed);
            invalidates[i] = invalidates_[i].exchange(0, std::memory_order_relaxed);
            moved += flushedBytes[i] + invalidatedBytes[i];
        }
        uint64_t marked[kMarks];
        for (int i = 0; i < kMarks; ++i) marked[i] = markedBytes_[i].exchange(0, std::memory_order_relaxed);
        const uint64_t largest = largestInvalidate_.exchange(0, std::memory_order_relaxed);
        const uint64_t deliveredBytes = deliveredBytes_.exchange(0, std::memory_order_relaxed);
        const uint64_t deliveries = deliveries_.exchange(0, std::memory_order_relaxed);
        moved += deliveredBytes;
        const uint64_t lazyBytes = lazyBytes_.exchange(0, std::memory_order_relaxed);
        const uint64_t lazyFilled = lazyFilledBytes_.exchange(0, std::memory_order_relaxed);
        const uint64_t lazyFills = lazyFills_.exchange(0, std::memory_order_relaxed);
        moved += lazyBytes + lazyFilled;
        const uint64_t unwritten = unwrittenInvalidates_.exchange(0, std::memory_order_relaxed);
        moved += unwritten;
        const uint64_t sent = sentBytes_.exchange(0, std::memory_order_relaxed);
        const uint64_t received = receivedBytes_.exchange(0, std::memory_order_relaxed);
        const uint64_t watched = watchedBytes_.exchange(0, std::memory_order_relaxed);
        const uint64_t whole = wholeBytes_.exchange(0, std::memory_order_relaxed);
        const uint64_t staged = stagedBytes_.exchange(0, std::memory_order_relaxed);
        uint64_t pieces[kPieces];
        for (int i = 0; i < kPieces; ++i) pieces[i] = pieces_[i].exchange(0, std::memory_order_relaxed);
        uint64_t considered[kShadows], shadowSent[kShadows];
        for (int i = 0; i < kShadows; ++i) {
            considered[i] = shadowConsidered_[i].exchange(0, std::memory_order_relaxed);
            shadowSent[i] = shadowSent_[i].exchange(0, std::memory_order_relaxed);
        }
        uint64_t shadowRuns[kShadows];
        for (int i = 0; i < kShadows; ++i) shadowRuns[i] = shadowRuns_[i].exchange(0, std::memory_order_relaxed);
        const uint64_t blockBytes = blockBytes_.exchange(0, std::memory_order_relaxed);
        const uint64_t blockRuns = blockRuns_.exchange(0, std::memory_order_relaxed);
        const uint64_t partial = partialBytes_.exchange(0, std::memory_order_relaxed);
        std::vector<std::pair<uint64_t, Allocation>> busiest;
        {
            std::lock_guard<std::mutex> lock(allocationsMutex_);
            busiest.assign(allocations_.begin(), allocations_.end());
            allocations_.clear();
        }
        for (int i = 0; i < kShadows; ++i) moved += considered[i];
        moved += watched + whole + staged;
        if (!moved && !sent && !received) return {};
        char line[4096];
        std::snprintf(line, sizeof line,
            "CABOOSE_GPU_MEMORY_TRAFFIC elapsed_ms=%" PRId64 " sent_bytes=%" PRIu64 " received_bytes=%" PRIu64
            " app_flushed_bytes=%" PRIu64 " app_flushes=%" PRIu64
            " coherent_flushed_bytes=%" PRIu64 " coherent_flushes=%" PRIu64
            " app_invalidated_bytes=%" PRIu64 " app_invalidates=%" PRIu64
            " coherent_invalidated_bytes=%" PRIu64 " coherent_invalidates=%" PRIu64
            " coherent_delivered_bytes=%" PRIu64 " coherent_delivered=%" PRIu64
            " largest_invalidate_bytes=%" PRIu64
            " marked_copy_image_bytes=%" PRIu64 " marked_copy_buffer_bytes=%" PRIu64 " marked_query_bytes=%" PRIu64
            " coherent_watched_bytes=%" PRIu64 " coherent_whole_bytes=%" PRIu64 " staging_flushed_bytes=%" PRIu64
            " pieces_unchanged=%" PRIu64 " pieces_named=%" PRIu64 " pieces_stored=%" PRIu64
            " copied_considered_bytes=%" PRIu64 " copied_sent_bytes=%" PRIu64
            " hashed_considered_bytes=%" PRIu64 " hashed_sent_bytes=%" PRIu64 " unshadowed_bytes=%" PRIu64
            " lazy_bytes=%" PRIu64 " lazy_filled_bytes=%" PRIu64 " lazy_fills=%" PRIu64
            " app_unwritten_invalidates=%" PRIu64
            " copied_runs=%" PRIu64 " hashed_runs=%" PRIu64 " unshadowed_runs=%" PRIu64
            " block_bytes=%" PRIu64 " block_runs=%" PRIu64 " hashed_partial_bytes=%" PRIu64,
            nowMs - start, sent, received,
            flushedBytes[application], flushes[application], flushedBytes[coherent], flushes[coherent],
            invalidatedBytes[application], invalidates[application],
            invalidatedBytes[coherent], invalidates[coherent], deliveredBytes, deliveries, largest,
            marked[copyImageToBuffer], marked[copyBuffer], marked[copyQueryResults],
            watched, whole, staged, pieces[unchangedPiece], pieces[namedPiece], pieces[storedPiece],
            considered[copied], shadowSent[copied], considered[hashed], shadowSent[hashed], considered[unshadowed],
            lazyBytes, lazyFilled, lazyFills, unwritten,
            shadowRuns[copied], shadowRuns[hashed], shadowRuns[unshadowed], blockBytes, blockRuns, partial);
        std::string text = line;
        // The busiest allocations by bytes sent: kind, size, buffer usage, and the same counts.
        const size_t shown = busiest.size() < kShownAllocations ? busiest.size() : kShownAllocations;
        std::partial_sort(busiest.begin(), busiest.begin() + shown, busiest.end(),
                          [](const auto& a, const auto& b) { return a.second.sent > b.second.sent; });
        static const char* const kinds[kShadows] = {"copied", "hashed", "unshadowed"};
        for (size_t i = 0; i < shown && busiest[i].second.sent; ++i) {
            const Allocation& a = busiest[i].second;
            std::snprintf(line, sizeof line,
                "\nCABOOSE_GPU_MEMORY_ALLOCATION rank=%zu shadow=%s bytes=%" PRIu64 " usage=0x%x considered_bytes=%" PRIu64
                " sent_bytes=%" PRIu64 " runs=%" PRIu64 " block_bytes=%" PRIu64 " block_runs=%" PRIu64,
                i + 1, kinds[a.kind], a.bytes, a.usage, a.considered, a.sent, a.runs, a.blockBytes, a.blockRuns);
            text += line;
        }
        return text;
    }

    // Writes the ended window's line to standard error.
    void report() {
        const auto line = take(std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count());
        if (line.empty()) return;
        std::fprintf(stderr, "%s\n", line.c_str());
        std::fflush(stderr);
    }

private:
    std::atomic<uint64_t> flushedBytes_[kOrigins]{}, flushes_[kOrigins]{};
    std::atomic<uint64_t> invalidatedBytes_[kOrigins]{}, invalidates_[kOrigins]{};
    std::atomic<uint64_t> largestInvalidate_{0};
    std::atomic<uint64_t> deliveredBytes_{0}, deliveries_{0}, unwrittenInvalidates_{0};
    std::atomic<uint64_t> lazyBytes_{0}, lazyFilledBytes_{0}, lazyFills_{0};
    std::atomic<uint64_t> markedBytes_[kMarks]{};
    std::atomic<uint64_t> sentBytes_{0}, receivedBytes_{0};
    std::atomic<uint64_t> watchedBytes_{0}, wholeBytes_{0}, stagedBytes_{0};
    std::atomic<uint64_t> pieces_[kPieces]{};
    std::atomic<uint64_t> shadowConsidered_[kShadows]{}, shadowSent_[kShadows]{}, shadowRuns_[kShadows]{};
    std::atomic<uint64_t> blockBytes_{0}, blockRuns_{0}, partialBytes_{0};
    struct Allocation {
        Shadow kind = unshadowed;
        uint64_t bytes = 0, considered = 0, sent = 0, runs = 0, blockBytes = 0, blockRuns = 0;
        uint32_t usage = 0;
    };
    static constexpr size_t kMaxAllocations = 1024, kShownAllocations = 8;
    std::mutex allocationsMutex_;
    std::unordered_map<uint64_t, Allocation> allocations_;
    std::atomic<int64_t> windowStart_{-1};
};

inline Counters& counters() {
    static Counters instance;
    return instance;
}

// Set while the driver's coherent upkeep flushes or invalidates, so the encoder's flush and
// invalidate count those bytes as the driver's rather than the application's.
inline thread_local bool coherentUpkeep = false;
struct CoherentUpkeep {
    bool previous;
    CoherentUpkeep() : previous(coherentUpkeep) { coherentUpkeep = true; }
    ~CoherentUpkeep() { coherentUpkeep = previous; }
};
inline Origin currentOrigin() { return coherentUpkeep ? coherent : application; }

}  // namespace caboose::memory::traffic
