// SPDX-License-Identifier: MIT
#pragma once

// Which parts of host-coherent memory an application wrote since they were last sent. Before
// every submit the socket path must send what the application wrote to its coherent mappings;
// without a record of writes it sends every mapping, compared against a copy where one fits
// the shadow's budget and whole where it does not (a D3D11 game's 64 MiB chunks: over 100 MB
// a frame). The guest's copy of each coherent allocation is write-protected with userfaultfd,
// which reports the first write to each block to a thread of the watch's own and lets it
// proceed; the flush takes the written blocks and protects them again before reading them.
// No signal is involved, so it coexists with Wine's handlers. Where userfaultfd is not
// available the flush sends every mapping as before.
//
// Lazy readback: the same descriptor fills GPU-written memory on first use. An invalidate
// after a wait makes the blocks it would read back lazy instead (`makeLazy`): their pages
// are dropped, and the first access of any kind to one, by the application or the kernel,
// is a missing-page fault this watch hands to a filler thread of its own. The filler asks
// the phone for the block and the lazy blocks after it, as many as one round trip carries,
// on a connection of its own, and installs them write-protected, so a write after the fill
// is recorded as before. A block nothing touches never crosses the link. A fill takes no lock
// of the driver's, so a fault is served whatever the faulting thread holds. Since the fill's
// connection is not ordered with the device stream, a block is lazy only when everything the
// phone must have done to it is done: the GPU writes the invalidate covers have completed (the
// caller's to see), and the last bytes sent for the block went before a submission that has
// completed (`noteSent`, `makeLazy`'s `confirmedBelow`). Blocks holding writes not yet sent,
// sent and not yet confirmed, of memory a completion record is being stored into
// (`beginDelivery`), or outside the mapping are read as before. The invalidate leaves lazy
// blocks out of what it stores, a flush fills the lazy blocks of what it sends first
// (`settle`), and a completion record skips them (the phone's copy, which the fill reads,
// already holds its bytes). The watch's own lock is below every other.

#include <algorithm>
#include "memory_traffic.h"
#include <atomic>
#include <condition_variable>
#include <cstdlib>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <map>
#include <mutex>
#include <thread>
#include <vector>

#include <fcntl.h>
#include <linux/userfaultfd.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

namespace caboose::memory {

// Writes are recorded per block: one fault each, and a flush sends whole written blocks.
inline constexpr uint64_t watchBlockBytes = 16 * 1024;

// The written blocks of one watched allocation, as a bitmap. Pure bookkeeping, separate from
// the kernel interface so it can be tested anywhere.
class WrittenBlocks {
public:
    explicit WrittenBlocks(uint64_t bytes) : bytes_(bytes), bits_((blocks(bytes) + 63) / 64, 0) {}

