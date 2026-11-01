// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "upload_store.h"

#include "blake3/blake3.h"

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <unistd.h>

namespace caboose::gpuv2 {
namespace {

constexpr char kSuffix[] = ".pack";
constexpr size_t kNumberDigits = 8;
constexpr uint64_t kTableBytes = uint64_t(kUploadPackSlots) * kUploadKeyBytes;
// What one held piece costs the budget: its slot and its key.
constexpr uint64_t kPieceCost = kUploadPieceBytes + kUploadKeyBytes;

uint32_t readLe32(const uint8_t* p) noexcept {
    return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
           (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}

void writeLe32(uint8_t* p, uint32_t value) noexcept {
    for (int i = 0; i < 4; ++i) p[i] = static_cast<uint8_t>(value >> (8 * i));
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

bool readFully(int fd, uint8_t* out, size_t size, uint64_t offset) {
    size_t done = 0;
    while (done < size) {
        const ssize_t n = pread(fd, out + done, size - done, static_cast<off_t>(offset + done));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        done += static_cast<size_t>(n);
    }
    return true;
}

bool writeFully(int fd, const uint8_t* bytes, size_t size, uint64_t offset) {
    size_t done = 0;
    while (done < size) {
        const ssize_t n = pwrite(fd, bytes + done, size - done, static_cast<off_t>(offset + done));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        done += static_cast<size_t>(n);
    }
    return true;
}

bool isZero(const uint8_t* bytes, size_t size) {
    for (size_t i = 0; i < size; ++i) if (bytes[i]) return false;
    return true;
}

// `<8 hex digits>.pack` names a pack.
bool packNumber(const std::string& name, uint32_t* number) {
    if (name.size() != kNumberDigits + sizeof(kSuffix) - 1 ||
        name.compare(kNumberDigits, std::string::npos, kSuffix) != 0) return false;
    uint32_t value = 0;
    for (size_t i = 0; i < kNumberDigits; ++i) {
        const char c = name[i];
        const int digit = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : -1;
        if (digit < 0) return false;
        value = value << 4 | static_cast<uint32_t>(digit);
    }
    *number = value;
    return true;
}

std::mutex gCurrentMutex;
std::shared_ptr<UploadStore> gCurrent;

}  // namespace

bool UploadPrefix::operator==(const UploadPrefix& other) const noexcept {
    return std::memcmp(bytes, other.bytes, kUploadPrefixBytes) == 0;
}

size_t UploadPrefixHash::operator()(const UploadPrefix& prefix) const noexcept {
    size_t value;
    std::memcpy(&value, prefix.bytes, sizeof(value));
    return value;
}

bool UploadKey::operator==(const UploadKey& other) const noexcept {
    return std::memcmp(bytes, other.bytes, kUploadKeyBytes) == 0;
}

UploadPrefix UploadKey::prefix() const noexcept {
    UploadPrefix prefix;
    std::memcpy(prefix.bytes, bytes, kUploadPrefixBytes);
    return prefix;
}

UploadKey uploadKeyOf(const uint8_t* piece) noexcept {
    blake3_hasher hasher;
    blake3_hasher_init(&hasher);
    blake3_hasher_update(&hasher, piece, kUploadPieceBytes);
    UploadKey key;
    blake3_hasher_finalize(&hasher, key.bytes, kUploadKeyBytes);
    return key;
}

bool parseUploadInventoryPacket(const uint8_t* packet, size_t size) noexcept {
    return packet && size == kUploadInventoryPacketBytes && readLe32(packet) == kUploadInventoryOpcode &&
           readLe32(packet + 4) == kUploadInventoryPacketBytes &&
           readLe32(packet + 8) == kUploadInventoryVersion && readLe32(packet + 12) == 0;
}

std::vector<uint8_t> encodeUploadInventoryReply(const std::vector<UploadPrefix>& prefixes, uint32_t allowance) {
    const size_t count = std::min<size_t>(prefixes.size(), kUploadInventoryMaxKeys);
    std::vector<uint8_t> reply(8 + count * kUploadPrefixBytes);
    writeLe32(reply.data(), static_cast<uint32_t>(count));
    writeLe32(reply.data() + 4, std::min(allowance, kUploadMaxAllowance));
    for (size_t i = 0; i < count; ++i)
        std::memcpy(reply.data() + 8 + i * kUploadPrefixBytes, prefixes[i].bytes, kUploadPrefixBytes);
    return reply;
}

UploadStore::UploadStore(std::string directory, UploadStoreLimits limits)
    : directory_(std::move(directory)), limits_(limits) {}

std::string UploadStore::pathOf(uint32_t number) const {
    char name[kNumberDigits + sizeof(kSuffix)];
    std::snprintf(name, sizeof(name), "%08x%s", number, kSuffix);
    return directory_ + "/" + name;
}

std::shared_ptr<UploadStore> UploadStore::open(const std::string& directory, UploadStoreLimits limits) {
    if (!makeDirectories(directory)) return nullptr;
    std::shared_ptr<UploadStore> store(new UploadStore(directory, limits));
    DIR* dir = opendir(directory.c_str());
    if (!dir) return nullptr;
    struct Found {
        uint32_t number;
        int fd;
        uint32_t used;
        int64_t usedNs;
        std::vector<uint8_t> keys;
    };
    std::vector<Found> found;
    std::vector<std::string> remove;
    uint64_t heldBytes = 0;
    while (dirent* item = readdir(dir)) {
        const std::string name = item->d_name;
        uint32_t number = 0;
        if (!packNumber(name, &number)) continue;
        const std::string path = directory + "/" + name;
        const int fd = ::open(path.c_str(), O_RDWR | O_CLOEXEC | O_NOFOLLOW);
        struct stat st {};
        std::vector<uint8_t> keys(kTableBytes);
        if (fd < 0 || fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) ||
            static_cast<uint64_t>(st.st_size) < kTableBytes || !readFully(fd, keys.data(), keys.size(), 0)) {
            if (fd >= 0) close(fd);
            remove.push_back(path);
            continue;
        }
        // Slots fill in order; the first empty key ends the pack's pieces.
        uint32_t used = 0;
        while (used < kUploadPackSlots && !isZero(keys.data() + size_t(used) * kUploadKeyBytes, kUploadKeyBytes)) ++used;
#ifdef __APPLE__
        const int64_t usedNs = static_cast<int64_t>(st.st_mtimespec.tv_sec) * 1000000000 + st.st_mtimespec.tv_nsec;
#else
        const int64_t usedNs = static_cast<int64_t>(st.st_mtim.tv_sec) * 1000000000 + st.st_mtim.tv_nsec;
#endif
        heldBytes += uint64_t(used) * kPieceCost;
        found.push_back({number, fd, used, usedNs, std::move(keys)});
    }
    closedir(dir);
    for (const auto& path : remove) unlink(path.c_str());

    // At most 1 GiB, and at most a share of the free space, counting what the store holds.
    uint64_t budget = limits.maxBytes;
    struct statvfs fs {};
    if (statvfs(directory.c_str(), &fs) == 0) {
        const uint64_t room = uint64_t(fs.f_bavail) * fs.f_frsize + heldBytes;
        budget = std::min<uint64_t>(budget, room / 100 * limits.freeSpacePercent);
    }
    store->budget_ = budget;

    // Most recently used first; whole packs that do not fit are dropped.
    std::sort(found.begin(), found.end(), [](const Found& a, const Found& b) {
        return a.usedNs != b.usedNs ? a.usedNs > b.usedNs : a.number > b.number;
    });
    std::unordered_map<UploadPrefix, UploadKey, UploadPrefixHash> keyOf;
    uint32_t nextNumber = 0;
    for (auto& f : found) {
        nextNumber = std::max(nextNumber, f.number + 1);
        const uint64_t cost = uint64_t(f.used) * kPieceCost;
        if (store->bytes_ + cost > budget) {
            close(f.fd);
            unlink(store->pathOf(f.number).c_str());
            ++store->stats_.droppedPacksAtOpen;
            continue;
        }
        const uint32_t index = static_cast<uint32_t>(store->packs_.size());
        store->packs_.push_back({f.number, f.fd, f.used, false});
        store->bytes_ += cost;
        for (uint32_t slot = 0; slot < f.used; ++slot) {
            UploadKey key;
            std::memcpy(key.bytes, f.keys.data() + size_t(slot) * kUploadKeyBytes, kUploadKeyBytes);
            const UploadPrefix prefix = key.prefix();
            auto [it, inserted] = keyOf.emplace(prefix, key);
            if (inserted) store->index_[prefix] = {index, slot, false};
            else if (!(it->second == key)) store->index_[prefix].ambiguous = true;  // two keys, one prefix
        }
    }
    // New pieces go to the most recent pack with room, else to a new one.
    auto room = std::find_if(store->packs_.begin(), store->packs_.end(),
                             [](const Pack& p) { return p.used < kUploadPackSlots; });
    if (room != store->packs_.end() && room != store->packs_.begin()) {
        // Keep the index's pack numbers: move it last by swapping indices in the index.
        const uint32_t from = static_cast<uint32_t>(room - store->packs_.begin());
        const uint32_t to = static_cast<uint32_t>(store->packs_.size() - 1);
        std::swap(store->packs_[from], store->packs_[to]);
        for (auto& [prefix, location] : store->index_) {
            if (location.pack == from) location.pack = to;
            else if (location.pack == to) location.pack = from;
        }
    }
    store->nextNumber_ = nextNumber;
    store->stats_.budgetBytes = budget;
    store->writer_ = std::thread([raw = store.get()] { raw->write(); });
    return store;
}

UploadStore::~UploadStore() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stopping_ = true;
    }
    changed_.notify_all();
    if (writer_.joinable()) writer_.join();
    for (const auto& pack : packs_) if (pack.fd >= 0) close(pack.fd);
}

