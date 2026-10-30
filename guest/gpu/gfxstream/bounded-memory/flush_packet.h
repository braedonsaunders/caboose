// SPDX-License-Identifier: MIT
#pragma once
#include "ranges.h"
#include <array>
#include <utility>

namespace caboose::memory {
// Changed-page flushes produce many small fragments; each drained packet costs a
// full round-trip, so a packet carries many fragments under one byte ceiling.
// The guest-to-device transport closes the stream on packets past 1 MiB.
inline constexpr size_t flushFragmentCapacity = 64;
inline constexpr uint64_t flushPacketByteLimit = 15 * rpcBytes;
struct FlushFragment {
    unsigned range;
    uint64_t offset;
    uint64_t size;
};

// One ordinary, unsequenced multi-range flush; DATA envelopes retain their own
// 64 KiB cap. Send serializes this packet; Receive returns its one actual
// provider result.
template<class Send, class Receive, class Invalidate>
class FlushPacket {
public:
    static constexpr size_t capacity = flushFragmentCapacity;
    static constexpr uint64_t byteLimit = flushPacketByteLimit;
    static constexpr uint64_t headerBytes = 20, fragmentOverhead = 40;
    FlushPacket(Send send, Receive receive, Invalidate invalidate)
        : send_(std::move(send)), receive_(std::move(receive)), invalidate_(std::move(invalidate)) {}
    ~FlushPacket() { if (pending_) invalidate_(); }
    int push(unsigned range, uint64_t offset, uint64_t size) {
        if (failure_) return failure_;
        if (!size || size > payloadBytes) return lost();
        if (fragmentOverhead + size > byteLimit - bytes_) {
            const int result = drain();
            if (result) return result;
        }
        fragments_[count_++] = {range, offset, size};
        bytes_ += fragmentOverhead + size;
        return count_ == capacity ? drain() : 0;
    }
    int finish() { return failure_ ? failure_ : drain(); }
private:
    int lost() {
        invalidate_(); pending_ = false; count_ = 0;
        failure_ = -4; return failure_;
    }
    int drain() {
        if (!count_) return 0;
        try {
            // A serialization exception may leave a partial command in IOStream.
            pending_ = true;
            if (send_(fragments_.data(), count_, bytes_) != 0) return lost();
            int result = 0;
            if (!receive_(result)) return lost();
            pending_ = false; count_ = 0; bytes_ = headerBytes;
            failure_ = result;
            return result;
        } catch (...) { lost(); throw; }
    }
    Send send_;
    Receive receive_;
    Invalidate invalidate_;
    std::array<FlushFragment, capacity> fragments_{};
    size_t count_ = 0;
    uint64_t bytes_ = headerBytes;
    bool pending_ = false;
    int failure_ = 0;
};
template<class S, class R, class I>
FlushPacket(S, R, I) -> FlushPacket<S, R, I>;
}
