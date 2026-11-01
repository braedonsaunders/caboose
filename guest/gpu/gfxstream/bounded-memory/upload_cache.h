// SPDX-License-Identifier: MIT
#pragma once

// The guest side of the phone's upload cache (docs/gpu-live.md, "Upload cache"). With hello
// feature 0x8000 the phone keeps 4096-byte pieces of flushed memory by the BLAKE3-256 of their
// bytes. A process asks once per executor for the 16-byte prefixes of the keys the store holds
// and how many pieces it may ask the phone to store (UPLOAD_INVENTORY, one round trip on its
// device stream). From then on a flush cuts each whole 4096 bytes of an application range of at
// least 16 KiB, counted from the range's offset, into a piece. A piece the host already holds
// unchanged costs nothing, as before; a changed one the process knows goes as its prefix
// (kind 2); a changed one of staging memory (image uploads, not per-frame vertex or uniform
// data) as its bytes for the phone to store (kind 1) while the allowance lasts; and the rest is
// flushed as before.

#include "ranges.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <unordered_set>
#include <vector>

namespace caboose::upload_cache {

// Wire, little-endian. Matches upload-cache/vectors.json.
inline constexpr uint32_t kInventoryOpcode = 0x4342FE11;
inline constexpr uint32_t kInventoryPacketBytes = 16;
inline constexpr uint32_t kInventoryVersion = 1;
inline constexpr uint32_t kInventoryMaxPrefixes = 262144;
inline constexpr uint32_t kMaxAllowance = 65536;
inline constexpr size_t kPieceBytes = 4096;
inline constexpr size_t kPrefixBytes = 16;
inline constexpr uint64_t kMinRangeBytes = 16 * 1024;
// A piece's data, in place of a fragment's `u64 length, bytes`: the length with bit 63 set and
// exactly 4096 below it, then u32 kind, then the bytes (kind 1) or the prefix (kind 2).
inline constexpr uint64_t kPieceLength = (uint64_t(1) << 63) | kPieceBytes;
inline constexpr size_t kPieceHeaderBytes = 12;

enum Kind : uint32_t { literal = 0, store = 1, stored = 2 };

using Prefix = std::array<uint8_t, kPrefixBytes>;

struct PrefixHash {
    size_t operator()(const Prefix& prefix) const noexcept {
        size_t value = 0;
        std::memcpy(&value, prefix.data(), sizeof(value));
        return value;
    }
};

inline void putLe32(uint8_t* p, uint32_t value) {
    for (int i = 0; i < 4; ++i) p[i] = static_cast<uint8_t>(value >> (8 * i));
}
inline uint32_t getLe32(const uint8_t* p) {
    return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24;
}

inline void encodeInventoryRequest(uint8_t out[kInventoryPacketBytes]) {
    putLe32(out, kInventoryOpcode);
    putLe32(out + 4, kInventoryPacketBytes);
    putLe32(out + 8, kInventoryVersion);
    putLe32(out + 12, 0);
}

// The reply's 8-byte head: false when it is malformed.
inline bool inventoryHead(const uint8_t head[8], uint32_t* count, uint32_t* allowance) {
    *count = getLe32(head);
    *allowance = getLe32(head + 4);
    return *count <= kInventoryMaxPrefixes && *allowance <= kMaxAllowance;
}

inline void encodePieceHeader(uint8_t out[kPieceHeaderBytes], Kind kind) {
    for (int i = 0; i < 8; ++i) out[i] = static_cast<uint8_t>(kPieceLength >> (8 * i));
    putLe32(out + 8, kind);
}

// The bytes a piece's data takes on the wire after its fragment's range.
inline constexpr uint64_t pieceDataBytes(Kind kind) {
    return kPieceHeaderBytes + (kind == store ? kPieceBytes : kPrefixBytes);
}

inline bool zeroPiece(const uint8_t* piece) {
    uint64_t any = 0;
    for (size_t i = 0; i < kPieceBytes; i += sizeof(uint64_t)) {
        uint64_t word;
        std::memcpy(&word, piece + i, sizeof(word));
        any |= word;
    }
    return any == 0;
}

// The first piece of a chunk [offset, offset + size) of a range that starts at `rangeOffset`:
// pieces are counted from the range's offset, whichever chunk they fall in.
inline uint64_t firstPiece(uint64_t rangeOffset, uint64_t offset) {
    return offset + (kPieceBytes - (offset - rangeOffset) % kPieceBytes) % kPieceBytes;
}

// What the process's store holds, and how many pieces it may still ask it to store. Unknown
// until the first cacheable flush asks; a failed inventory, or one the memory budget cannot
// hold, leaves the process flushing as before. A new executor forgets everything.
class Inventory {
public:
    enum class State { unknown, loaded, unavailable };

