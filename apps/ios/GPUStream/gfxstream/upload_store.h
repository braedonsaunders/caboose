// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once

// The phone's persistent upload store (docs/gpu-live.md, "Upload cache"). 4096-byte pieces of
// mapped memory a computer uploaded are kept on the phone's storage under the BLAKE3-256 of
// their bytes. A guest process asks for the store's inventory (UPLOAD_INVENTORY) and from then
// on names a piece the inventory lists, or that it stored on the same device stream, by the
// first 16 bytes of its key instead of sending it. The phone hashes every piece it stores
// itself. Nothing is removed while the store is open, so every name stays resolvable for the
// life of the runtime; the budget is applied when a store is opened, by dropping whole least
// recently used packs.
//
// On storage the store is a directory of packs, `<number>.pack`, each a table of 16384
// 32-byte keys followed by 16384 4096-byte slots. A slot is written before its key, so an
// interrupted write leaves an empty slot; a slot is verified against its key whenever it is
// read. Pieces are written off the decoding thread: a piece waits in memory, where it already
// resolves, until a writer thread has put it in a pack.

#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace caboose::gpuv2 {

inline constexpr size_t kUploadPieceBytes = 4096;
inline constexpr size_t kUploadKeyBytes = 32;
inline constexpr size_t kUploadPrefixBytes = 16;
// A flush fragment whose u64 length has this bit set is a piece (vk_decoder, packet_framing).
inline constexpr uint64_t kUploadPieceFlag = 1ull << 63;
inline constexpr uint32_t kUploadPieceStore = 1;   // 4096 bytes follow: write and store them
inline constexpr uint32_t kUploadPieceStored = 2;  // a 16-byte key prefix follows

inline constexpr uint32_t kUploadInventoryOpcode = 0x4342FE11;
inline constexpr uint32_t kUploadInventoryPacketBytes = 16;
inline constexpr uint32_t kUploadInventoryVersion = 1;
inline constexpr uint32_t kUploadInventoryMaxKeys = 262144;
inline constexpr uint32_t kUploadMaxAllowance = 65536;
inline constexpr uint32_t kUploadPackSlots = 16384;

struct UploadPrefix {
    uint8_t bytes[kUploadPrefixBytes] = {};
    bool operator==(const UploadPrefix& other) const noexcept;
};
struct UploadPrefixHash {
    size_t operator()(const UploadPrefix& prefix) const noexcept;
};
struct UploadKey {
    uint8_t bytes[kUploadKeyBytes] = {};
    bool operator==(const UploadKey& other) const noexcept;
    UploadPrefix prefix() const noexcept;
};

UploadKey uploadKeyOf(const uint8_t* piece) noexcept;  // of exactly kUploadPieceBytes

// UPLOAD_INVENTORY: the 8-byte packet header (opcode, size 16), version 1, reserved zero.
bool parseUploadInventoryPacket(const uint8_t* packet, size_t size) noexcept;
// Its reply: count u32, allowance u32, then count 16-byte prefixes. At most
// kUploadInventoryMaxKeys prefixes and kUploadMaxAllowance pieces are ever sent.
std::vector<uint8_t> encodeUploadInventoryReply(const std::vector<UploadPrefix>& prefixes, uint32_t allowance);

// A fragment's form in a flush packet, after its u64 length (`length`), from the `available`
// bytes at `data`: how many bytes the piece occupies after the length, 0 when more are needed
// to tell, or -1 when it is not a valid piece. Lengths without kUploadPieceFlag are not pieces.
inline int64_t uploadPieceSize(uint64_t length, const uint8_t* data, size_t available) noexcept {
    // Bit 63, exactly 4096 below it, nothing else.
    if (length != (kUploadPieceFlag | kUploadPieceBytes)) return -1;
    if (available < 4) return 0;
    const uint32_t kind = uint32_t(data[0]) | uint32_t(data[1]) << 8 | uint32_t(data[2]) << 16 | uint32_t(data[3]) << 24;
    if (kind == kUploadPieceStore) return 4 + int64_t(kUploadPieceBytes);
    if (kind == kUploadPieceStored) return 4 + int64_t(kUploadPrefixBytes);
    return -1;
}

