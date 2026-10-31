// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// The phone's side of docs/gpu-media.md: media stream records and LATCH packets. Byte
// layouts are pinned by guest/vaapi/tests/gpu-media-vectors.txt (tests/media_wire_test.cpp).
// Parsers validate structure and bounds only; every integer is little-endian.
#pragma once
#include <array>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

namespace caboose::gpuv2::media {
constexpr uint32_t kStreamFlags = 0x4d564243u;  // "CBVM", in place of Vulkan's client flags
constexpr uint32_t kVersion = 1;
constexpr uint32_t kMaxRecord = 16u << 20;
constexpr uint32_t kMaxCaps = 16;

enum RecordType : uint32_t {
    kHello = 0x01, kOpen = 0x02, kUnit = 0x03, kClose = 0x04, kSurfaceGone = 0x05,
    kCaps = 0x81, kFail = 0x82, kReplay = 0x83,
};
enum Codec : uint8_t { kH264 = 1, kHEVC = 2, kVP9 = 3, kAV1 = 4 };
enum FailReason : uint32_t { kFailUnsupported = 1, kFailDecode = 2 };
constexpr uint32_t kUnitKey = 0x01, kUnitHidden = 0x02, kUnitReplay = 0x04;

constexpr uint32_t kFourccNV12 = 0x3231564eu, kFourccP010 = 0x30313050u;

using Token = std::array<uint8_t, 16>;

inline uint16_t rd16(const uint8_t* p) { return uint16_t(p[0] | p[1] << 8); }
inline uint32_t rd32(const uint8_t* p) {
    return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24;
}
inline uint64_t rd64(const uint8_t* p) { return rd32(p) | uint64_t(rd32(p + 4)) << 32; }
inline void put16(std::vector<uint8_t>& o, uint16_t v) { o.push_back(uint8_t(v)); o.push_back(uint8_t(v >> 8)); }
inline void put32(std::vector<uint8_t>& o, uint32_t v) { for (int i = 0; i < 4; ++i) o.push_back(uint8_t(v >> (8 * i))); }

struct Open { uint32_t stream; uint8_t codec, depth, chroma; uint16_t width, height; };
struct Unit {
    uint32_t stream, seq, surface, flags;
    uint64_t serial;
    uint16_t width, height;
    const uint8_t* data;
    size_t size;
};
struct Capability { uint8_t codec, maxDepth; uint16_t maxWidth, maxHeight; };

inline bool parseHello(const uint8_t* p, size_t n, Token* token) {
    if (n != 20 || rd32(p) != kVersion) return false;
    std::memcpy(token->data(), p + 4, 16);
    return true;
}
inline bool parseOpen(const uint8_t* p, size_t n, Open* o) {
    if (n != 12 || p[7] != 0) return false;
    *o = {rd32(p), p[4], p[5], p[6], rd16(p + 8), rd16(p + 10)};
    return o->codec >= kH264 && o->codec <= kAV1 && o->chroma == 1 && (o->depth == 8 || o->depth == 10) &&
           o->width && o->height;
}
inline bool parseUnit(const uint8_t* p, size_t n, Unit* u) {
    if (n < 32 || rd32(p + 28) != 0) return false;
    *u = {rd32(p), rd32(p + 4), rd32(p + 8), rd32(p + 12), rd64(p + 16), rd16(p + 24), rd16(p + 26),
          p + 32, n - 32};
    return u->serial != 0 && !(u->flags & ~(kUnitKey | kUnitHidden | kUnitReplay));
}
inline bool parseWord(const uint8_t* p, size_t n, uint32_t* v) {
    if (n != 4) return false;
    *v = rd32(p);
    return true;
}

inline std::vector<uint8_t> record(uint32_t type, const std::vector<uint8_t>& payload) {
    std::vector<uint8_t> out;
    out.reserve(8 + payload.size());
    put32(out, type);
    put32(out, uint32_t(payload.size()));
    out.insert(out.end(), payload.begin(), payload.end());
    return out;
}
inline std::vector<uint8_t> encodeCaps(const std::vector<Capability>& caps) {
    std::vector<uint8_t> p;
    put32(p, kVersion);
    const uint32_t count = caps.size() > kMaxCaps ? kMaxCaps : uint32_t(caps.size());
    put32(p, count);
    for (uint32_t i = 0; i < count; ++i) {
        p.push_back(caps[i].codec); p.push_back(caps[i].maxDepth); put16(p, 0);
        put16(p, caps[i].maxWidth); put16(p, caps[i].maxHeight);
    }
    return record(kCaps, p);
}
inline std::vector<uint8_t> encodeFail(uint32_t stream, uint32_t reason) {
    std::vector<uint8_t> p; put32(p, stream); put32(p, reason); return record(kFail, p);
}
inline std::vector<uint8_t> encodeReplay(uint32_t stream) {
    std::vector<uint8_t> p; put32(p, stream); return record(kReplay, p);
}

// ---- LATCH -----------------------------------------------------------------
constexpr uint32_t kLatchOpcode = 0x4c564243u;  // "CBVL"
constexpr size_t kLatchHead = 24, kLatchEntry = 24, kLatchPicture = 32, kLatchPixels = 16;
constexpr uint32_t kMaxLatchEntries = 64;
enum LatchKind : uint32_t { kPicture = 1, kPixels = 2 };
constexpr uint32_t kPlaneLuma = 1, kPlaneChroma = 2;

struct LatchEntry {
    uint64_t image;
    uint32_t kind, planes, fourcc;
    uint16_t width, height;
    // kPicture
    Token token{};
    uint32_t surface = 0;
    uint64_t serial = 0;
    // kPixels: the planes the image holds, luma first, `pitch` bytes per row
    uint32_t pitch = 0, uvOffset = 0;
    const uint8_t* pixels = nullptr;
    uint64_t pixelBytes = 0;
};
struct Latch { uint64_t queue; std::vector<LatchEntry> entries; };

inline uint32_t bytesPerSample(uint32_t fourcc) {
    return fourcc == kFourccNV12 ? 1 : fourcc == kFourccP010 ? 2 : 0;
}
// Bytes a pixels entry carries for `planes` of a picture.
inline uint64_t pixelPayload(uint32_t planes, uint32_t pitch, uint32_t height) {
    uint64_t bytes = 0;
    if (planes & kPlaneLuma) bytes += uint64_t(pitch) * height;
    if (planes & kPlaneChroma) bytes += uint64_t(pitch) * ((height + 1u) / 2u);
    return bytes;
}

// `data` holds exactly one packet of `size` bytes (its declared size). Returns 0 or EPROTO.
inline int parseLatch(const uint8_t* data, size_t size, Latch* out) {
    if (size < kLatchHead || rd32(data) != kLatchOpcode || rd32(data + 4) != size) return EPROTO;
    const uint32_t count = rd32(data + 16);
    if (!count || count > kMaxLatchEntries || rd32(data + 20) != 0) return EPROTO;
    out->queue = rd64(data + 8);
    out->entries.clear();
    out->entries.reserve(count);
    size_t at = kLatchHead;
    for (uint32_t i = 0; i < count; ++i) {
        if (size - at < kLatchEntry) return EPROTO;
        const uint8_t* e = data + at;
        LatchEntry entry{rd64(e), rd32(e + 8), rd32(e + 12), rd32(e + 16), rd16(e + 20), rd16(e + 22)};
        at += kLatchEntry;
        const uint32_t bps = bytesPerSample(entry.fourcc);
        if (!entry.image || !bps || !entry.width || !entry.height || !entry.planes ||
            (entry.planes & ~(kPlaneLuma | kPlaneChroma))) return EPROTO;
        if (entry.kind == kPicture) {
            if (size - at < kLatchPicture || rd32(data + at + 20) != 0) return EPROTO;
            std::memcpy(entry.token.data(), data + at, 16);
            entry.surface = rd32(data + at + 16);
            entry.serial = rd64(data + at + 24);
            if (!entry.serial) return EPROTO;
            at += kLatchPicture;
        } else if (entry.kind == kPixels) {
            if (size - at < kLatchPixels) return EPROTO;
            entry.pitch = rd32(data + at);
            entry.uvOffset = rd32(data + at + 4);
            entry.pixelBytes = rd64(data + at + 8);
            at += kLatchPixels;
            const uint32_t chromaWidth = (entry.width + 1u) / 2u * 2u;
            if (uint64_t(entry.pitch) < uint64_t(chromaWidth) * bps || entry.pitch % (2 * bps) ||
                entry.pixelBytes != pixelPayload(entry.planes, entry.pitch, entry.height) ||
                entry.pixelBytes > size - at) return EPROTO;
            entry.pixels = data + at;
            at += size_t(entry.pixelBytes);
        } else {
            return EPROTO;
        }
        out->entries.push_back(entry);
    }
    return at == size ? 0 : EPROTO;
}
}