    explicit Inventory(memory::Budget& budget = memory::processBudget) : budget_(budget) {}
    ~Inventory() { budget_.release(charged_); }

    // `load(std::vector<uint8_t>* prefixes, uint32_t* allowance)` performs UPLOAD_INVENTORY:
    // true with the concatenated prefixes, false if the phone could not answer.
    template <class Load>
    State ensure(Load&& load) {
        std::lock_guard<std::mutex> lock(mutex_);
        refreshLocked();
        if (state_ != State::unknown) return state_;
        const uint64_t epoch = epoch_.load(std::memory_order_acquire);
        std::vector<uint8_t> bytes;
        uint32_t allowance = 0;
        const bool answered = load(&bytes, &allowance) && bytes.size() % kPrefixBytes == 0 &&
                              bytes.size() / kPrefixBytes <= kInventoryMaxPrefixes &&
                              allowance <= kMaxAllowance;
        // An executor change during the request makes its answer another store's.
        if (epoch != epoch_.load(std::memory_order_acquire)) return State::unknown;
        const size_t count = answered ? bytes.size() / kPrefixBytes : 0;
        if (!answered || !budget_.acquire(count * sizeof(Prefix))) {
            state_ = State::unavailable;
            return state_;
        }
        charged_ = count * sizeof(Prefix);
        prefixes_.resize(count);
        for (size_t i = 0; i < count; ++i)
            std::memcpy(prefixes_[i].data(), bytes.data() + i * kPrefixBytes, kPrefixBytes);
        std::sort(prefixes_.begin(), prefixes_.end());
        allowance_ = allowance;
        state_ = State::loaded;
        return state_;
    }
    bool contains(const Prefix& prefix) {
        std::lock_guard<std::mutex> lock(mutex_);
        refreshLocked();
        return state_ == State::loaded &&
               std::binary_search(prefixes_.begin(), prefixes_.end(), prefix);
    }
    // Whether a piece could go as anything but its bytes: the store holds some, or would
    // take some. Otherwise a flush need not hash its pieces.
    bool offers() {
        std::lock_guard<std::mutex> lock(mutex_);
        refreshLocked();
        return state_ == State::loaded && (!prefixes_.empty() || allowance_ != 0);
    }
    // One piece of the allowance, if any is left.
    bool takeAllowance() {
        std::lock_guard<std::mutex> lock(mutex_);
        refreshLocked();
        if (state_ != State::loaded || !allowance_) return false;
        --allowance_;
        return true;
    }
    // A new executor connected. Lock-free: the connection may be made inside an encoder call.
    void reset() { epoch_.fetch_add(1, std::memory_order_acq_rel); }
    uint64_t epoch() const { return epoch_.load(std::memory_order_acquire); }

private:
    void refreshLocked() {
        const uint64_t epoch = epoch_.load(std::memory_order_acquire);
        if (epoch == seenEpoch_) return;
        seenEpoch_ = epoch;
        state_ = State::unknown;
        allowance_ = 0;
        std::vector<Prefix>().swap(prefixes_);
        budget_.release(charged_);
        charged_ = 0;
    }
    memory::Budget& budget_;
    std::mutex mutex_;
    std::atomic<uint64_t> epoch_{0};
    uint64_t seenEpoch_ = 0;
    State state_ = State::unknown;
    std::vector<Prefix> prefixes_;
    uint32_t allowance_ = 0;
    size_t charged_ = 0;
};

inline Inventory& inventory() {
    static Inventory instance;
    return instance;
}

// The pieces one device stream stored. Only that stream names them: another stream's
// commands may reach the decoder first. Used under the stream's encoder lock. At most an
// allowance of pieces (65536) is held.
class StreamKnown {
public:
    bool contains(const Inventory& inventory, const Prefix& prefix) {
        refresh(inventory);
        return prefixes_.count(prefix) != 0;
    }
    void add(const Inventory& inventory, const Prefix& prefix) {
        refresh(inventory);
        if (prefixes_.size() < kMaxAllowance) prefixes_.insert(prefix);
    }
    size_t size(const Inventory& inventory) {
        refresh(inventory);
        return prefixes_.size();
    }

private:
    void refresh(const Inventory& inventory) {
        const uint64_t epoch = inventory.epoch();
        if (epoch == seenEpoch_) return;
        seenEpoch_ = epoch;
        std::unordered_set<Prefix, PrefixHash>().swap(prefixes_);
    }
    uint64_t seenEpoch_ = 0;
    std::unordered_set<Prefix, PrefixHash> prefixes_;
};

// What the process's pieces went as, for CABOOSE_PRIVATE_GPU_UPLOAD_LOG=1.
struct Counts {
    std::atomic<uint64_t> unchanged{0}, stored{0}, namedInventory{0}, namedStream{0}, literal{0};
};
inline Counts& counts() {
    static Counts instance;
    return instance;
}
// At most every 5 seconds, when the log is on: one line of the counts so far.
inline void report() {
    static const bool enabled = [] {
        const char* value = std::getenv("CABOOSE_PRIVATE_GPU_UPLOAD_LOG");
        return value && value[0] == '1';
    }();
    if (!enabled) return;
    static std::atomic<int64_t> last{0};
    const int64_t now = std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
    int64_t prior = last.load(std::memory_order_relaxed);
    if (now - prior < 5 || !last.compare_exchange_strong(prior, now)) return;
    const Counts& c = counts();
    std::fprintf(stderr,
                 "CABOOSE_GPU_UPLOADS unchanged=%llu stored=%llu named_inventory=%llu named_stream=%llu literal=%llu\n",
                 (unsigned long long)c.unchanged.load(), (unsigned long long)c.stored.load(),
                 (unsigned long long)c.namedInventory.load(), (unsigned long long)c.namedStream.load(),
                 (unsigned long long)c.literal.load());
}

// Decides what a changed whole piece of a cacheable range is sent as (the caller sends an
// unchanged one as nothing). `hash(piece, Prefix*)` fills the first 16 bytes of the piece's
// BLAKE3-256; `mayStore` is whether its memory is staging. The inventory must be loaded.
template <class Hash>
Kind plan(Inventory& inventory, StreamKnown& known, const uint8_t* piece, bool mayStore,
          Hash&& hash, Prefix* prefix) {
    Counts& c = counts();
    if (zeroPiece(piece)) {
        c.literal.fetch_add(1, std::memory_order_relaxed);
        return literal;
    }
    hash(piece, prefix);
    if (inventory.contains(*prefix)) {
        c.namedInventory.fetch_add(1, std::memory_order_relaxed);
        return stored;
    }
    if (known.contains(inventory, *prefix)) {
        c.namedStream.fetch_add(1, std::memory_order_relaxed);
        return stored;
    }
    if (mayStore && inventory.takeAllowance()) {
        c.stored.fetch_add(1, std::memory_order_relaxed);
        return store;
    }
    c.literal.fetch_add(1, std::memory_order_relaxed);
    return literal;
}

// Staging memory: bound only to buffers that are copied from (image uploads), never to ones
// the device reads per draw, whose contents change every frame and are not worth storing.
inline bool staging(uint32_t bufferUsage) {
    constexpr uint32_t transferSource = 0x1;  // VK_BUFFER_USAGE_TRANSFER_SRC_BIT
    constexpr uint32_t perDraw = 0x4 | 0x8 | 0x10 | 0x20 | 0x40 | 0x80 | 0x100;
    // UNIFORM_TEXEL, STORAGE_TEXEL, UNIFORM, STORAGE, INDEX, VERTEX, INDIRECT
    return (bufferUsage & transferSource) && !(bufferUsage & perDraw);
}

// Writes a piece's data. A stored piece is its prefix. A piece to store is copied, the copy
// hashed and written, and that hash becomes known on this stream: the application may write
// the mapping during the flush, and the key the phone stores is the hash of what it received.
template <class Write, class Hash>
void writePiece(Kind kind, const uint8_t* source, const Prefix& prefix, Inventory& inventory,
                StreamKnown& known, Write&& write, Hash&& hash) {
    uint8_t header[kPieceHeaderBytes];
    encodePieceHeader(header, kind);
    write(header, sizeof(header));
    if (kind == stored) {
        write(prefix.data(), prefix.size());
        return;
    }
    uint8_t copy[kPieceBytes];
    std::memcpy(copy, source, sizeof(copy));
    Prefix sent;
    hash(copy, &sent);
    write(copy, sizeof(copy));
    known.add(inventory, sent);
}

}  // namespace caboose::upload_cache
