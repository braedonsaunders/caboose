// SPDX-License-Identifier: MIT
#pragma once
#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <new>

namespace caboose::memory {
constexpr uint64_t rpcBytes = 64 * 1024;
// One unsequenced VkMappedMemoryRange command: 52-byte header + 8-byte tail
// length. Invalidate replies use a 4-byte result + 8-byte tail length.
constexpr uint64_t payloadBytes = rpcBytes - 60;
constexpr size_t stagingBytes = 64 * 1024 * 1024;
constexpr int success = 0, outOfHostMemory = -1;

class Budget {
public:
    explicit Budget(size_t maximum = stagingBytes) : maximum_(maximum) {}
    bool acquire(size_t bytes) {
        size_t prior = used_.load(std::memory_order_relaxed);
        do { if (bytes > maximum_ - prior) return false; }
        while (!used_.compare_exchange_weak(prior, prior + bytes, std::memory_order_relaxed));
        return true;
    }
    void release(size_t bytes) { used_.fetch_sub(bytes, std::memory_order_relaxed); }
    size_t used() const { return used_.load(std::memory_order_relaxed); }
private:
    size_t maximum_;
    std::atomic<size_t> used_{0};
};
inline Budget processBudget;
struct Reservation {
    Budget& budget;
    size_t held = 0;
    bool add(size_t bytes) {
        if (!budget.acquire(bytes)) return false;
        held += bytes; return true;
    }
    ~Reservation() { budget.release(held); }
};
struct Range {
    uint64_t offset = 0, size = 0, mapBegin = 0, mapEnd = 0, allocation = 0, atom = 0;
    bool whole = false;
    uint8_t* base = nullptr; // allocation-relative shadow, never serialized
    std::shared_ptr<uint8_t> lifetime;
    size_t stagedOffset = 0;
};

// Lookup snapshots real mapping metadata; emit performs one ordinary synchronous
// encoder RPC and returns its actual VkResult. No whole-call publication on any
// failed invalidate. The caller supplies valid Vulkan host synchronization.
template<class Lookup, class Emit>
int transact(bool invalidate, uint32_t count, Lookup lookup, Emit emit,
             Budget& budget = processBudget) {
    if (!count || count > (SIZE_MAX - sizeof(Reservation)) / sizeof(Range)) return outOfHostMemory;
    Reservation reservation{budget};
    if (!reservation.add(size_t(count) * sizeof(Range) + sizeof(Reservation))) return outOfHostMemory;
    std::unique_ptr<Range[]> plan(new (std::nothrow) Range[count]);
    if (!plan) return outOfHostMemory;
    size_t total = 0;
    for (uint32_t i = 0; i < count; ++i) {
        auto& r = plan[i];
        if (!lookup(i, r) || !r.base || !r.lifetime || !r.atom || r.offset % r.atom ||
            r.mapBegin > r.mapEnd || r.mapEnd > r.allocation || r.allocation > SIZE_MAX ||
            r.offset < r.mapBegin || r.offset >= r.mapEnd) return outOfHostMemory;
        if (r.whole) r.size = r.mapEnd - r.offset;
        if (!r.size || r.size > r.mapEnd - r.offset ||
            (r.size % r.atom && r.offset + r.size != r.allocation) ||
            (r.size > payloadBytes && r.atom > payloadBytes)) return outOfHostMemory;
        if (invalidate) {
            if (r.size > SIZE_MAX - total) return outOfHostMemory;
            r.stagedOffset = total; total += size_t(r.size);
        }
    }
    // Plan storage and every overlap's separate result storage share one process
    // reservation; failure here occurs before any remote call or shadow mutation.
    if (!reservation.add(total)) return outOfHostMemory;
    std::unique_ptr<uint8_t[]> staged;
    if (total) {
        staged.reset(new (std::nothrow) uint8_t[total]);
        if (!staged) return outOfHostMemory;
    }
    for (uint32_t i = 0; i < count; ++i) {
        const auto& r = plan[i];
        uint64_t done = 0;
        while (done < r.size) {
            uint64_t bytes = std::min(payloadBytes, r.size - done);
            if (bytes < r.size - done) bytes -= bytes % r.atom;
            auto* destination = invalidate ? staged.get() + r.stagedOffset + size_t(done) : nullptr;
            const int result = emit(i, r.offset + done, bytes, destination);
            if (result != success) return result;
            done += bytes;
        }
    }
    if (invalidate) {
        for (uint32_t i = 0; i < count; ++i) {
            const auto& r = plan[i];
            // Preserve original order, including overlapping ranges.
            std::memcpy(r.base + size_t(r.offset), staged.get() + r.stagedOffset, size_t(r.size));
        }
    }
    return success;
}
}
