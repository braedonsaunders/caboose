// SPDX-License-Identifier: MIT
#pragma once

// The guest side of the phone's persistent shader cache (docs/gpu-live.md, "Shader cache").
// With hello feature 0x2000 the phone keeps every SPIR-V module a computer sends, under its
// BLAKE3 hash, across sessions. A process asks once for the keys the phone holds
// (SHADER_INVENTORY, one round trip on its device stream); from then on vkCreateShaderModule
// sends a 48-byte token in place of the code of any module the phone holds, including any the
// process already sent as code on its single device stream.

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <unordered_set>
#include <vector>

namespace caboose::shader_cache {

// Wire, little-endian. Matches the phone's shader_store.h and vectors.json.
inline constexpr uint32_t kTokenMagic = 0x4D534243;  // "CBSM"
inline constexpr uint32_t kTokenVersion = 1;
inline constexpr size_t kTokenBytes = 48;
inline constexpr size_t kKeyBytes = 32;
inline constexpr size_t kMinCodeBytes = 256;
inline constexpr size_t kMaxCodeBytes = 16u * 1024u * 1024u;
inline constexpr uint32_t kInventoryOpcode = 0x4342FE10;
inline constexpr uint32_t kInventoryPacketBytes = 16;
inline constexpr uint32_t kInventoryVersion = 1;
inline constexpr uint32_t kInventoryMaxKeys = 16384;

using Key = std::array<uint8_t, kKeyBytes>;

struct KeyHash {
    size_t operator()(const Key& key) const noexcept {
        size_t value = 0;
        std::memcpy(&value, key.data(), sizeof(value));
        return value;
    }
};

inline void putLe32(uint8_t* p, uint32_t value) {
    for (int i = 0; i < 4; ++i) p[i] = static_cast<uint8_t>(value >> (8 * i));
}
inline uint32_t getLe32(const uint8_t* p) {
    return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24;
}

inline bool cacheable(size_t codeSize) {
    return codeSize >= kMinCodeBytes && codeSize <= kMaxCodeBytes && codeSize % 4 == 0;
}

inline void encodeInventoryRequest(uint8_t out[kInventoryPacketBytes]) {
    putLe32(out, kInventoryOpcode);
    putLe32(out + 4, kInventoryPacketBytes);
    putLe32(out + 8, kInventoryVersion);
    putLe32(out + 12, 0);
}

// The reply's 8-byte head: the key count, or -1 for a malformed head.
inline int64_t inventoryCount(const uint8_t head[8]) {
    const uint32_t count = getLe32(head), reserved = getLe32(head + 4);
    return reserved == 0 && count <= kInventoryMaxKeys ? int64_t(count) : -1;
}

inline void encodeToken(uint8_t out[kTokenBytes], const Key& key, uint32_t codeSize) {
    putLe32(out, kTokenMagic);
    putLe32(out + 4, kTokenVersion);
    putLe32(out + 8, codeSize);
    putLe32(out + 12, 0);
    std::memcpy(out + 16, key.data(), kKeyBytes);
}

// The keys this process may name by token. Unknown until the first cacheable module asks
// the phone; a failed inventory leaves the process sending code. A new executor (a
// reconnect, perhaps to another phone) forgets everything.
class Known {
public:
    enum class State { unknown, loaded, unavailable };

    // `load(std::vector<uint8_t>* keys)` performs SHADER_INVENTORY: true with the
    // concatenated keys, false if the phone could not answer.
    template <class Load>
    State ensure(Load&& load) {
        std::lock_guard<std::mutex> lock(mutex_);
        refreshLocked();
        if (state_ != State::unknown) return state_;
        const uint64_t epoch = epoch_.load(std::memory_order_acquire);
        std::vector<uint8_t> keys;
        const bool answered = load(&keys) && keys.size() % kKeyBytes == 0;
        // An executor change during the request makes its answer another phone's.
        if (epoch != epoch_.load(std::memory_order_acquire)) return State::unknown;
        if (!answered) {
            state_ = State::unavailable;
            return state_;
        }
        for (size_t offset = 0; offset < keys.size(); offset += kKeyBytes) {
            Key key;
            std::memcpy(key.data(), keys.data() + offset, kKeyBytes);
            keys_.insert(key);
        }
        state_ = State::loaded;
        return state_;
    }
    bool contains(const Key& key) {
        std::lock_guard<std::mutex> lock(mutex_);
        refreshLocked();
        return state_ == State::loaded && keys_.count(key) != 0;
    }
    void add(const Key& key) {
        std::lock_guard<std::mutex> lock(mutex_);
        refreshLocked();
        if (state_ == State::loaded) keys_.insert(key);
    }
    // A new executor connected. Lock-free: the connection may be made inside an encoder call.
    void reset() { epoch_.fetch_add(1, std::memory_order_acq_rel); }
    size_t size() {
        std::lock_guard<std::mutex> lock(mutex_);
        refreshLocked();
        return keys_.size();
    }

private:
    void refreshLocked() {
        const uint64_t epoch = epoch_.load(std::memory_order_acquire);
        if (epoch == seenEpoch_) return;
        seenEpoch_ = epoch;
        state_ = State::unknown;
        keys_.clear();
    }
    std::mutex mutex_;
    std::atomic<uint64_t> epoch_{0};
    uint64_t seenEpoch_ = 0;
    State state_ = State::unknown;
    std::unordered_set<Key, KeyHash> keys_;
};

inline Known& known() {
    static Known instance;
    return instance;
}

// Decides what vkCreateShaderModule sends for `code`. Returns true and fills `token` when
// the phone holds the module; otherwise the code is sent, and once `singleStream` (all of
// the process's commands share one device stream, so the phone has created the module
// from that code before it meets a later token) the module's key is remembered.
// `hash(code, size, Key*)` is BLAKE3-256; `load` is as for Known::ensure.
template <class Hash, class Load>
bool substitute(Known& known, const void* code, size_t codeSize, bool singleStream, Hash&& hash,
                Load&& load, uint8_t token[kTokenBytes]) {
    if (!code || !cacheable(codeSize)) return false;
    if (known.ensure(load) != Known::State::loaded) return false;
    Key key;
    hash(code, codeSize, &key);
    if (known.contains(key)) {
        encodeToken(token, key, static_cast<uint32_t>(codeSize));
        return true;
    }
    if (singleStream) known.add(key);
    return false;
}

}  // namespace caboose::shader_cache
