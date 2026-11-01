// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "shader_store.h"
#include "upload_store.h"

#include "blake3/blake3.h"

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace caboose::gpuv2 {
namespace {

constexpr char kSuffix[] = ".spv";
constexpr size_t kHexBytes = kShaderKeyBytes * 2;
constexpr char kTempPrefix[] = ".tmp-";

uint32_t readLe32(const uint8_t* p) noexcept {
    return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
           (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}

void writeLe32(uint8_t* p, uint32_t value) noexcept {
    p[0] = static_cast<uint8_t>(value);
    p[1] = static_cast<uint8_t>(value >> 8);
    p[2] = static_cast<uint8_t>(value >> 16);
    p[3] = static_cast<uint8_t>(value >> 24);
}

bool sizeIsCacheable(size_t codeSize) noexcept {
    return codeSize >= kShaderMinCodeBytes && codeSize <= kShaderMaxCodeBytes && codeSize % 4 == 0;
}

bool makeDirectories(const std::string& path) {
    if (path.empty()) return false;
    std::string current;
    for (size_t i = 0; i <= path.size(); ++i) {
        if (i == path.size() || path[i] == '/') {
            if (!current.empty() && mkdir(current.c_str(), 0700) != 0 && errno != EEXIST) return false;
        }
        if (i < path.size()) current.push_back(path[i]);
    }
    struct stat st {};
    return stat(path.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

bool readWholeFile(const std::string& path, size_t expected, std::vector<uint32_t>* out) {
    const int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return false;
    struct stat st {};
    bool ok = fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && static_cast<uint64_t>(st.st_size) == expected;
    if (ok) {
        out->assign(expected / 4, 0);
        auto* bytes = reinterpret_cast<uint8_t*>(out->data());
        size_t done = 0;
        while (ok && done < expected) {
            const ssize_t got = ::read(fd, bytes + done, expected - done);
            if (got < 0 && errno == EINTR) continue;
            if (got <= 0) ok = false;
            else done += static_cast<size_t>(got);
        }
    }
    ::close(fd);
    return ok;
}

std::mutex gCurrentMutex;
std::shared_ptr<ShaderStore> gCurrent;
std::string gCurrentRoot;

}  // namespace

bool ShaderKey::operator==(const ShaderKey& other) const noexcept {
    return std::memcmp(bytes, other.bytes, kShaderKeyBytes) == 0;
}

size_t ShaderKeyHash::operator()(const ShaderKey& key) const noexcept {
    size_t value = 0;
    std::memcpy(&value, key.bytes, sizeof(value));
    return value;
}

ShaderKey shaderKeyOf(const void* code, size_t codeSize) noexcept {
    blake3_hasher hasher;
    blake3_hasher_init(&hasher);
    blake3_hasher_update(&hasher, code, codeSize);
    ShaderKey key;
    blake3_hasher_finalize(&hasher, key.bytes, kShaderKeyBytes);
    return key;
}

std::string shaderKeyHex(const ShaderKey& key) {
    static const char digits[] = "0123456789abcdef";
    std::string hex(kHexBytes, '0');
    for (size_t i = 0; i < kShaderKeyBytes; ++i) {
        hex[2 * i] = digits[key.bytes[i] >> 4];
        hex[2 * i + 1] = digits[key.bytes[i] & 15];
    }
    return hex;
}

bool shaderKeyFromHex(const char* hex, size_t length, ShaderKey* key) noexcept {
    if (!hex || !key || length != kHexBytes) return false;
    auto nibble = [](char c) -> int {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        return -1;
    };
    for (size_t i = 0; i < kShaderKeyBytes; ++i) {
        const int hi = nibble(hex[2 * i]), lo = nibble(hex[2 * i + 1]);
        if (hi < 0 || lo < 0) return false;
        key->bytes[i] = static_cast<uint8_t>((hi << 4) | lo);
    }
    return true;
}

void writeShaderToken(uint8_t out[kShaderTokenBytes], const ShaderKey& key, uint32_t codeSize) noexcept {
    writeLe32(out, kShaderTokenMagic);
    writeLe32(out + 4, kShaderTokenVersion);
    writeLe32(out + 8, codeSize);
    writeLe32(out + 12, 0);
    std::memcpy(out + 16, key.bytes, kShaderKeyBytes);
}

bool parseShaderToken(const void* code, size_t codeSize, ShaderKey* key, uint32_t* realSize) noexcept {
    if (!code || codeSize != kShaderTokenBytes) return false;
    const auto* p = static_cast<const uint8_t*>(code);
    if (readLe32(p) != kShaderTokenMagic || readLe32(p + 4) != kShaderTokenVersion || readLe32(p + 12) != 0)
        return false;
    const uint32_t size = readLe32(p + 8);
    if (!sizeIsCacheable(size)) return false;
    if (key) std::memcpy(key->bytes, p + 16, kShaderKeyBytes);
    if (realSize) *realSize = size;
    return true;
}

bool parseShaderInventoryPacket(const uint8_t* packet, size_t size) noexcept {
    return packet && size == kShaderInventoryPacketBytes && readLe32(packet) == kShaderInventoryOpcode &&
           readLe32(packet + 4) == kShaderInventoryPacketBytes &&
           readLe32(packet + 8) == kShaderInventoryVersion && readLe32(packet + 12) == 0;
}

std::vector<uint8_t> encodeShaderInventoryReply(const std::vector<ShaderKey>& keys) {
    const size_t count = std::min<size_t>(keys.size(), kShaderInventoryMaxKeys);
    std::vector<uint8_t> reply(8 + count * kShaderKeyBytes);
    writeLe32(reply.data(), static_cast<uint32_t>(count));
    writeLe32(reply.data() + 4, 0);
    for (size_t i = 0; i < count; ++i)
        std::memcpy(reply.data() + 8 + i * kShaderKeyBytes, keys[i].bytes, kShaderKeyBytes);
    return reply;
}

ShaderStore::ShaderStore(std::string directory, ShaderStoreLimits limits)
    : directory_(std::move(directory)), limits_(limits) {}

std::string ShaderStore::pathOf(const ShaderKey& key) const {
    return directory_ + "/" + shaderKeyHex(key) + kSuffix;
}

std::shared_ptr<ShaderStore> ShaderStore::open(const std::string& directory, ShaderStoreLimits limits) {
    if (!makeDirectories(directory)) return nullptr;
    std::shared_ptr<ShaderStore> store(new ShaderStore(directory, limits));
    DIR* dir = opendir(directory.c_str());
    if (!dir) return nullptr;
    struct Found {
        ShaderKey key;
        uint32_t size;
        int64_t usedNs;
    };
    std::vector<Found> found;
    std::vector<std::string> remove;
    while (dirent* item = readdir(dir)) {
        const std::string name = item->d_name;
        if (name == "." || name == "..") continue;
        const std::string path = directory + "/" + name;
        ShaderKey key;
        struct stat st {};
        const bool entryName = name.size() == kHexBytes + sizeof(kSuffix) - 1 &&
                               name.compare(kHexBytes, std::string::npos, kSuffix) == 0 &&
                               shaderKeyFromHex(name.data(), kHexBytes, &key);
        if (!entryName || lstat(path.c_str(), &st) != 0 || !S_ISREG(st.st_mode) ||
            !sizeIsCacheable(static_cast<size_t>(st.st_size))) {
            if (name.compare(0, sizeof(kTempPrefix) - 1, kTempPrefix) == 0 || entryName) remove.push_back(path);
            continue;
        }
#ifdef __APPLE__
        const int64_t usedNs = static_cast<int64_t>(st.st_mtimespec.tv_sec) * 1000000000 + st.st_mtimespec.tv_nsec;
#else
        const int64_t usedNs = static_cast<int64_t>(st.st_mtim.tv_sec) * 1000000000 + st.st_mtim.tv_nsec;
#endif
        found.push_back({key, static_cast<uint32_t>(st.st_size), usedNs});
    }
    closedir(dir);
    for (const auto& path : remove) unlink(path.c_str());
    // Most recently used first; keep what fits.
    std::sort(found.begin(), found.end(), [](const Found& a, const Found& b) { return a.usedNs > b.usedNs; });
    for (const auto& f : found) {
        if (store->entries_.size() < limits.maxEntries && store->bytes_ + f.size <= limits.maxBytes) {
            store->entries_[f.key].size = f.size;
            store->bytes_ += f.size;
        } else {
            unlink(store->pathOf(f.key).c_str());
            ++store->stats_.evictedAtOpen;
        }
    }
    return store;
}

std::vector<ShaderKey> ShaderStore::inventory() const {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<ShaderKey> keys;
    keys.reserve(std::min<size_t>(entries_.size(), kShaderInventoryMaxKeys));
    for (const auto& [key, entry] : entries_) {
        if (keys.size() == kShaderInventoryMaxKeys) break;
        keys.push_back(key);
    }
    return keys;
}

bool ShaderStore::resolve(const ShaderKey& key, uint32_t codeSize, std::vector<uint32_t>* out) {
    std::vector<uint32_t> memory;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = entries_.find(key);
        if (it == entries_.end() || it->second.size != codeSize) {
            ++stats_.unresolved;
            return false;
        }
        memory = it->second.memory;
    }
    const std::string path = pathOf(key);
    bool ok = !memory.empty() ? (*out = std::move(memory), true) : readWholeFile(path, codeSize, out);
    ok = ok && shaderKeyOf(out->data(), codeSize) == key;
    std::lock_guard<std::mutex> lock(mutex_);
    if (!ok) {
        // A damaged or missing file: forget it, so no later inventory lists it.
        auto it = entries_.find(key);
        if (it != entries_.end() && it->second.memory.empty()) {
            bytes_ -= it->second.size;
            entries_.erase(it);
            unlink(path.c_str());
        }
        ++stats_.unresolved;
        return false;
    }
    ++stats_.resolved;
    stats_.resolvedBytes += codeSize;
    // Recency for eviction at the next open.
    utimensat(AT_FDCWD, path.c_str(), nullptr, 0);
    return true;
}

bool ShaderStore::writeFile(const ShaderKey& key, const void* code, size_t codeSize) {
    std::string temp;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        temp = directory_ + "/" + kTempPrefix + std::to_string(getpid()) + "-" + std::to_string(++tempCounter_);
    }
    const int fd = ::open(temp.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return false;
    const auto* bytes = static_cast<const uint8_t*>(code);
    size_t done = 0;
    bool ok = true;
    while (ok && done < codeSize) {
        const ssize_t put = ::write(fd, bytes + done, codeSize - done);
        if (put < 0 && errno == EINTR) continue;
        if (put <= 0) ok = false;
        else done += static_cast<size_t>(put);
    }
    ok = ::close(fd) == 0 && ok;
    ok = ok && ::rename(temp.c_str(), pathOf(key).c_str()) == 0;
    if (!ok) unlink(temp.c_str());
    return ok;
}

void ShaderStore::insert(const void* code, size_t codeSize) {
    if (!code || !sizeIsCacheable(codeSize)) {
        std::lock_guard<std::mutex> lock(mutex_);
        ++stats_.insertSkipped;
        return;
    }
    const ShaderKey key = shaderKeyOf(code, codeSize);
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = entries_.find(key);
        if (it != entries_.end() && it->second.size == codeSize) return;
    }
    const bool written = writeFile(key, code, codeSize);
    std::lock_guard<std::mutex> lock(mutex_);
    Entry& entry = entries_[key];
    if (entry.size == codeSize) return;  // another thread kept it meanwhile
    entry.size = static_cast<uint32_t>(codeSize);
    if (!written) {
        const auto* words = static_cast<const uint32_t*>(code);
        entry.memory.assign(words, words + codeSize / 4);
        ++stats_.writeFailures;
    }
    bytes_ += codeSize;
    ++stats_.inserted;
    stats_.insertedBytes += codeSize;
}

ShaderStoreStats ShaderStore::stats() const {
    std::lock_guard<std::mutex> lock(mutex_);
    ShaderStoreStats s = stats_;
    s.entries = entries_.size();
    s.bytes = bytes_;
    return s;
}

std::shared_ptr<ShaderStore> currentShaderStore() {
    std::lock_guard<std::mutex> lock(gCurrentMutex);
    return gCurrent;
}

int setShaderStoreRoot(const char* root) {
    // Whatever happens, the previous computer's caches are no longer selected.
    {
        std::lock_guard<std::mutex> lock(gCurrentMutex);
        gCurrent.reset();
        gCurrentRoot.clear();
    }
    setUploadStoreRoot({});
    if (!root) return 0;
    if (root[0] != '/') return EINVAL;
    std::string dir(root);
    while (dir.size() > 1 && dir.back() == '/') dir.pop_back();
    auto store = ShaderStore::open(dir + "/shaders");
    if (!store) return EIO;
    // Uploads live beside the shaders; without them the shader cache still works.
    const int uploads = setUploadStoreRoot(dir);
    if (uploads) std::fprintf(stderr, "CABOOSE_GPU_CACHES uploads=unavailable error=%d\n", uploads);
    std::lock_guard<std::mutex> lock(gCurrentMutex);
    gCurrent = std::move(store);
    gCurrentRoot = dir;
    return 0;
}

std::string cacheRoot() {
    std::lock_guard<std::mutex> lock(gCurrentMutex);
    return gCurrentRoot;
}

ShaderCodeSource resolveShaderCode(const void* code, size_t codeSize, std::vector<uint32_t>* out) {
    ShaderKey key;
    uint32_t realSize = 0;
    if (!parseShaderToken(code, codeSize, &key, &realSize)) return ShaderCodeSource::literal;
    auto store = currentShaderStore();
    if (!store || !out || !store->resolve(key, realSize, out)) return ShaderCodeSource::unresolved;
    return ShaderCodeSource::resolved;
}

void rememberShaderCode(const void* code, size_t codeSize) {
    if (auto store = currentShaderStore()) store->insert(code, codeSize);
}

}  // namespace caboose::gpuv2