    void mark(uint64_t offset) {
        if (offset >= bytes_) return;
        const uint64_t block = offset / watchBlockBytes;
        bits_[size_t(block / 64)] |= uint64_t(1) << (block % 64);
        any_ = true;
    }
    bool any() const { return any_; }
    bool marked(uint64_t offset) const {
        if (offset >= bytes_) return false;
        const uint64_t block = offset / watchBlockBytes;
        return bits_[size_t(block / 64)] & (uint64_t(1) << (block % 64));
    }
    // Calls take(begin, end) for each run of written blocks inside [from, to), clearing them;
    // runs are clipped to [from, to) and to the allocation.
    template <class Take>
    void take(uint64_t from, uint64_t to, Take&& take) {
        if (!any_) return;
        to = std::min(to, bytes_);
        if (from >= to) return;
        const uint64_t first = from / watchBlockBytes, last = (to - 1) / watchBlockBytes;
        uint64_t runStart = 0;
        bool inRun = false;
        for (uint64_t block = first; block <= last; ++block) {
            uint64_t& word = bits_[size_t(block / 64)];
            const uint64_t bit = uint64_t(1) << (block % 64);
            const bool written = word & bit;
            if (written) {
                word &= ~bit;
                if (!inRun) { runStart = block; inRun = true; }
            } else if (inRun) {
                take(std::max(from, runStart * watchBlockBytes), std::min(to, block * watchBlockBytes));
                inRun = false;
            }
        }
        if (inRun) take(std::max(from, runStart * watchBlockBytes), to);
        any_ = std::any_of(bits_.begin(), bits_.end(), [](uint64_t word) { return word != 0; });
    }

private:
    static uint64_t blocks(uint64_t bytes) { return (bytes + watchBlockBytes - 1) / watchBlockBytes; }
    uint64_t bytes_;
    std::vector<uint64_t> bits_;
    bool any_ = false;
};

// The lazy blocks of one allocation, as a bitmap, and which of them a filler has taken.
// Pure bookkeeping, tested anywhere.
class LazyBlocks {
public:
    explicit LazyBlocks(uint64_t bytes) : bytes_(bytes), bits_((blocks(bytes) + 63) / 64, 0) {}
    bool lazy(uint64_t block) const { return block < blocks(bytes_) && (bits_[size_t(block / 64)] >> (block % 64)) & 1; }
    void set(uint64_t block, bool on) {
        if (block >= blocks(bytes_)) return;
        uint64_t& word = bits_[size_t(block / 64)];
        const uint64_t bit = uint64_t(1) << (block % 64);
        if (on && !(word & bit)) { word |= bit; ++count_; }
        if (!on && (word & bit)) { word &= ~bit; --count_; }
    }
    uint64_t count() const { return count_; }
    uint64_t blockCount() const { return blocks(bytes_); }
    // A lazy block made lazy again (newer writes): a fill that read it before must read again.
    void renew(uint64_t block) {
        if (block >= blocks(bytes_)) return;
        if (generations_.empty()) generations_.assign(size_t(blocks(bytes_)), 0);
        ++generations_[size_t(block)];
    }
    uint32_t generation(uint64_t block) const {
        return block < generations_.size() ? generations_[size_t(block)] : 0;
    }
    // The lazy run that starts at `block`: at most `limit` blocks, all lazy, from `block` on.
    uint64_t runFrom(uint64_t block, uint64_t limit) const {
        uint64_t n = 0;
        while (n < limit && lazy(block + n)) ++n;
        return n;
    }
    // Calls take(begin, end) for each run of lazy blocks inside [from, to), in bytes, clipped.
    template <class Take>
    void runs(uint64_t from, uint64_t to, Take&& take) const {
        to = std::min(to, bytes_);
        if (!count_ || from >= to) return;
        uint64_t block = from / watchBlockBytes;
        const uint64_t last = (to - 1) / watchBlockBytes;
        while (block <= last) {
            if (!lazy(block)) { ++block; continue; }
            const uint64_t start = block;
            while (block <= last && lazy(block)) ++block;
            take(std::max(from, start * watchBlockBytes), std::min(to, block * watchBlockBytes));
        }
    }

private:
    static uint64_t blocks(uint64_t bytes) { return (bytes + watchBlockBytes - 1) / watchBlockBytes; }
    uint64_t bytes_;
    std::vector<uint64_t> bits_;
    std::vector<uint32_t> generations_;
    uint64_t count_ = 0;
};

// Lazy blocks one fill asks for: as many whole blocks as one invalidate round trip carries
// (ranges.h, payloadBytes), three of 16 KiB.
inline constexpr uint64_t lazyFillBlocks = 3;

class WriteWatch {
public:
    // Reads `size` bytes at `offset` of allocation `memory` of `device` from the phone into
    // `out`, on a connection that needs no lock of the driver's, once submission `after` (0:
    // none) has completed; false when they cannot be read (the fill then stores zeros, as a
    // lost device's memory reads). It returns, whatever becomes of the executor. Set by the
    // driver.
    using Fetch = bool (*)(uint64_t device, uint64_t memory, uint64_t offset, uint64_t size, uint8_t* out,
                           uint64_t after);
    void setFetch(Fetch fetch) { fetch_.store(fetch, std::memory_order_release); }

    // Whether writes to watched memory are recorded in this process.
    bool available() {
        std::call_once(opened_, [this] { open(); });
        return fd_ >= 0;
    }

