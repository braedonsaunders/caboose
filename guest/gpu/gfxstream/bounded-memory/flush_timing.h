// SPDX-License-Identifier: MIT
#pragma once
#include <chrono>
#include <cinttypes>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <utility>

namespace caboose::memory {

inline void saturateAdd(uint64_t& dst, uint64_t delta) noexcept {
    if (delta <= UINT64_MAX - dst) dst += delta;
    else dst = UINT64_MAX;
}

struct FlushDurationSample {
    uint64_t count = 0;
    uint64_t sum_us = 0;
    uint64_t max_us = 0;

    void add(uint64_t elapsed_us) noexcept {
        saturateAdd(count, 1u);
        saturateAdd(sum_us, elapsed_us);
        if (elapsed_us > max_us) max_us = elapsed_us;
    }

    void merge(const FlushDurationSample& other) noexcept {
        saturateAdd(count, other.count);
        saturateAdd(sum_us, other.sum_us);
        if (other.max_us > max_us) max_us = other.max_us;
    }
};

struct FlushCallRecord {
    uint64_t range_count = 0;
    uint64_t elapsed_us = 0;
    int result = -4;
    unsigned transport_failed = 0;
    uint64_t windows = 0;
    uint64_t send_bytes = 0;
    FlushDurationSample send{};
    // First tryRead of each FlushWindow drain flushes buffered IOStream socket
    // writes (m_buf commit) and then waits for the first 4-byte VkResult reply.
    // It is not a pure network RTT measurement.
    FlushDurationSample first_read_write_wait{};
    FlushDurationSample rest_read_wait{};
    bool draining_window = false;

    void recordSend(uint64_t payload_bytes, uint64_t call_us, int send_result) noexcept {
        draining_window = false;
        send.add(call_us);
        if (send_result == 0) {
            saturateAdd(send_bytes, payload_bytes);
        } else {
            transport_failed = 1u;
            result = send_result;
        }
    }

    void recordRead(uint64_t call_us, bool read_ok, int reply_result) noexcept {
        if (!draining_window) {
            draining_window = true;
            saturateAdd(windows, 1u);
            first_read_write_wait.add(call_us);
        } else {
            rest_read_wait.add(call_us);
        }
        if (!read_ok) {
            transport_failed = 1u;
            result = -4;
        } else if (result == 0 && reply_result != 0) {
            result = reply_result;
        }
    }

    void recordInvalidate() noexcept {
        transport_failed = 1u;
    }
};

struct FlushTimingTotals {
    uint64_t calls = 0;
    uint64_t errors = 0;
    uint64_t transport_failures = 0;
    uint64_t ranges = 0;
    uint64_t windows = 0;
    uint64_t send_bytes = 0;
    uint64_t elapsed_sum_us = 0;
    uint64_t elapsed_max_us = 0;
    FlushDurationSample send{};
    FlushDurationSample first_read_write_wait{};
    FlushDurationSample rest_read_wait{};

    void accumulate(const FlushCallRecord& call) noexcept {
        saturateAdd(calls, 1u);
        if (call.result != 0) saturateAdd(errors, 1u);
        if (call.transport_failed != 0) saturateAdd(transport_failures, 1u);
        saturateAdd(ranges, call.range_count);
        saturateAdd(windows, call.windows);
        saturateAdd(send_bytes, call.send_bytes);
        saturateAdd(elapsed_sum_us, call.elapsed_us);
        if (call.elapsed_us > elapsed_max_us) elapsed_max_us = call.elapsed_us;
        send.merge(call.send);
        first_read_write_wait.merge(call.first_read_write_wait);
        rest_read_wait.merge(call.rest_read_wait);
    }
};

template<unsigned Limit = 128>
class FlushTimingCollector {
public:
    static constexpr unsigned kLimit = Limit;

    template<class Emit>
    void recordWith(const FlushCallRecord& call, Emit&& emit) noexcept {
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            totals_.accumulate(call);
            const unsigned ordinal = emitted_ <= Limit ? emitted_++ : Limit + 1u;
            if (ordinal <= Limit) {
                emit(ordinal, call, totals_);
            }
        } catch (...) {}
    }