bool UploadStore::startPack() {
    const uint32_t number = nextNumber_++;
    const int fd = ::open(pathOf(number).c_str(), O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return false;
    // The key table exists, all empty, before any slot is written.
    if (ftruncate(fd, static_cast<off_t>(kTableBytes)) != 0) {
        close(fd);
        unlink(pathOf(number).c_str());
        return false;
    }
    packs_.push_back({number, fd, 0, true});
    return true;
}

void UploadStore::write() {
    std::unique_lock<std::mutex> lock(mutex_);
    for (;;) {
        changed_.wait(lock, [&] { return stopping_ || !queue_.empty(); });
        if (queue_.empty()) return;  // stopping, with every piece written
        auto piece = queue_.front();
        queue_.pop_front();
        writing_ = true;
        bool ok = !failing_;
        if (ok && (packs_.empty() || packs_.back().used == kUploadPackSlots)) ok = startPack();
        uint32_t index = 0, slot = 0;
        int fd = -1;
        if (ok) {
            index = static_cast<uint32_t>(packs_.size() - 1);
            slot = packs_[index].used;
            fd = packs_[index].fd;
        }
        lock.unlock();
        // The slot before its key: an interrupted write leaves an empty slot.
        ok = ok && writeFully(fd, piece->bytes.data(), kUploadPieceBytes, kTableBytes + uint64_t(slot) * kUploadPieceBytes) &&
             writeFully(fd, piece->key.bytes, kUploadKeyBytes, uint64_t(slot) * kUploadKeyBytes);
        lock.lock();
        const UploadPrefix prefix = piece->key.prefix();
        if (ok) {
            ++packs_[index].used;
            index_[prefix] = {index, slot, false};
            pending_.erase(prefix);
        } else {
            // Kept in memory: a piece the guest stored stays resolvable for the whole run, and
            // the store asks for no more.
            failing_ = true;
            ++stats_.writeFailures;
        }
        pendingBytes_ -= kUploadPieceBytes;
        writing_ = false;
        changed_.notify_all();
    }
}

std::vector<UploadPrefix> UploadStore::inventory() const {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<UploadPrefix> prefixes;
    prefixes.reserve(std::min<size_t>(index_.size() + pending_.size(), kUploadInventoryMaxKeys));
    for (const auto& [prefix, location] : index_) {
        if (prefixes.size() == kUploadInventoryMaxKeys) return prefixes;
        if (!location.ambiguous) prefixes.push_back(prefix);
    }
    for (const auto& [prefix, piece] : pending_) {
        if (prefixes.size() == kUploadInventoryMaxKeys) break;
        if (!index_.count(prefix)) prefixes.push_back(prefix);
    }
    return prefixes;
}

uint32_t UploadStore::allowance() const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (failing_ || bytes_ >= budget_) return 0;
    return static_cast<uint32_t>(std::min<uint64_t>((budget_ - bytes_) / kPieceCost, kUploadMaxAllowance));
}