    // Starts recording writes to [base, base + bytes), page-aligned memory this process
    // mapped privately and anonymously. Nothing in it counts as written yet.
    bool watch(uint8_t* base, uint64_t bytes) {
        if (!available() || !bytes || reinterpret_cast<uintptr_t>(base) % pageBytes() || bytes % pageBytes()) return false;
        uffdio_register reg{};
        reg.range = {reinterpret_cast<uintptr_t>(base), bytes};
        reg.mode = UFFDIO_REGISTER_MODE_WP;
        if (ioctl(fd_, UFFDIO_REGISTER, &reg) != 0) return false;
        std::lock_guard<std::mutex> lock(mutex_);
        if (!protect(reinterpret_cast<uintptr_t>(base), bytes, true)) {
            uffdio_range range{reinterpret_cast<uintptr_t>(base), bytes};
            ioctl(fd_, UFFDIO_UNREGISTER, &range);
            return false;
        }
        regions_.insert_or_assign(reinterpret_cast<uintptr_t>(base),
                                  Region{bytes, WrittenBlocks(bytes), LazyBlocks(bytes), ++serials_,
                                         std::vector<uint64_t>(size_t((bytes + watchBlockBytes - 1) / watchBlockBytes), 0),
                                         std::vector<uint64_t>(size_t((bytes + watchBlockBytes - 1) / watchBlockBytes), 0)});
        return true;
    }

