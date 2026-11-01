// SPDX-License-Identifier: MIT
#pragma once
#include <cstdint>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>

namespace caboose::memory {

// Answers of physical-device queries that cannot change while the physical device exists
// (format and image-format properties), keyed by the query and its exact parameters, so
// asking again needs no round trip. Only queries without extension structures are kept.
class StaticQueryCache {
public:
    static constexpr size_t kMaxEntries = 8192;

    template <class... Parts> static std::string key(uint32_t query, const Parts&... parts) {
        std::string out;
        append(&out, query);
        (append(&out, parts), ...);
        return out;
    }
    template <class T> bool lookup(const std::string& key, T* out) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = entries_.find(key);
        if (it == entries_.end() || it->second.size() != sizeof(T)) return false;
        std::memcpy(out, it->second.data(), sizeof(T));
        return true;
    }
    template <class T> void store(const std::string& key, const T& value) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (entries_.size() >= kMaxEntries && !entries_.count(key)) entries_.clear();
        entries_[key].assign(reinterpret_cast<const char*>(&value), sizeof(T));
    }

private:
    template <class T> static void append(std::string* out, const T& value) {
        out->append(reinterpret_cast<const char*>(&value), sizeof(T));
    }
    std::mutex mutex_;
    std::unordered_map<std::string, std::string> entries_;
};

inline StaticQueryCache staticQueryCache;

}  // namespace caboose::memory