    void record(const FlushCallRecord& call) noexcept {
        recordWith(call, [](unsigned ordinal, const FlushCallRecord& rec, const FlushTimingTotals& tot) noexcept {
            if (ordinal < Limit) {
                std::fprintf(
                    stderr,
                    "CABOOSE_GPU_FLUSH_TIMING ordinal=%u result=%d transport_failed=%u "
                    "ranges=%" PRIu64 " windows=%" PRIu64 " elapsed_us=%" PRIu64 " "
                    "send_count=%" PRIu64 " send_bytes=%" PRIu64 " send_sum_us=%" PRIu64 " send_max_us=%" PRIu64 " "
                    "first_read_write_wait_count=%" PRIu64 " first_read_write_wait_sum_us=%" PRIu64 " first_read_write_wait_max_us=%" PRIu64 " "
                    "rest_read_wait_count=%" PRIu64 " rest_read_wait_sum_us=%" PRIu64 " rest_read_wait_max_us=%" PRIu64 " "
                    "total_calls=%" PRIu64 " total_errors=%" PRIu64 " total_transport_failures=%" PRIu64 " "
                    "total_ranges=%" PRIu64 " total_windows=%" PRIu64 " total_send_count=%" PRIu64 " total_send_bytes=%" PRIu64 " "
                    "total_send_sum_us=%" PRIu64 " total_first_read_write_wait_sum_us=%" PRIu64 " "
                    "total_rest_read_wait_sum_us=%" PRIu64 " total_elapsed_sum_us=%" PRIu64 "\n",
                    ordinal, rec.result, rec.transport_failed,
                    rec.range_count, rec.windows, rec.elapsed_us,
                    rec.send.count, rec.send_bytes, rec.send.sum_us, rec.send.max_us,
                    rec.first_read_write_wait.count, rec.first_read_write_wait.sum_us, rec.first_read_write_wait.max_us,
                    rec.rest_read_wait.count, rec.rest_read_wait.sum_us, rec.rest_read_wait.max_us,
                    tot.calls, tot.errors, tot.transport_failures,
                    tot.ranges, tot.windows, tot.send.count, tot.send_bytes,
                    tot.send.sum_us, tot.first_read_write_wait.sum_us,
                    tot.rest_read_wait.sum_us, tot.elapsed_sum_us);
                std::fflush(stderr);
            } else if (ordinal == Limit) {
                std::fprintf(
                    stderr,
                    "CABOOSE_GPU_FLUSH_TIMING limit=%u total_calls=%" PRIu64 " total_errors=%" PRIu64 " "
                    "total_transport_failures=%" PRIu64 " total_ranges=%" PRIu64 " total_windows=%" PRIu64 " "
                    "total_send_count=%" PRIu64 " total_send_bytes=%" PRIu64 " total_send_sum_us=%" PRIu64 " "
                    "total_first_read_write_wait_sum_us=%" PRIu64 " total_rest_read_wait_sum_us=%" PRIu64 " "
                    "total_elapsed_sum_us=%" PRIu64 "\n",
                    Limit, tot.calls, tot.errors, tot.transport_failures,
                    tot.ranges, tot.windows, tot.send.count, tot.send_bytes,
                    tot.send.sum_us, tot.first_read_write_wait.sum_us,
                    tot.rest_read_wait.sum_us, tot.elapsed_sum_us);
                std::fflush(stderr);
            }
        });
    }

    FlushTimingTotals totals() const noexcept {
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            return totals_;
        } catch (...) {
            return {};
        }
    }

    unsigned emitted() const noexcept {
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            return emitted_;
        } catch (...) {
            return 0;
        }
    }

private:
    mutable std::mutex mutex_;
    unsigned emitted_ = 0;
    FlushTimingTotals totals_{};
};

inline uint64_t steadyFlushMicros() noexcept {
    const auto now = std::chrono::steady_clock::now().time_since_epoch();
    const auto us = std::chrono::duration_cast<std::chrono::microseconds>(now).count();
    return us > 0 ? static_cast<uint64_t>(us) : 0u;
}

