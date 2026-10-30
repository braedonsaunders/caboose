// SPDX-License-Identifier: MIT
#pragma once
#include "ranges.h"
#if __has_include("gfxstream/guest/IOStream.h")
#include "gfxstream/guest/IOStream.h"
#endif
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <new>
#include <vector>

namespace caboose::memory {

inline constexpr size_t cbInitialStagingBytes = 64 * 1024;
inline constexpr size_t cbMaxStagingBytes = 4 * 1024 * 1024;

// Bounded per-command-buffer local recording stream backed by processBudget.
// Never performs network I/O; stores unsequenced v4 packets (OP_vkBeginCommandBuffer
// + OP_vkCmd* + OP_vkEndCommandBuffer) in contiguous process-budgeted memory until
// vkQueueSubmit coalesces all staged command buffers and OP_vkQueueSubmit into a
// single network round-trip.
class CabooseCommandBufferStream final : public gfxstream::guest::IOStream {
public:
    explicit CabooseCommandBufferStream(
        Budget& budget = processBudget,
        size_t maxBytes = cbMaxStagingBytes,
        size_t initialBytes = cbInitialStagingBytes) noexcept
        : IOStream(initialBytes),
          budget_(budget),
          maxBytes_(maxBytes),
          initialBytes_(std::min(initialBytes, maxBytes)) {}

    ~CabooseCommandBufferStream() override {
        reset();
    }

    CabooseCommandBufferStream(const CabooseCommandBufferStream&) = delete;
    CabooseCommandBufferStream& operator=(const CabooseCommandBufferStream&) = delete;

    bool hasOverflowed() const noexcept { return overflowed_; }
    bool isEnded() const noexcept { return ended_; }

    void markOverflowed() noexcept {
        overflowed_ = true;
        ended_ = false;
        releaseStorage();
        rewind();
    }

    // Appends the 16-byte OP_vkEndCommandBuffer packet, shrinks capacity down to
    // the exact recorded byte count (releasing slack back to budget_), and marks
    // the stream ended and ready for vkQueueSubmit coalescing.
    bool stageEndPacket(uint32_t opcode, uint64_t hostCommandBuffer) noexcept {
        if (overflowed_ || ended_) {
            markOverflowed();
            return false;
        }
        const uint32_t packetSize = 16;
        uint8_t* ptr = static_cast<uint8_t*>(alloc(packetSize));
        if (!ptr) {
            markOverflowed();
            return false;
        }
        std::memcpy(ptr, &opcode, sizeof(uint32_t));
        std::memcpy(ptr + 4, &packetSize, sizeof(uint32_t));
        std::memcpy(ptr + 8, &hostCommandBuffer, sizeof(uint64_t));
        if (flush() < 0 || overflowed_ || !data_ || written_ < 16) {
            markOverflowed();
            return false;
        }
        if (capacity_ > written_) {
            const size_t slack = capacity_ - written_;
            if (auto* shrunk = static_cast<uint8_t*>(std::realloc(data_, written_))) {
                data_ = shrunk;
            }
            capacity_ = written_;
            budget_.release(slack);
        }
        ended_ = true;
        return true;
    }

    size_t capacityBytes() const noexcept { return capacity_; }
    size_t maxCapacityBytes() const noexcept { return maxBytes_; }

    // Synchronize any buffered IOStream region and return the staged bytes.
    void getWritten(const uint8_t** dataOut, size_t* sizeOut) noexcept {
        (void)flush();
        if (overflowed_ || !data_ || written_ == 0) {
            if (dataOut) *dataOut = nullptr;
            if (sizeOut) *sizeOut = 0;
            return;
        }
        if (dataOut) *dataOut = data_;
        if (sizeOut) *sizeOut = written_;
    }

    // Detach staged bytes into a caller-owned vector and immediately release
    // the stream's processBudget reservation. If overflowed, returns false.
    bool detachWritten(std::vector<uint8_t>& out, Reservation& outReservation) noexcept {
        (void)flush();
        out.clear();
        if (overflowed_) {
            reset();
            return false;
        }
        if (!data_ || written_ == 0) {
            reset();
            return true;
        }
        const size_t bytes = written_;
        // Release our capacity reservation first so transferring into `outReservation`
        // never double-counts against `budget_`.
        const size_t oldCap = capacity_;
        capacity_ = 0;
        budget_.release(oldCap);
        if (!outReservation.add(bytes)) {
            std::free(data_);
            data_ = nullptr;
            written_ = 0;
            overflowed_ = true;
            ended_ = false;
            rewind();
            return false;
        }
        try {
            out.assign(data_, data_ + bytes);
        } catch (...) {
            std::free(data_);
            data_ = nullptr;
            written_ = 0;
            overflowed_ = true;
            ended_ = false;
            rewind();
            return false;
        }
        std::free(data_);
        data_ = nullptr;
        written_ = 0;
        ended_ = false;
        rewind();
        return true;
    }