    // Bytes of [begin, end) of the watched memory at `base` were sent on the device stream
    // before any submission numbered `submission` or later.
    void noteSent(const uint8_t* base, uint64_t begin, uint64_t end, uint64_t submission) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto found = regions_.find(reinterpret_cast<uintptr_t>(base));
        if (found == regions_.end() || begin >= end) return;
        auto& sent = found->second.sent;
        for (uint64_t block = begin / watchBlockBytes; block * watchBlockBytes < end && block < sent.size(); ++block)
            sent[size_t(block)] = submission;
    }
    // Makes the blocks of [begin, end) of the watched memory at `base` lazy where it can, and
    // calls lazy(begin, end) for every lazy run in [begin, end), new or earlier, so the caller
    // reads only the rest. A block can be lazy when all of it is inside [mapBegin, mapEnd)
    // (or ends the allocation there), it holds no write not yet sent, what was last sent for
    // it went before a completed submission (every submission below `confirmedBelow` has
    // completed) or before submission `after`, and no completion record is being stored into
    // the memory. With `after`, the writes are of submission `after`, which a wait reported
    // complete before its record came (completion_feed.h, Speculation): the fill reads the
    // block once that submission has completed. Called with the encoder held, so nothing the
    // encoder does meanwhile reads or writes a block it makes lazy.
    template <class Lazy>
    void makeLazy(uint8_t* base, uint64_t device, uint64_t memory, uint64_t allocation, uint64_t mapBegin,
                  uint64_t mapEnd, uint64_t begin, uint64_t end, uint64_t confirmedBelow, uint64_t after,
                  Lazy&& lazy) {
        if (after && confirmedBelow <= after) confirmedBelow = after + 1;
        std::vector<std::pair<uint64_t, uint64_t>> runs;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            auto found = regions_.find(reinterpret_cast<uintptr_t>(base));
            if (found == regions_.end()) return;
            Region& region = found->second;
            end = std::min({end, allocation, region.bytes});
            const bool can = fetch_.load(std::memory_order_acquire) && !region.delivering && allocation &&
                             !lazyDisabled() && (region.missing || registerMissing(found->first, region));
            if (can) {
                region.device = device, region.memory = memory, region.allocation = allocation;
                for (uint64_t block = begin / watchBlockBytes; block * watchBlockBytes < end; ++block) {
                    const uint64_t first = block * watchBlockBytes;
                    const uint64_t stop = std::min(first + watchBlockBytes, allocation);
                    if (first < mapBegin || stop > mapEnd || region.blocks.marked(first) ||
                        (block < region.sent.size() && region.sent[size_t(block)] >= confirmedBelow &&
                         region.sent[size_t(block)]))
                        continue;
                    if (region.lazy.lazy(block)) {
                        // A fill in flight read the block before these writes: it reads again.
                        region.lazy.renew(block);
                        region.after[size_t(block)] = std::max(region.after[size_t(block)], after);
                        continue;
                    }
                    const uint64_t pages = std::min(first + watchBlockBytes, region.bytes);
                    if (madvise(base + first, size_t(pages - first), MADV_DONTNEED) != 0) continue;
                    region.lazy.set(block, true);
                    region.after[size_t(block)] = after;
                    made_.fetch_add(stop - first, std::memory_order_relaxed);
                    traffic::counters().lazy(stop - first, 0, 0);
                }
            }
            region.lazy.runs(begin, end, [&](uint64_t b, uint64_t e) { runs.emplace_back(b, e); });
        }
        for (const auto& [b, e] : runs) lazy(b, e);
    }
    // Calls lazy(begin, end) for each lazy run in [begin, end) of the memory at `base`.
    template <class Lazy>
    void lazyRuns(const uint8_t* base, uint64_t begin, uint64_t end, Lazy&& lazy) {
        std::vector<std::pair<uint64_t, uint64_t>> runs;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            auto found = regions_.find(reinterpret_cast<uintptr_t>(base));
            if (found == regions_.end()) return;
            found->second.lazy.runs(begin, end, [&](uint64_t b, uint64_t e) { runs.emplace_back(b, e); });
        }
        for (const auto& [b, e] : runs) lazy(b, e);
    }
    // Fills the lazy blocks of [begin, end) of the memory at `base` now: before the encoder sends
    // them, or before the memory is unmapped.
    void settle(uint8_t* base, uint64_t begin, uint64_t end) {
        const Fetch fetch = fetch_.load(std::memory_order_acquire);
        for (;;) {
            Fill fill;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                auto found = regions_.find(reinterpret_cast<uintptr_t>(base));
                if (found == regions_.end() || !found->second.lazy.count()) return;
                bool any = false;
                found->second.lazy.runs(begin, end, [&](uint64_t b, uint64_t) {
                    if (!any) { any = true; fill = planLocked(found->first, found->second, b / watchBlockBytes); }
                });
                if (!any) return;
            }
            completeFill(fill, fetch);
        }
    }
    // A completion record is about to store [offset, offset + size) of the memory at `base`:
    // no block of it becomes lazy until `endDelivery`, and take(begin, end) is called for each
    // part not already lazy, which is all it may write (a lazy block's fill reads the phone's
    // copy, which holds the record's bytes). Unwatched memory is written whole.
    template <class Take>
    void beginDelivery(const uint8_t* base, uint64_t offset, uint64_t size, Take&& take) {
        std::vector<std::pair<uint64_t, uint64_t>> parts;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            auto found = regions_.find(reinterpret_cast<uintptr_t>(base));
            if (found == regions_.end()) {
                parts.emplace_back(offset, offset + size);
            } else {
                ++found->second.delivering;
                uint64_t from = offset;
                found->second.lazy.runs(offset, offset + size, [&](uint64_t b, uint64_t e) {
                    if (b > from) parts.emplace_back(from, b);
                    from = e;
                });
                if (from < offset + size) parts.emplace_back(from, offset + size);
            }
        }
        for (const auto& [b, e] : parts) take(b, e);
    }
    void endDelivery(const uint8_t* base) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto found = regions_.find(reinterpret_cast<uintptr_t>(base));
        if (found != regions_.end() && found->second.delivering) --found->second.delivering;
    }
    struct LazyStats { uint64_t made = 0, filled = 0, fills = 0; };
    LazyStats lazyStats() const {
        return {made_.load(std::memory_order_relaxed), filled_.load(std::memory_order_relaxed),
                fills_.load(std::memory_order_relaxed)};
    }

    // Stops recording writes to the watched memory at `base`, before it is unmapped.
    void unwatch(uint8_t* base) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto found = regions_.find(reinterpret_cast<uintptr_t>(base));
        if (found == regions_.end()) return;
        uffdio_range range{found->first, found->second.bytes};
        ioctl(fd_, UFFDIO_UNREGISTER, &range);
        regions_.erase(found);
    }
    bool watched(const uint8_t* base) {
        std::lock_guard<std::mutex> lock(mutex_);
        return regions_.count(reinterpret_cast<uintptr_t>(base)) != 0;
    }
    // Calls take(begin, end), offsets from `base`, for each run of blocks written in
    // [from, to) of the watched memory at `base`, and protects them again first: a write
    // made while they are being sent is recorded for the next flush. False when the memory
    // is not watched (all of it must be sent).
    template <class Take>
    bool written(const uint8_t* base, uint64_t from, uint64_t to, Take&& take) {
        std::vector<std::pair<uint64_t, uint64_t>> runs;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            auto found = regions_.find(reinterpret_cast<uintptr_t>(base));
            if (found == regions_.end()) return false;
            found->second.blocks.take(from, to, [&](uint64_t begin, uint64_t end) { runs.emplace_back(begin, end); });
            for (const auto& [begin, end] : runs) {
                const uintptr_t first = (found->first + begin) / pageBytes() * pageBytes();
                const uintptr_t last = (found->first + end + pageBytes() - 1) / pageBytes() * pageBytes();
                if (!protect(first, last - first, true)) {
                    // Unprotected memory records nothing: stop watching it, and send it whole.
                    uffdio_range range{found->first, found->second.bytes};
                    ioctl(fd_, UFFDIO_UNREGISTER, &range);
                    regions_.erase(found);
                    return false;
                }
            }
        }
        for (const auto& [begin, end] : runs) take(begin, end);
        return true;
    }
    uint64_t faults() const { return faults_.load(std::memory_order_relaxed); }

