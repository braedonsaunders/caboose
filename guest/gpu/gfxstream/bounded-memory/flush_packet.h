// SPDX-License-Identifier: MIT
#pragma once
#include "ranges.h"
#include <array>
#include <utility>

namespace caboose::memory {
inline constexpr size_t flushFragmentCapacity = 8;
inline constexpr size_t flushWindowCapacity = 8;
struct FlushFragment {
    unsigned range;
    uint64_t offset;
    uint64_t size;
};

// Windowed multi-range flush. Each packet packs up to eight fragments (<= 512 KiB)
// and pipelines up to eight packets (<= 4 MiB, 64 fragments) per window before
// draining every queued provider result in order; DATA envelopes keep their 64 KiB cap.
template<class Send, class Receive, class Invalidate>
class FlushPacket {
public:
    static constexpr size_t capacity = flushFragmentCapacity;
    static constexpr size_t windowCapacity = flushWindowCapacity;
    static constexpr uint64_t byteLimit = capacity * rpcBytes;
    static constexpr uint64_t headerBytes = 20, fragmentOverhead = 40;
    FlushPacket(Send send, Receive receive, Invalidate invalidate)
        : send_(std::move(send)), receive_(std::move(receive)), invalidate_(std::move(invalidate)) {}
    ~FlushPacket() { if (pending_ || sending_) invalidate_(); }
    int push(unsigned range, uint64_t offset, uint64_t size) {
        if (failure_) return failure_;
        if (!size || size > payloadBytes) return lost();
        if (fragmentOverhead + size > byteLimit - bytes_) {
            const int result = emitPacket();
            if (result) return result;
        }
        fragments_[count_++] = {range, offset, size};
        bytes_ += fragmentOverhead + size;
        return count_ == capacity ? emitPacket() : 0;
    }
    int finish() {
        if (failure_) return failure_;
        if (count_ > 0) {
            const int result = emitPacket();
            if (result) return result;
        }
        return drainWindow();
    }
private:
    int lost() {
        invalidate_();
        pending_ = 0;
        sending_ = false;
        count_ = 0;
        bytes_ = headerBytes;
        failure_ = -4;
        return failure_;
    }
    int emitPacket() {
        if (!count_) return 0;
        try {
            // A serialization exception may leave a partial command in IOStream.
            sending_ = true;
            if (send_(fragments_.data(), count_, bytes_) != 0) return lost();
            sending_ = false;
            count_ = 0;
            bytes_ = headerBytes;
            ++pending_;
            return pending_ == windowCapacity ? drainWindow() : 0;
        } catch (...) { lost(); throw; }
    }
    int drainWindow() {
        int first = 0;
        try {
            while (pending_) {
                int result = 0;
                if (!receive_(result)) return lost();
                --pending_;
                if (!first && result) first = result;
            }
        } catch (...) { lost(); throw; }
        if (first != 0) failure_ = first;
        return first;
    }
    Send send_;
    Receive receive_;
    Invalidate invalidate_;
    std::array<FlushFragment, capacity> fragments_{};
    size_t count_ = 0;
    uint64_t bytes_ = headerBytes;
    size_t pending_ = 0;
    bool sending_ = false;
    int failure_ = 0;
};
template<class S, class R, class I>
FlushPacket(S, R, I) -> FlushPacket<S, R, I>;
}
