// SPDX-License-Identifier: MIT
#pragma once
#include "lock_order.h"
#include "memory_traffic.h"
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
// Allocations no copy fits are known by a 64-bit hash of each block instead: 1/32 of their
// size, so 16 MiB knows 512 MiB of mapped memory.
inline constexpr size_t shadowMaxHashBytes = 16 * 1024 * 1024;

// XXH64 of one block (Yann Collet's xxHash, seed 0).
inline uint64_t blockHash(const uint8_t* p, size_t size) {
    constexpr uint64_t p1 = 0x9E3779B185EBCA87ull, p2 = 0xC2B2AE3D27D4EB4Full, p3 = 0x165667B19E3779F9ull,
                       p4 = 0x85EBCA77C2B2AE63ull, p5 = 0x27D4EB2F165667C5ull;
    auto rotl = [](uint64_t x, int r) { return (x << r) | (x >> (64 - r)); };
    auto read64 = [](const uint8_t* q) { uint64_t v; std::memcpy(&v, q, 8); return v; };
    auto read32 = [](const uint8_t* q) { uint32_t v; std::memcpy(&v, q, 4); return uint64_t(v); };
    auto round = [&](uint64_t acc, uint64_t input) { return rotl(acc + input * p2, 31) * p1; };
    auto merge = [&](uint64_t acc, uint64_t value) { return (acc ^ round(0, value)) * p1 + p4; };
    const uint8_t* end = p + size;
    uint64_t h;
    if (size >= 32) {
        uint64_t v1 = p1 + p2, v2 = p2, v3 = 0, v4 = 0 - p1;
        for (; p + 32 <= end; p += 32) {
            v1 = round(v1, read64(p)); v2 = round(v2, read64(p + 8));
            v3 = round(v3, read64(p + 16)); v4 = round(v4, read64(p + 24));
        }
        h = rotl(v1, 1) + rotl(v2, 7) + rotl(v3, 12) + rotl(v4, 18);
        h = merge(merge(merge(merge(h, v1), v2), v3), v4);
    } else {
        h = p5;
    }
    h += uint64_t(size);
    for (; p + 8 <= end; p += 8) h = rotl(h ^ round(0, read64(p)), 27) * p1 + p4;
    if (p + 4 <= end) { h = rotl(h ^ (read32(p) * p1), 23) * p2 + p3; p += 4; }
    for (; p < end; ++p) h = rotl(h ^ (uint64_t(*p) * p5), 11) * p1;
    h ^= h >> 33; h *= p2; h ^= h >> 29; h *= p3; h ^= h >> 32;
    return h;
}

// Last bytes the host received for each flushed allocation. The host's copy is
// known per 256-byte block: a flush sends only the known blocks that differ and
// every block it does not know, and a block becomes known once it was sent or
// refreshed whole. Applications flush small ranges (ANGLE and Zink a few hundred
// bytes to a few KiB of a large allocation), so knowledge kept per page would never
// form and every range would be sent again in full. Unmap and free drop knowledge
// of the host's copy, while a successful invalidate updates the known host baseline
// with the refreshed bytes. An allocation too large for a copy, or past the copies'
// share of the budget, is known by block hashes: a whole block whose hash matches what
// was sent is not sent again, and a partly sent block is sent until it is sent whole.
// Allocations the budget cannot know either way are always sent in full.
class FlushShadow {
public:
    explicit FlushShadow(Budget& budget = processBudget) : budget_(budget) {}
    ~FlushShadow() { std::lock_guard<decltype(mutex_)> lock(mutex_); clearLocked(); }