private:
    struct Region {
        uint64_t bytes;
        WrittenBlocks blocks;
        LazyBlocks lazy;
        uint64_t serial = 0;       // this watch of the memory, not a later one at the same address
        std::vector<uint64_t> sent;  // per block: sent before this submission (noteSent), or 0
        std::vector<uint64_t> after;  // per lazy block: read once this submission has completed
        bool missing = false;      // registered for missing-page faults (the first lazy block)
        uint32_t delivering = 0;   // completion records being stored into it
        uint64_t device = 0, memory = 0, allocation = 0;
    };
    // One fill: whole blocks [first, first + count) of the region at `base`.
    struct Fill {
        uintptr_t base = 0;
        uint64_t serial = 0, first = 0, count = 0, device = 0, memory = 0, allocation = 0, bytes = 0, after = 0;
        uint32_t generations[lazyFillBlocks] = {};
    };

    // CABOOSE_LAZY_READBACK=0 reads every invalidated range eagerly.
    static bool lazyDisabled() {
        static const bool disabled = [] {
            const char* value = std::getenv("CABOOSE_LAZY_READBACK");
            return value && value[0] == '0' && !value[1];
        }();
        return disabled;
    }
    // Missing-page faults are taken only in memory that has had lazy blocks: elsewhere a
    // page's first use costs nothing more than it did.
    bool registerMissing(uintptr_t start, Region& region) {
        if (!fillerStarted_) {
            try {
                std::thread([this] { fillLoop(); }).detach();
            } catch (...) {
                return false;
            }
            fillerStarted_ = true;
        }
        uffdio_register reg{};
        reg.range = {start, region.bytes};
        reg.mode = UFFDIO_REGISTER_MODE_MISSING | UFFDIO_REGISTER_MODE_WP;
        if (ioctl(fd_, UFFDIO_REGISTER, &reg) != 0) return false;
        region.missing = true;
        return true;
    }
    Fill planLocked(uintptr_t start, const Region& region, uint64_t block) const {
        Fill fill;
        fill.base = start; fill.serial = region.serial; fill.first = block;
        fill.count = region.lazy.runFrom(block, lazyFillBlocks);
        for (uint64_t i = 0; i < fill.count; ++i) {
            fill.generations[i] = region.lazy.generation(block + i);
            fill.after = std::max(fill.after, region.after[size_t(block + i)]);
        }
        fill.device = region.device; fill.memory = region.memory; fill.allocation = region.allocation;
        fill.bytes = region.bytes;
        return fill;
    }
    // Installs each missing page of [start, start + bytes) from `data`, write-protected.
    bool installLocked(uintptr_t start, const uint8_t* data, uint64_t bytes) {
        for (uint64_t at = 0; at < bytes; at += pageBytes()) {
            uffdio_copy copy{};
            copy.dst = start + at;
            copy.src = reinterpret_cast<uintptr_t>(data + at);
            copy.len = pageBytes();
            copy.mode = UFFDIO_COPY_MODE_WP;
            while (ioctl(fd_, UFFDIO_COPY, &copy) != 0) {
                if (errno == EEXIST) break;  // present already: nothing to install
                if (errno == EAGAIN) { copy.copy = 0; continue; }
                return false;
            }
        }
        return true;
    }
    // Reads a fill's blocks and installs them, unless one was made lazy again meanwhile (newer
    // GPU writes: it reads again) or the memory went.
    void completeFill(Fill fill, Fetch fetch) {
        for (;;) {
            const uint64_t begin = fill.first * watchBlockBytes;
            const uint64_t span = std::min(fill.count * watchBlockBytes, fill.bytes - begin);
            std::vector<uint8_t> data(size_t(span), 0);
            const uint64_t readable = fill.allocation > begin ? std::min(span, fill.allocation - begin) : 0;
            const bool read = fetch && readable && fetch(fill.device, fill.memory, begin, readable, data.data(), fill.after);
            if (!read) std::fill(data.begin(), data.end(), 0);
            std::lock_guard<std::mutex> lock(mutex_);
            auto found = regions_.find(fill.base);
            if (found == regions_.end() || found->second.serial != fill.serial) return;
            Region& region = found->second;
            bool renewed = false;
            for (uint64_t i = 0; i < fill.count; ++i)
                renewed = renewed || (region.lazy.lazy(fill.first + i) &&
                                      region.lazy.generation(fill.first + i) != fill.generations[i]);
            if (renewed) {
                fill = planLocked(found->first, region, fill.first);
                if (!fill.count) return;
                continue;
            }
            for (uint64_t i = 0; i < fill.count; ++i) {
                const uint64_t block = fill.first + i;
                if (!region.lazy.lazy(block)) continue;
                const uint64_t at = block * watchBlockBytes;
                const uint64_t bytes = std::min(watchBlockBytes, region.bytes - at);
                installLocked(found->first + at, data.data() + (at - begin), bytes);
                region.lazy.set(block, false);
                region.after[size_t(block)] = 0;
            }
            filled_.fetch_add(readable, std::memory_order_relaxed);
            fills_.fetch_add(1, std::memory_order_relaxed);
            traffic::counters().lazy(0, readable, 1);
            return;
        }
    }
    // The filler: one fill at a time, each for the block a fault found and the lazy blocks
    // after it. The serving thread never waits for the phone.
    void fillLoop() {
        for (;;) {
            Fill fill;
            {
                std::unique_lock<std::mutex> lock(mutex_);
                queued_.wait(lock, [&] { return !requests_.empty(); });
                const auto [start, block] = requests_.front();
                requests_.erase(requests_.begin());
                auto found = regions_.find(start);
                if (found == regions_.end()) continue;
                if (!found->second.lazy.lazy(block)) {
                    // Filled since it was asked for: wake the faulting thread.
                    uffdio_range range{start + block * watchBlockBytes,
                                       std::min(watchBlockBytes, found->second.bytes - block * watchBlockBytes)};
                    ioctl(fd_, UFFDIO_WAKE, &range);
                    continue;
                }
                fill = planLocked(start, found->second, block);
            }
            completeFill(fill, fetch_.load(std::memory_order_acquire));
        }
    }
    // A missing page: of a lazy block, a fill (the filler wakes the thread); of any other block
    // of the memory, a page never used before, installed zero and write-protected.
    void missingLocked(uintptr_t address) {
        auto found = regions_.upper_bound(address);
        if (found != regions_.begin()) {
            --found;
            Region& region = found->second;
            if (address < found->first + region.bytes) {
                const uint64_t block = (address - found->first) / watchBlockBytes;
                if (region.lazy.lazy(block)) {
                    const std::pair<uintptr_t, uint64_t> request{found->first, block};
                    if (std::find(requests_.begin(), requests_.end(), request) == requests_.end()) {
                        requests_.push_back(request);
                        queued_.notify_one();
                    }
                    return;
                }
                static const std::vector<uint8_t> zeros(size_t(watchBlockBytes), 0);
                const uint64_t at = block * watchBlockBytes;
                if (installLocked(found->first + at, zeros.data(), std::min(watchBlockBytes, region.bytes - at))) return;
            }
        }
        uffdio_zeropage zero{};
        zero.range = {address / pageBytes() * pageBytes(), pageBytes()};
        ioctl(fd_, UFFDIO_ZEROPAGE, &zero);
    }

    static uint64_t pageBytes() {
        static const uint64_t bytes = uint64_t(sysconf(_SC_PAGESIZE));
        return bytes;
    }

    void open() {
        // Only through the device: its descriptors also take the kernel's own writes (a
        // read() into a mapping), which a user-mode-only descriptor from the system call
        // would fail with EFAULT.
        const int device = ::open("/dev/userfaultfd", O_RDWR | O_CLOEXEC);
        if (device < 0) return;
        const int fd = ioctl(device, USERFAULTFD_IOC_NEW, O_CLOEXEC | O_NONBLOCK);
        ::close(device);
        if (fd < 0) return;
        // Unpopulated pages must be protected too: a fresh allocation is all unpopulated.
        uffdio_api api{};
        api.api = UFFD_API;
        api.features = UFFD_FEATURE_WP_UNPOPULATED;
        if (ioctl(fd, UFFDIO_API, &api) != 0 || !(api.features & UFFD_FEATURE_WP_UNPOPULATED)) {
            ::close(fd);
            return;
        }
        try {
            std::thread([this, fd] { serve(fd); }).detach();
        } catch (...) {
            ::close(fd);
            return;
        }
        fd_ = fd;
    }

    bool protect(uintptr_t start, uint64_t bytes, bool on) {
        uffdio_writeprotect wp{};
        wp.range = {start, bytes};
        wp.mode = on ? UFFDIO_WRITEPROTECT_MODE_WP : 0;
        while (ioctl(fd_, UFFDIO_WRITEPROTECT, &wp) != 0) {
            if (errno != EAGAIN && errno != EINTR) return false;
        }
        return true;
    }

    // Records each first write to a protected block and lets the writer go on.
    void serve(int fd) {
        for (;;) {
            pollfd ready{fd, POLLIN, 0};
            if (poll(&ready, 1, -1) < 0 && errno != EINTR) return;
            uffd_msg message;
            const ssize_t got = read(fd, &message, sizeof(message));
            if (got != ssize_t(sizeof(message))) continue;
            if (message.event != UFFD_EVENT_PAGEFAULT) continue;
            const uintptr_t address = uintptr_t(message.arg.pagefault.address);
            std::lock_guard<std::mutex> lock(mutex_);
            if (!(message.arg.pagefault.flags & UFFD_PAGEFAULT_FLAG_WP)) {
                missingLocked(address);
                continue;
            }
            faults_.fetch_add(1, std::memory_order_relaxed);
            auto found = regions_.upper_bound(address);
            if (found != regions_.begin()) {
                --found;
                if (address < found->first + found->second.bytes) {
                    const uint64_t offset = address - found->first;
                    const uint64_t block = offset / watchBlockBytes * watchBlockBytes;
                    const uint64_t end = std::min(found->second.bytes, block + watchBlockBytes);
                    found->second.blocks.mark(offset);
                    // The whole block goes unprotected: one fault per block, not per page.
                    if (protect(found->first + block, end - block, false)) continue;
                }
            }
            // Not memory this watch protects (anymore): let the writer go on regardless.
            const uintptr_t page = address / pageBytes() * pageBytes();
            protect(page, pageBytes(), false);
        }
    }

    std::once_flag opened_;
    int fd_ = -1;
    std::mutex mutex_;
    std::map<uintptr_t, Region> regions_;
    std::atomic<uint64_t> faults_{0};
    std::atomic<Fetch> fetch_{nullptr};
    bool fillerStarted_ = false;
    std::condition_variable queued_;
    std::vector<std::pair<uintptr_t, uint64_t>> requests_;
    std::atomic<uint64_t> made_{0}, filled_{0}, fills_{0};
    uint64_t serials_ = 0;
};

// Set while the coherent upkeep invalidates the writes of submissions that have completed: what
// it reads may be lazy at once. Any other invalidate's may be lazy only once every submission
// has completed (a wait may have returned before its submission did: completion_feed.h,
// Speculation).
inline thread_local bool completedWritesOnly = false;
// Set while the coherent upkeep invalidates writes that include those of submission
// `lazyAfterSerial` or earlier, which a wait reported complete before their records came: what
// it makes lazy is read once that submission has completed, and what it reads at once is
// ordered behind it by the device stream's WAIT_SERIAL (completion_feed.h, Speculation).
inline thread_local uint64_t lazyAfterSerial = 0;

inline WriteWatch& writeWatch() {
    static WriteWatch* instance = new WriteWatch;  // its thread outlives static destruction
    return *instance;
}

}  // namespace caboose::memory