void UploadStore::store(const uint8_t* piece) {
    const UploadKey key = uploadKeyOf(piece);
    const UploadPrefix prefix = key.prefix();
    std::unique_lock<std::mutex> lock(mutex_);
    if (index_.count(prefix) || pending_.count(prefix)) {
        ++stats_.duplicates;
        return;
    }
    // Pieces wait in memory only up to the pending budget; past it, the decoder waits for the
    // writer. A piece that could not be written stays in memory without counting.
    changed_.wait(lock, [&] { return pendingBytes_ + kUploadPieceBytes <= limits_.pendingBytes || stopping_; });
    auto pending = std::make_shared<Pending>();
    pending->key = key;
    pending->bytes.assign(piece, piece + kUploadPieceBytes);
    pending_[prefix] = pending;
    queue_.push_back(std::move(pending));
    pendingBytes_ += kUploadPieceBytes;
    bytes_ += kPieceCost;
    ++stats_.stored;
    changed_.notify_all();
}

bool UploadStore::resolve(const uint8_t* prefixBytes, uint8_t* out) {
    UploadPrefix prefix;
    std::memcpy(prefix.bytes, prefixBytes, kUploadPrefixBytes);
    int fd = -1;
    uint32_t slot = 0;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        const auto waiting = pending_.find(prefix);
        if (waiting != pending_.end()) {
            std::memcpy(out, waiting->second->bytes.data(), kUploadPieceBytes);
            ++stats_.resolved;
            return true;
        }
        const auto it = index_.find(prefix);
        if (it == index_.end() || it->second.ambiguous) {
            ++stats_.unresolved;
            return false;
        }
        Pack& pack = packs_[it->second.pack];
        fd = pack.fd;
        slot = it->second.slot;
        if (!pack.touched) {
            // Used this run: the pack is among the most recently used when the store next opens.
            pack.touched = true;
            futimens(fd, nullptr);
        }
    }
    const bool ok = readFully(fd, out, kUploadPieceBytes, kTableBytes + uint64_t(slot) * kUploadPieceBytes) &&
                    uploadKeyOf(out).prefix() == prefix;
    std::lock_guard<std::mutex> lock(mutex_);
    ++(ok ? stats_.resolved : stats_.unresolved);
    return ok;
}

