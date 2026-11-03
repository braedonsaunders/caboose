// SPDX-License-Identifier: MIT
// What a process moves through its device streams, always counted: mapped memory flushed to
// the phone and read back from it, by who asked, the readbacks commands marked, and every
// byte the process's sockets sent and received. Every five seconds in which anything moved,
// the first call after the window ends writes one CABOOSE_GPU_MEMORY_TRAFFIC line.
#pragma once
#include <atomic>
#include <chrono>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <string>

namespace caboose::memory::traffic {

// Who a flush or invalidate is for: the application's own call, or the driver keeping its
// host-coherent memory type coherent (a flush before each submit, an invalidate after waits).
enum Origin : int { application, coherent, kOrigins };
// The commands whose destination buffer the driver reads back after the GPU wrote it.
enum Mark : int { copyImageToBuffer, copyBuffer, copyQueryResults, kMarks };

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
    void marked(Mark mark, uint64_t bytes) { markedBytes_[mark].fetch_add(bytes, std::memory_order_relaxed); }
    void sent(uint64_t bytes) { sentBytes_.fetch_add(bytes, std::memory_order_relaxed); }
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
        const uint64_t sent = sentBytes_.exchange(0, std::memory_order_relaxed);
        const uint64_t received = receivedBytes_.exchange(0, std::memory_order_relaxed);
        if (!moved && !sent && !received) return {};
        char line[768];
        std::snprintf(line, sizeof line,
            "CABOOSE_GPU_MEMORY_TRAFFIC elapsed_ms=%" PRId64 " sent_bytes=%" PRIu64 " received_bytes=%" PRIu64
            " app_flushed_bytes=%" PRIu64 " app_flushes=%" PRIu64
            " coherent_flushed_bytes=%" PRIu64 " coherent_flushes=%" PRIu64
            " app_invalidated_bytes=%" PRIu64 " app_invalidates=%" PRIu64
            " coherent_invalidated_bytes=%" PRIu64 " coherent_invalidates=%" PRIu64
            " largest_invalidate_bytes=%" PRIu64
            " marked_copy_image_bytes=%" PRIu64 " marked_copy_buffer_bytes=%" PRIu64 " marked_query_bytes=%" PRIu64,
            nowMs - start, sent, received,
            flushedBytes[application], flushes[application], flushedBytes[coherent], flushes[coherent],
            invalidatedBytes[application], invalidates[application],
            invalidatedBytes[coherent], invalidates[coherent], largest,
            marked[copyImageToBuffer], marked[copyBuffer], marked[copyQueryResults]);
        return line;
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
    std::atomic<uint64_t> markedBytes_[kMarks]{};
    std::atomic<uint64_t> sentBytes_{0}, receivedBytes_{0};
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
