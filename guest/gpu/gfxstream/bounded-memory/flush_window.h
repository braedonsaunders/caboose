// SPDX-License-Identifier: MIT
#pragma once
#include <cstddef>
#include <utility>
namespace caboose::memory {
// Send returns zero only after an ordinary packet was serialized. Receive
// distinguishes transport failure from a real provider result. No failed
// window can be reused, even if earlier replies had successful results.
template<class Send, class Receive, class Invalidate>
class FlushWindow {
public:
    static constexpr size_t capacity = 8;
    FlushWindow(Send send, Receive receive, Invalidate invalidate)
        : send_(std::move(send)), receive_(std::move(receive)), invalidate_(std::move(invalidate)) {}
    ~FlushWindow() { if (pending_) invalidate_(); }
    int push(unsigned range, unsigned long long offset, unsigned long long size) {
        if (failure_) return failure_;
        try {
            if (send_(range, offset, size) != 0) return lost();
            ++pending_;
            return pending_ == capacity ? drain() : 0;
        } catch (...) { lost(); throw; }
    }
    int finish() { return failure_ ? failure_ : drain(); }
private:
    int lost() { invalidate_(); pending_ = 0; failure_ = -4; return failure_; }
    int drain() {
        int first = 0;
        try {
            while (pending_) {
                int result = 0;
                if (!receive_(result)) return lost();
                --pending_;
                if (!first && result) first = result;
            }
        } catch (...) { lost(); throw; }
        failure_ = first;
        return first;
    }
    Send send_;
    Receive receive_;
    Invalidate invalidate_;
    size_t pending_ = 0;
    int failure_ = 0;
};
template<class S, class R, class I>
FlushWindow(S, R, I) -> FlushWindow<S, R, I>;
}