inline bool flushTimingEnabled() noexcept {
    static const bool enabled = []() noexcept {
        const char* value = std::getenv("CABOOSE_PRIVATE_GPU_FLUSH_TIMING");
        return value && std::strcmp(value, "1") == 0;
    }();
    return enabled;
}

inline FlushTimingCollector<128>& processFlushTimingCollector() noexcept {
    static FlushTimingCollector<128> collector;
    return collector;
}

template<class Clock, class Sink>
class BasicFlushCallScope {
public:
    BasicFlushCallScope(uint32_t range_count, bool enabled, Clock clock, Sink sink) noexcept
        : clock_(std::move(clock)), sink_(std::move(sink)), enabled_(enabled) {
        if (enabled_) {
            record_.range_count = range_count;
            record_.result = 0;
            started_us_ = clock_();
        }
    }

    BasicFlushCallScope(const BasicFlushCallScope&) = delete;
    BasicFlushCallScope& operator=(const BasicFlushCallScope&) = delete;

    ~BasicFlushCallScope() noexcept {
        if (enabled_ && !completed_) {
            if (record_.result == 0) record_.result = -4;
            emitOnce();
        }
    }

    template<class Fn>
    int send(unsigned long long payload_bytes, Fn&& fn) {
        if (!enabled_) return fn();
        const uint64_t start_us = clock_();
        int rc = -4;
        struct SendGuard {
            BasicFlushCallScope* self;
            uint64_t bytes;
            uint64_t start;
            int* rc_ptr;
            ~SendGuard() noexcept {
                const uint64_t end = self->clock_();
                const uint64_t elapsed = end >= start ? end - start : 0u;
                self->record_.recordSend(bytes, elapsed, *rc_ptr);
            }
        } guard{this, static_cast<uint64_t>(payload_bytes), start_us, &rc};
        rc = fn();
        return rc;
    }

    template<class Fn>
    bool receive(int& result, Fn&& fn) {
        if (!enabled_) return fn();
        const uint64_t start_us = clock_();
        bool ok = false;
        struct ReadGuard {
            BasicFlushCallScope* self;
            uint64_t start;
            bool* ok_ptr;
            int* result_ptr;
            ~ReadGuard() noexcept {
                const uint64_t end = self->clock_();
                const uint64_t elapsed = end >= start ? end - start : 0u;
                self->record_.recordRead(elapsed, *ok_ptr, *result_ptr);
            }
        } guard{this, start_us, &ok, &result};
        ok = fn();
        return ok;
    }

    void invalidate() noexcept {
        if (enabled_) record_.recordInvalidate();
    }

    int finish(int final_result) noexcept {
        if (enabled_ && !completed_) {
            record_.result = final_result;
            emitOnce();
        }
        return final_result;
    }

private:
    void emitOnce() noexcept {
        completed_ = true;
        try {
            const uint64_t end_us = clock_();
            record_.elapsed_us = end_us >= started_us_ ? end_us - started_us_ : 0u;
            sink_(record_);
        } catch (...) {}
    }

    Clock clock_;
    Sink sink_;
    FlushCallRecord record_{};
    uint64_t started_us_ = 0;
    bool enabled_ = false;
    bool completed_ = false;
};

class FlushCallScope {
public:
    explicit FlushCallScope(uint32_t range_count) noexcept
        : inner_(range_count, flushTimingEnabled(), &steadyFlushMicros, DefaultSink{}) {}

    FlushCallScope(const FlushCallScope&) = delete;
    FlushCallScope& operator=(const FlushCallScope&) = delete;

    template<class Fn>
    int send(unsigned long long payload_bytes, Fn&& fn) {
        return inner_.send(payload_bytes, std::forward<Fn>(fn));
    }

    template<class Fn>
    bool receive(int& result, Fn&& fn) {
        return inner_.receive(result, std::forward<Fn>(fn));
    }

    void invalidate() noexcept { inner_.invalidate(); }
    int finish(int final_result) noexcept { return inner_.finish(final_result); }

private:
    struct DefaultSink {
        void operator()(const FlushCallRecord& rec) const noexcept {
            processFlushTimingCollector().record(rec);
        }
    };
    BasicFlushCallScope<uint64_t (*)() noexcept, DefaultSink> inner_;
};

} // namespace caboose::memory