void UploadStore::drain() {
    std::unique_lock<std::mutex> lock(mutex_);
    changed_.wait(lock, [&] { return queue_.empty() && !writing_; });
}

UploadStoreStats UploadStore::stats() const {
    std::lock_guard<std::mutex> lock(mutex_);
    UploadStoreStats s = stats_;
    s.pieces = index_.size() + pending_.size();
    s.packs = packs_.size();
    return s;
}

std::shared_ptr<UploadStore> currentUploadStore() {
    std::lock_guard<std::mutex> lock(gCurrentMutex);
    return gCurrent;
}

int setUploadStoreRoot(const std::string& root) {
    std::shared_ptr<UploadStore> previous;
    {
        std::lock_guard<std::mutex> lock(gCurrentMutex);
        previous = std::move(gCurrent);
    }
    previous.reset();  // writes what the previous computer's store still holds in memory
    if (root.empty()) return 0;
    auto store = UploadStore::open(root + "/uploads");
    if (!store) return EIO;
    std::lock_guard<std::mutex> lock(gCurrentMutex);
    gCurrent = std::move(store);
    return 0;
}

void storeUploadPiece(const uint8_t* piece) {
    if (auto store = currentUploadStore()) store->store(piece);
}

bool resolveUploadPiece(const uint8_t* prefix, uint8_t* out) {
    auto store = currentUploadStore();
    return store && store->resolve(prefix, out);
}

}  // namespace caboose::gpuv2
