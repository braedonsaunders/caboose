// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once

// The phone's persistent SPIR-V store (docs/gpu-live.md, "Shader cache"). Shader modules a
// computer sent are kept on the phone's storage under their BLAKE3 hash. A guest process
// asks for the store's inventory once per device stream (SHADER_INVENTORY) and from then on
// sends a 48-byte token instead of the code of any module the inventory lists, or that it
// already sent as code on that stream. Entries are never removed while the store is open
// and every module created from code is kept (in memory if its file cannot be written), so
// both stay resolvable for the life of the runtime. The budget is applied when a store is
// opened, by evicting the least recently used entries.

#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace caboose::gpuv2 {

inline constexpr uint32_t kShaderTokenMagic = 0x4D534243;  // "CBSM", little-endian
inline constexpr uint32_t kShaderTokenVersion = 1;
inline constexpr size_t kShaderTokenBytes = 48;
inline constexpr size_t kShaderKeyBytes = 32;
// Modules smaller than this are always sent as code: the token saves too little.
inline constexpr size_t kShaderMinCodeBytes = 256;
inline constexpr size_t kShaderMaxCodeBytes = 16u * 1024u * 1024u;

inline constexpr uint32_t kShaderInventoryOpcode = 0x4342FE10;
inline constexpr uint32_t kShaderInventoryPacketBytes = 16;
inline constexpr uint32_t kShaderInventoryVersion = 1;
inline constexpr uint32_t kShaderInventoryMaxKeys = 16384;

struct ShaderKey {
    uint8_t bytes[kShaderKeyBytes] = {};
    bool operator==(const ShaderKey& other) const noexcept;
};

struct ShaderKeyHash {
    size_t operator()(const ShaderKey& key) const noexcept;
};

ShaderKey shaderKeyOf(const void* code, size_t codeSize) noexcept;
std::string shaderKeyHex(const ShaderKey& key);
bool shaderKeyFromHex(const char* hex, size_t length, ShaderKey* key) noexcept;

// A token is magic, version, code size, reserved zero (four u32) and the code's key.
void writeShaderToken(uint8_t out[kShaderTokenBytes], const ShaderKey& key, uint32_t codeSize) noexcept;
// True for exactly a well-formed token. A SPIR-V module begins with 0x07230203, so a
// module is never mistaken for a token.
bool parseShaderToken(const void* code, size_t codeSize, ShaderKey* key, uint32_t* realSize) noexcept;

// SHADER_INVENTORY: the 8-byte packet header (opcode, size 16), version 1, reserved zero.
bool parseShaderInventoryPacket(const uint8_t* packet, size_t size) noexcept;
// Its reply: count u32, reserved zero u32, then count 32-byte keys.
std::vector<uint8_t> encodeShaderInventoryReply(const std::vector<ShaderKey>& keys);

struct ShaderStoreLimits {
    uint64_t maxBytes = 256ull * 1024ull * 1024ull;
    uint32_t maxEntries = kShaderInventoryMaxKeys;
};

struct ShaderStoreStats {
    uint64_t entries = 0;
    uint64_t bytes = 0;
    uint64_t evictedAtOpen = 0;
    uint64_t resolved = 0;
    uint64_t resolvedBytes = 0;
    uint64_t unresolved = 0;
    uint64_t inserted = 0;
    uint64_t insertedBytes = 0;
    uint64_t insertSkipped = 0;
    uint64_t writeFailures = 0;
};

class ShaderStore {
public:
    // Opens or creates `directory`, removes interrupted writes and files that are not
    // entries, and evicts the least recently used entries beyond `limits`.
    static std::shared_ptr<ShaderStore> open(const std::string& directory, ShaderStoreLimits limits = {});

    std::vector<ShaderKey> inventory() const;
    // The verified code of `key`, which must be `codeSize` bytes. False if the store does not
    // hold it or its file no longer matches its key.
    bool resolve(const ShaderKey& key, uint32_t codeSize, std::vector<uint32_t>* out);
    // Keeps `code`. No-op when it is held or outside the size bounds; the budget is not
    // checked here, so a module the guest sent as code can always be named by token later.
    void insert(const void* code, size_t codeSize);
    ShaderStoreStats stats() const;
    const std::string& directory() const noexcept { return directory_; }

private:
    struct Entry {
        uint32_t size = 0;
        std::vector<uint32_t> memory;  // only when its file could not be written
    };
    explicit ShaderStore(std::string directory, ShaderStoreLimits limits);
    std::string pathOf(const ShaderKey& key) const;
    bool writeFile(const ShaderKey& key, const void* code, size_t codeSize);

    const std::string directory_;
    const ShaderStoreLimits limits_;
    mutable std::mutex mutex_;
    std::unordered_map<ShaderKey, Entry, ShaderKeyHash> entries_;
    uint64_t bytes_ = 0;
    ShaderStoreStats stats_;
    uint64_t tempCounter_ = 0;
};

// The store the decoder uses: `<root>/shaders` of the cache root the app set for the
// connected computer (caboose_gpu_runtime_set_cache_root). Null until a root is set.
std::shared_ptr<ShaderStore> currentShaderStore();
// Selects `root` (absolute), or no caches for null. On failure no caches are selected.
int setShaderStoreRoot(const char* root);
// That root, or empty. The persistent pipeline cache lives in `<root>/pipeline`.
std::string cacheRoot();

// Decoder hooks for vkCreateShaderModule (gfxstream fork, caboose_shader_cache.h).
enum class ShaderCodeSource { literal, resolved, unresolved };
// For a token, fills `out` with the module's code (resolved) or reports that the store does
// not hold it (unresolved). Anything else is literal code, used as it is.
ShaderCodeSource resolveShaderCode(const void* code, size_t codeSize, std::vector<uint32_t>* out);
// After a literal module was created, keeps its code for later tokens.
void rememberShaderCode(const void* code, size_t codeSize);

}  // namespace caboose::gpuv2