    // Calls emit(offset, size) for each maximal run of changed blocks inside
    // [offset, offset + size) of the mapping `base`, and records those bytes as
    // sent. Run boundaries are block-aligned or equal to the chunk's own bounds.
    template<class Emit>
    int emitChanged(uint64_t key, const uint8_t* base, uint64_t allocation,
                    uint64_t offset, uint64_t size, Emit emit) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        Entry* entry = entryLocked(key, allocation);
        auto& traffic = traffic::counters();
        if (!entry) {
            traffic.shadowed(traffic::unshadowed, size, size);
            return emit(offset, size);
        }
        const auto kind = entry->bytes ? traffic::copied : traffic::hashed;
        uint64_t sent = 0;
        auto send = [&](uint64_t runOffset, uint64_t runSize) {
            sent += runSize;
            return emit(runOffset, runSize);
        };
        const uint64_t end = offset + size;
        uint64_t runBegin = 0;
        bool inRun = false;
        for (uint64_t block = offset; block < end;) {
            const uint64_t first = block - block % shadowBlockBytes;
            const uint64_t next = first + shadowBlockBytes;
            const uint64_t blockStop = next < end ? next : end;
            const size_t index = size_t(first / shadowBlockBytes);
            const bool known = entry->valid[index];
            const bool whole = block == first && blockStop == blockEnd(first, allocation);
            bool changed;
            if (entry->bytes) {
                changed = !known ||
                    std::memcmp(entry->bytes.get() + block, base + block, size_t(blockStop - block)) != 0;
                if (changed) std::memcpy(entry->bytes.get() + block, base + block, size_t(blockStop - block));
                // A partially sent block is only known on the host where it was sent.
                entry->valid[index] = known || whole;
            } else if (whole) {
                const uint64_t hash = blockHash(base + block, size_t(blockStop - block));
                changed = !known || entry->hashes[index] != hash;
                entry->hashes[index] = hash;
                entry->valid[index] = true;
            } else {
                // Part of a block changes the host's whole block from the hash it had.
                changed = true;
                entry->valid[index] = false;
            }
            if (changed) {
                if (!inRun) { runBegin = block; inRun = true; }
            } else if (inRun) {
                const int result = send(runBegin, block - runBegin);
                if (result != success) { forgetLocked(key); return result; }
                inRun = false;
            }
            block = blockStop;
        }
        if (inRun) {
            const int result = send(runBegin, end - runBegin);
            if (result != success) { forgetLocked(key); return result; }
        }
        traffic.shadowed(kind, size, sent);
        return success;
    }

    // Records that [offset, offset + size) of `base` now matches the host's copy
    // (e.g. after a successful vkInvalidateMappedMemoryRanges into `base`).
    void noteRefreshed(uint64_t key, const uint8_t* base, uint64_t allocation,
                       uint64_t offset, uint64_t size) {
        if (!base || !size || offset >= allocation) return;
        const uint64_t end = size > allocation - offset ? allocation : offset + size;
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        Entry* entry = entryLocked(key, allocation);
        if (!entry) return;
        if (entry->bytes) std::memcpy(entry->bytes.get() + offset, base + offset, size_t(end - offset));
        for (uint64_t block = offset; block < end;) {
            const uint64_t first = block - block % shadowBlockBytes;
            const uint64_t blockStop = first + shadowBlockBytes < end ? first + shadowBlockBytes : end;
            const size_t index = size_t(first / shadowBlockBytes);
            const bool whole = block == first && blockStop == blockEnd(first, allocation);
            if (entry->bytes) {
                entry->valid[index] = entry->valid[index] || whole;
            } else if (whole) {
                entry->hashes[index] = blockHash(base + block, size_t(blockStop - block));
                entry->valid[index] = true;
            } else {
                entry->valid[index] = false;
            }
            block = blockStop;
        }
    }

    // Whether the host holds every block of [offset, offset + size) whole and the mapping
    // still has the bytes it was sent: a flush of the range would send nothing.
    bool unchanged(uint64_t key, const uint8_t* base, uint64_t allocation, uint64_t offset,
                   uint64_t size) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        auto found = entries_.find(key);
        if (found == entries_.end() || found->second.allocation < allocation || !size ||
            offset > allocation || size > allocation - offset) return false;
        const Entry& entry = found->second;
        for (uint64_t first = offset - offset % shadowBlockBytes; first < offset + size; first += shadowBlockBytes)
            if (!entry.valid[size_t(first / shadowBlockBytes)]) return false;
        if (entry.bytes) return std::memcmp(entry.bytes.get() + offset, base + offset, size_t(size)) == 0;
        // Hashes know whole blocks only.
        if (offset % shadowBlockBytes) return false;
        for (uint64_t first = offset; first < offset + size; first += shadowBlockBytes) {
            const uint64_t stop = blockEnd(first, allocation);
            if (stop > offset + size) return false;
            if (entry.hashes[size_t(first / shadowBlockBytes)] != blockHash(base + first, size_t(stop - first)))
                return false;
        }
        return true;
    }

    void forget(uint64_t key) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        forgetLocked(key);
    }

    // The device wrote [begin, end) behind the guest's back: every block it touches
    // is sent again until a flush or an invalidate makes it known once more.
    void forgetRange(uint64_t key, uint64_t begin, uint64_t end) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        auto found = entries_.find(key);
        if (found == entries_.end()) return;
        std::vector<bool>& valid = found->second.valid;
        const size_t last = valid.size();
        for (size_t index = size_t(begin / shadowBlockBytes);
             index < last && uint64_t(index) * shadowBlockBytes < end; ++index)
            valid[index] = false;
    }