struct UploadStoreLimits {
    uint64_t maxBytes = 1ull << 30;
    // The budget is also at most this share of the free space where the store lives.
    uint32_t freeSpacePercent = 5;
    size_t pendingBytes = 16u << 20;
};

struct UploadStoreStats {
    uint64_t pieces = 0;
    uint64_t packs = 0;
    uint64_t droppedPacksAtOpen = 0;
    uint64_t stored = 0;
    uint64_t duplicates = 0;
    uint64_t resolved = 0;
    uint64_t unresolved = 0;
    uint64_t writeFailures = 0;
    uint64_t budgetBytes = 0;
};

class UploadStore {
public:
    // Opens or creates `directory`, drops packs it cannot read and, least recently used first,
    // whole packs beyond the budget, and rebuilds the index from the remaining packs' keys.
    static std::shared_ptr<UploadStore> open(const std::string& directory, UploadStoreLimits limits = {});
    ~UploadStore();  // writes every waiting piece

    // The prefixes the store holds, each naming exactly one piece.
    std::vector<UploadPrefix> inventory() const;
    // How many pieces a process may still ask to store: what is left of the budget.
    uint32_t allowance() const;
    // Keeps `piece` (kUploadPieceBytes), hashed here. A piece already held is kept once. Waits
    // while the pieces not yet written fill the pending budget.
    void store(const uint8_t* piece);
    // Fills `out` (kUploadPieceBytes) with the piece whose key begins with `prefix`. False when
    // the store holds none, or two, or its slot no longer matches its key.
    bool resolve(const uint8_t* prefix, uint8_t* out);
    // Waits until every piece stored so far is in a pack.
    void drain();
    UploadStoreStats stats() const;

private:
    struct Location {
        uint32_t pack = 0;
        uint32_t slot = 0;
        bool ambiguous = false;
    };
    struct Pack {
        uint32_t number = 0;
        int fd = -1;
        uint32_t used = 0;
        bool touched = false;
    };
    struct Pending {
        UploadKey key;
        std::vector<uint8_t> bytes;
    };
    UploadStore(std::string directory, UploadStoreLimits limits);
    void write();
    bool startPack();
    std::string pathOf(uint32_t number) const;

    const std::string directory_;
    const UploadStoreLimits limits_;
    uint64_t budget_ = 0;
    mutable std::mutex mutex_;
    std::condition_variable changed_;
    std::unordered_map<UploadPrefix, Location, UploadPrefixHash> index_;
    std::unordered_map<UploadPrefix, std::shared_ptr<Pending>, UploadPrefixHash> pending_;
    std::deque<std::shared_ptr<Pending>> queue_;
    size_t pendingBytes_ = 0;
    std::vector<Pack> packs_;  // the last one takes new pieces
    uint64_t bytes_ = 0;
    uint32_t nextNumber_ = 0;
    bool writing_ = false;
    bool stopping_ = false;
    bool failing_ = false;  // a write failed: pieces stay in memory and none more are asked for
    UploadStoreStats stats_;
    std::thread writer_;
};

// The store the decoder uses: `<root>/uploads` of the cache root the app set for the connected
// computer (selected with the shader store, setShaderStoreRoot). Null until a root is set.
std::shared_ptr<UploadStore> currentUploadStore();
// Selects `<root>/uploads`, or none for an empty root.
int setUploadStoreRoot(const std::string& root);

// Decoder hooks for vkFlushMappedMemoryRanges (gfxstream fork, caboose_upload_cache.h).
void storeUploadPiece(const uint8_t* piece);
bool resolveUploadPiece(const uint8_t* prefix, uint8_t* out);

}  // namespace caboose::gpuv2
