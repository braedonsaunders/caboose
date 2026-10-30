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

inline constexpr uint64_t shadowPageBytes = 4096;
inline constexpr uint64_t shadowMaxAllocationBytes = 16 * 1024 * 1024;
// Shadows share processBudget with command-buffer staging; keep them to a slice of it.
inline constexpr size_t shadowMaxTotalBytes = 24 * 1024 * 1024;

// Last bytes the host received for each flushed allocation, at page granularity.
// A flush sends only pages that differ from (or were never sent into) the
// shadow. Invalidate, unmap and free drop knowledge of the host's copy, so the
// next flush of those pages is sent in full. Allocations the budget cannot
// shadow are always sent in full.
class FlushShadow {
public:
    explicit FlushShadow(Budget& budget = processBudget) : budget_(budget) {}
    ~FlushShadow() { std::lock_guard<std::mutex> lock(mutex_); clearLocked(); }

    // Calls emit(offset, size) for each maximal run of changed pages inside
    // [offset, offset + size) of the mapping `base`, and records those bytes as
    // sent. Run boundaries are page-aligned or equal to the chunk's own bounds.
    template<class Emit>
    int emitChanged(uint64_t key, const uint8_t* base, uint64_t allocation,
                    uint64_t offset, uint64_t size, Emit emit) {
        std::lock_guard<std::mutex> lock(mutex_);
        Entry* entry = entryLocked(key, allocation);
        if (!entry) return emit(offset, size);
        const uint64_t end = offset + size;
        uint64_t runBegin = 0;
        bool inRun = false;
        for (uint64_t page = offset - offset % shadowPageBytes; page < end; page += shadowPageBytes) {
            const uint64_t begin = page < offset ? offset : page;
            const uint64_t stop = page + shadowPageBytes < end ? page + shadowPageBytes : end;
            const size_t index = size_t(page / shadowPageBytes);
            const uint64_t pageEnd = page + shadowPageBytes < allocation ? page + shadowPageBytes : allocation;
            const bool whole = begin == page && stop == pageEnd;
            bool changed = !entry->valid[index] ||
                std::memcmp(entry->bytes.get() + begin, base + begin, size_t(stop - begin)) != 0;
            if (changed) {
                std::memcpy(entry->bytes.get() + begin, base + begin, size_t(stop - begin));
                // A partially sent page is only known on the host where it was sent.
                entry->valid[index] = whole || entry->valid[index];
                if (!inRun) { runBegin = begin; inRun = true; }
            } else if (inRun) {
                const int result = emit(runBegin, begin - runBegin);
                if (result != success) { forgetLocked(key); return result; }
                inRun = false;
            }
        }
        if (inRun) {
            const int result = emit(runBegin, end - runBegin);
            if (result != success) { forgetLocked(key); return result; }
        }
        return success;
    }

    void forget(uint64_t key) {
        std::lock_guard<std::mutex> lock(mutex_);
        forgetLocked(key);
    }

private:
    struct Entry {
        std::unique_ptr<uint8_t[]> bytes;
        std::vector<bool> valid;
        size_t charged = 0;
    };

    Entry* entryLocked(uint64_t key, uint64_t allocation) {
        auto found = entries_.find(key);
        if (found != entries_.end()) {
            if (found->second.charged >= allocation) return &found->second;
            forgetLocked(key);
        }
        if (!allocation || allocation > shadowMaxAllocationBytes) return nullptr;
        const size_t pages = size_t((allocation + shadowPageBytes - 1) / shadowPageBytes);
        const size_t charged = size_t(allocation) + pages / 8 + sizeof(Entry);
        if (charged > shadowMaxTotalBytes - used_ || !budget_.acquire(charged)) return nullptr;
        Entry entry;
        entry.bytes.reset(new (std::nothrow) uint8_t[size_t(allocation)]);
        if (!entry.bytes) { budget_.release(charged); return nullptr; }
        try {
            entry.valid.assign(pages, false);
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

} // namespace caboose::memory