private:
    // A copy of the host's bytes, or (no bytes) a hash of each whole block it holds.
    struct Entry {
        std::unique_ptr<uint8_t[]> bytes;
        std::vector<uint64_t> hashes;
        std::vector<bool> valid;
        size_t charged = 0;
        uint64_t allocation = 0;
    };

    static uint64_t blockEnd(uint64_t first, uint64_t allocation) {
        return first + shadowBlockBytes < allocation ? first + shadowBlockBytes : allocation;
    }

    Entry* entryLocked(uint64_t key, uint64_t allocation) {
        auto found = entries_.find(key);
        if (found != entries_.end()) {
            if (found->second.allocation >= allocation) return &found->second;
            forgetLocked(key);
        }
        if (!allocation) return nullptr;
        const size_t blocks = size_t((allocation + shadowBlockBytes - 1) / shadowBlockBytes);
        const size_t copyCharge = size_t(allocation) + blocks / 8 + sizeof(Entry);
        if (allocation <= shadowMaxAllocationBytes && copyCharge <= shadowMaxTotalBytes - used_ &&
            budget_.acquire(copyCharge)) {
            Entry entry;
            entry.bytes.reset(new (std::nothrow) uint8_t[size_t(allocation)]);
            if (entry.bytes) return storeLocked(key, std::move(entry), blocks, copyCharge, allocation);
            budget_.release(copyCharge);
        }
        const size_t hashCharge = blocks * sizeof(uint64_t) + blocks / 8 + sizeof(Entry);
        if (hashCharge > shadowMaxHashBytes - hashUsed_ || !budget_.acquire(hashCharge)) return nullptr;
        Entry entry;
        try {
            entry.hashes.assign(blocks, 0);
        } catch (...) {
            budget_.release(hashCharge);
            return nullptr;
        }
        return storeLocked(key, std::move(entry), blocks, hashCharge, allocation);
    }

    Entry* storeLocked(uint64_t key, Entry&& entry, size_t blocks, size_t charged, uint64_t allocation) {
        const bool copy = entry.bytes != nullptr;
        try {
            entry.valid.assign(blocks, false);
            entry.charged = charged;
            entry.allocation = allocation;
            Entry* stored = &entries_.emplace(key, std::move(entry)).first->second;
            (copy ? used_ : hashUsed_) += charged;
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
        (found->second.bytes ? used_ : hashUsed_) -= found->second.charged;
        entries_.erase(found);
    }

    void clearLocked() {
        for (auto& [key, entry] : entries_) budget_.release(entry.charged);
        entries_.clear();
        used_ = 0;
        hashUsed_ = 0;
    }

    Budget& budget_;
    size_t used_ = 0;
    size_t hashUsed_ = 0;
    caboose::lock_order::Mutex<std::mutex, caboose::lock_order::kFlushShadow> mutex_;
    std::unordered_map<uint64_t, Entry> entries_;
};

// Never destroyed: a process's exit runs static destructors while its other threads may
// still be inside the driver.
inline FlushShadow& flushShadow = *new FlushShadow;
inline thread_local uint64_t lastFlushCallSentBytes = 0;

} // namespace caboose::memory
