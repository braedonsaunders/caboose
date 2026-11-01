// SPDX-License-Identifier: MIT
#pragma once
#include "ranges.h"
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <new>
#include <unordered_map>
#include <vector>

namespace caboose::memory {

inline constexpr uint64_t shadowBlockBytes = 256;
inline constexpr uint64_t shadowMaxAllocationBytes = 32 * 1024 * 1024;
// Shadows share processBudget with command-buffer staging; keep them to a slice of it.
inline constexpr size_t shadowMaxTotalBytes = 48 * 1024 * 1024;

// Last bytes the host received for each flushed allocation. The host's copy is
// known per 256-byte block: a flush sends only the known blocks that differ and
// every block it does not know, and a block becomes known once it was sent or
// refreshed whole. Applications flush small ranges (ANGLE and Zink a few hundred
// bytes to a few KiB of a large allocation), so knowledge kept per page would never
// form and every range would be sent again in full. Unmap and free drop knowledge
// of the host's copy, while a successful invalidate updates the known host baseline
// with the refreshed bytes. Allocations the budget cannot shadow are always sent
// in full.
class FlushShadow {
public:
    explicit FlushShadow(Budget& budget = processBudget) : budget_(budget) {}
    ~FlushShadow() { std::lock_guard<std::mutex> lock(mutex_); clearLocked(); }

    // Calls emit(offset, size) for each maximal run of changed blocks inside
    // [offset, offset + size) of the mapping `base`, and records those bytes as
    // sent. Run boundaries are block-aligned or equal to the chunk's own bounds.
    template<class Emit>
    int emitChanged(uint64_t key, const uint8_t* base, uint64_t allocation,
                    uint64_t offset, uint64_t size, Emit emit) {
        std::lock_guard<std::mutex> lock(mutex_);
        Entry* entry = entryLocked(key, allocation);
        if (!entry) return emit(offset, size);
        const uint64_t end = offset + size;
        uint64_t runBegin = 0;
        bool inRun = false;
        for (uint64_t block = offset; block < end;) {
            const uint64_t first = block - block % shadowBlockBytes;
            const uint64_t next = first + shadowBlockBytes;
            const uint64_t blockStop = next < end ? next : end;
            const size_t index = size_t(first / shadowBlockBytes);
            const bool known = entry->valid[index];
            const bool changed = !known ||
                std::memcmp(entry->bytes.get() + block, base + block, size_t(blockStop - block)) != 0;
            if (changed) {
                std::memcpy(entry->bytes.get() + block, base + block, size_t(blockStop - block));
                if (!inRun) { runBegin = block; inRun = true; }
            } else if (inRun) {
                const int result = emit(runBegin, block - runBegin);
                if (result != success) { forgetLocked(key); return result; }
                inRun = false;
            }
            // A partially sent block is only known on the host where it was sent.
            entry->valid[index] = known || (block == first && blockStop == blockEnd(first, allocation));
            block = blockStop;
        }
        if (inRun) {
            const int result = emit(runBegin, end - runBegin);
            if (result != success) { forgetLocked(key); return result; }
        }
        return success;
    }

    // Records that [offset, offset + size) of `base` now matches the host's copy
    // (e.g. after a successful vkInvalidateMappedMemoryRanges into `base`).
    void noteRefreshed(uint64_t key, const uint8_t* base, uint64_t allocation,
                       uint64_t offset, uint64_t size) {
        if (!base || !size || offset >= allocation) return;
        const uint64_t end = size > allocation - offset ? allocation : offset + size;
        std::lock_guard<std::mutex> lock(mutex_);
        Entry* entry = entryLocked(key, allocation);
        if (!entry) return;
        std::memcpy(entry->bytes.get() + offset, base + offset, size_t(end - offset));
        for (uint64_t block = offset; block < end;) {
            const uint64_t first = block - block % shadowBlockBytes;
            const uint64_t blockStop = first + shadowBlockBytes < end ? first + shadowBlockBytes : end;
            const size_t index = size_t(first / shadowBlockBytes);
            entry->valid[index] = entry->valid[index] || (block == first && blockStop == blockEnd(first, allocation));
            block = blockStop;
        }
    }

    // Whether the host holds every block of [offset, offset + size) whole and the mapping
    // still has the bytes it was sent: a flush of the range would send nothing.
    bool unchanged(uint64_t key, const uint8_t* base, uint64_t allocation, uint64_t offset,
                   uint64_t size) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto found = entries_.find(key);
        if (found == entries_.end() || found->second.charged < allocation || !size ||
            offset > allocation || size > allocation - offset) return false;
        const Entry& entry = found->second;
        for (uint64_t first = offset - offset % shadowBlockBytes; first < offset + size; first += shadowBlockBytes)
            if (!entry.valid[size_t(first / shadowBlockBytes)]) return false;
        return std::memcmp(entry.bytes.get() + offset, base + offset, size_t(size)) == 0;
    }

    void forget(uint64_t key) {
        std::lock_guard<std::mutex> lock(mutex_);
        forgetLocked(key);
    }

    // The device wrote [begin, end) behind the guest's back: every block it touches
    // is sent again until a flush or an invalidate makes it known once more.
    void forgetRange(uint64_t key, uint64_t begin, uint64_t end) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto found = entries_.find(key);
        if (found == entries_.end()) return;
        std::vector<bool>& valid = found->second.valid;
        const size_t last = valid.size();
        for (size_t index = size_t(begin / shadowBlockBytes);
             index < last && uint64_t(index) * shadowBlockBytes < end; ++index)
            valid[index] = false;
    }

private:
    struct Entry {
        std::unique_ptr<uint8_t[]> bytes;
        std::vector<bool> valid;
        size_t charged = 0;
    };

    static uint64_t blockEnd(uint64_t first, uint64_t allocation) {
        return first + shadowBlockBytes < allocation ? first + shadowBlockBytes : allocation;
    }

    Entry* entryLocked(uint64_t key, uint64_t allocation) {
        auto found = entries_.find(key);
        if (found != entries_.end()) {
            if (found->second.charged >= allocation) return &found->second;
            forgetLocked(key);
        }
        if (!allocation || allocation > shadowMaxAllocationBytes) return nullptr;
        const size_t blocks = size_t((allocation + shadowBlockBytes - 1) / shadowBlockBytes);
        const size_t charged = size_t(allocation) + blocks / 8 + sizeof(Entry);
        if (charged > shadowMaxTotalBytes - used_ || !budget_.acquire(charged)) return nullptr;
        Entry entry;
        entry.bytes.reset(new (std::nothrow) uint8_t[size_t(allocation)]);
        if (!entry.bytes) { budget_.release(charged); return nullptr; }
        try {
            entry.valid.assign(blocks, false);
            entry.charged = charged;
            Entry* stored = &entries_.emplace(key, std::move(entry)).first->second;
            used_ += charged;
            return stored;
        } catch (...) {
            budget_.release(charged);
            return nullptr;
        }
    }

    void forgetLocked(uint64_t key) {
        auto found = entries_.find(key);
        if (found == entries_.end()) return;
        budget_.release(found->second.charged);
        used_ -= found->second.charged;
        entries_.erase(found);
    }

    void clearLocked() {
        for (auto& [key, entry] : entries_) budget_.release(entry.charged);
        entries_.clear();
        used_ = 0;
    }

    Budget& budget_;
    size_t used_ = 0;
    std::mutex mutex_;
    std::unordered_map<uint64_t, Entry> entries_;
};

inline FlushShadow flushShadow;
inline thread_local uint64_t lastFlushCallSentBytes = 0;

} // namespace caboose::memory