    // Append staged bytes onto `out` (extending `outReservation` by `written_`)
    // and immediately release the stream's own storage and budget reservation.
    bool appendDetachedTo(std::vector<uint8_t>& out, Reservation& outReservation) noexcept {
        (void)flush();
        if (overflowed_ || !ended_ || !data_ || written_ == 0) {
            reset();
            return false;
        }
        const size_t bytes = written_;
        const size_t oldCap = capacity_;
        capacity_ = 0;
        budget_.release(oldCap);
        if (!outReservation.add(bytes)) {
            std::free(data_);
            data_ = nullptr;
            written_ = 0;
            overflowed_ = true;
            ended_ = false;
            rewind();
            return false;
        }
        try {
            out.insert(out.end(), data_, data_ + bytes);
        } catch (...) {
            std::free(data_);
            data_ = nullptr;
            written_ = 0;
            overflowed_ = true;
            ended_ = false;
            rewind();
            return false;
        }
        std::free(data_);
        data_ = nullptr;
        written_ = 0;
        ended_ = false;
        rewind();
        return true;
    }

    void reset() noexcept {
        overflowed_ = false;
        ended_ = false;
        written_ = 0;
        releaseStorage();
        rewind();
    }

    void* allocBuffer(size_t minSize) override {
        if (overflowed_ || ended_) return nullptr;
        if (minSize > maxBytes_ || written_ > maxBytes_ - minSize) {
            markOverflowed();
            return nullptr;
        }
        const size_t required = written_ + minSize;
        if (required > capacity_) {
            size_t nextCap = capacity_ ? capacity_ : initialBytes_;
            while (nextCap < required) {
                if (nextCap > maxBytes_ / 2) {
                    nextCap = maxBytes_;
                    break;
                }
                nextCap *= 2;
            }
            if (nextCap < required || nextCap > maxBytes_) {
                markOverflowed();
                return nullptr;
            }
            const size_t delta = nextCap - capacity_;
            if (!budget_.acquire(delta)) {
                markOverflowed();
                return nullptr;
            }
            auto* nextData = static_cast<uint8_t*>(std::realloc(data_, nextCap));
            if (!nextData) {
                budget_.release(delta);
                markOverflowed();
                return nullptr;
            }
            data_ = nextData;
            capacity_ = nextCap;
        }
        return data_ + written_;
    }

    size_t idealAllocSize(size_t len) override {
        if (overflowed_ || ended_ || len > maxBytes_ - written_) return len;
        const size_t remainingMax = maxBytes_ - written_;
        const size_t target = std::max(len, initialBytes_);
        return std::min(target, remainingMax);
    }

    int commitBuffer(size_t size) override {
        if (overflowed_ || ended_ || size > capacity_ - written_) {
            markOverflowed();
            return -1;
        }
        written_ += size;
        return 0;
    }

    const unsigned char* readFully(void*, size_t) override {
        markOverflowed();
        return nullptr;
    }

    const unsigned char* commitBufferAndReadFully(size_t, void*, size_t) override {
        markOverflowed();
        return nullptr;
    }

    const unsigned char* read(void*, size_t*) override {
        markOverflowed();
        return nullptr;
    }

    int writeFully(const void* buf, size_t len) override {
        if (overflowed_ || ended_) return -1;
        if (len == 0) return 0;
        if (!buf) {
            markOverflowed();
            return -1;
        }
        if (flush() < 0) return -1;
        void* dst = allocBuffer(len);
        if (!dst) return -1;
        std::memcpy(dst, buf, len);
        written_ += len;
        return 0;
    }

private:
    void releaseStorage() noexcept {
        if (data_) {
            std::free(data_);
            data_ = nullptr;
        }
        if (capacity_) {
            budget_.release(capacity_);
            capacity_ = 0;
        }
    }

    Budget& budget_;
    size_t maxBytes_;
    size_t initialBytes_;
    uint8_t* data_ = nullptr;
    size_t capacity_ = 0;
    size_t written_ = 0;
    bool overflowed_ = false;
    bool ended_ = false;
};

} // namespace caboose::memory
