// SPDX-License-Identifier: MIT
// Imported dmabufs on the Caboose socket transport (docs/gpu-media.md).
//
// The phone has neither dmabufs nor DRM format modifiers, so an image created
// over an imported dmabuf is an ordinary optimal image on the phone with its
// own device memory, and the dmabuf stays here, mapped read-only. Before each
// queue submission the driver decides, per such image, whether the phone must
// fill it again: from its own decoded picture, named by the surface identity
// at the dmabuf's end (gpu_media.h), or from the pixels in the mapping. It
// says so in LATCH packets written into the ordered device stream just ahead
// of the submission.
//
// This header is the pure part: plane bookkeeping, change tracking and packet
// encoding, with no Vulkan or transport dependency, so it is unit-tested on
// any host (caboose-media/media_import_test.cpp).
#pragma once
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

#include "gpu_media.h"

namespace caboose::media {

// How an imported image's format relates to an NV12/P010 surface.
enum class PlaneFormat : uint8_t {
    unsupported,
    twoPlane8,   // G8_B8R8_2PLANE_420_UNORM: the whole surface
    twoPlane16,  // G10X6_B10X6R10X6_2PLANE_420_UNORM_3PACK16 / G16_B16R16_2PLANE_420_UNORM
    luma8,       // R8_UNORM
    luma16,      // R16_UNORM
    chroma8,     // R8G8_UNORM
    chroma16,    // R16G16_UNORM
};

inline unsigned bytesPerSample(PlaneFormat f) {
    switch (f) {
    case PlaneFormat::twoPlane8: case PlaneFormat::luma8: case PlaneFormat::chroma8: return 1;
    case PlaneFormat::twoPlane16: case PlaneFormat::luma16: case PlaneFormat::chroma16: return 2;
    default: return 0;
    }
}
inline bool isTwoPlane(PlaneFormat f) { return f == PlaneFormat::twoPlane8 || f == PlaneFormat::twoPlane16; }
inline bool isLuma(PlaneFormat f) { return f == PlaneFormat::luma8 || f == PlaneFormat::luma16; }
inline bool isChroma(PlaneFormat f) { return f == PlaneFormat::chroma8 || f == PlaneFormat::chroma16; }

// An image created over a dmabuf with explicit linear plane layouts.
struct ImageDesc {
    PlaneFormat format = PlaneFormat::unsupported;
    uint32_t width = 0, height = 0; // the image's extent
    uint32_t planeCount = 0;        // explicit layouts given: 2 for two-plane formats, else 1
    uint64_t offset[2] = {0, 0};    // byte offsets into the dmabuf
    uint64_t pitch[2] = {0, 0};
};

// What one LATCH entry says about one image, before encoding.
struct Entry {
    uint64_t image = 0; // wire handle
    uint32_t kind = 0;  // CB_GM_KIND_PICTURE or CB_GM_KIND_PIXELS
    uint32_t planes = 0;
    uint32_t fourcc = 0;
    uint16_t width = 0, height = 0;
    // PICTURE
    uint8_t token[16] = {};
    uint32_t surface = 0;
    uint64_t serial = 0;
    // PIXELS
    uint32_t pitch = 0, uvOffset = 0;
    std::vector<uint8_t> bytes;
};

inline size_t encodedSize(const Entry& e) {
    return CB_GM_LATCH_ENTRY + (e.kind == CB_GM_KIND_PICTURE ? CB_GM_LATCH_PICTURE
                                                             : CB_GM_LATCH_PIXELS + e.bytes.size());
}

// Packets for one submission's queue: at most CB_GM_LATCH_MAX_ENTRIES entries
// each, and a new packet once one would grow beyond maxBytes (an entry larger
// than that travels alone).
inline std::vector<std::vector<uint8_t>> encodeLatches(uint64_t queue, const std::vector<Entry>& entries,
                                                       size_t maxBytes = 8u << 20) {
    std::vector<std::vector<uint8_t>> packets;
    size_t i = 0;
    while (i < entries.size()) {
        size_t size = CB_GM_LATCH_HEAD, count = 0;
        while (i + count < entries.size() && count < CB_GM_LATCH_MAX_ENTRIES) {
            size_t next = encodedSize(entries[i + count]);
            if (count && size + next > maxBytes) break;
            size += next;
            ++count;
        }
        std::vector<uint8_t> p(size);
        uint8_t* w = p.data();
        cb_gm_le32(w, CB_GM_LATCH_OPCODE);
        cb_gm_le32(w + 4, static_cast<uint32_t>(size));
        cb_gm_le64(w + 8, queue);
        cb_gm_le32(w + 16, static_cast<uint32_t>(count));
        cb_gm_le32(w + 20, 0);
        w += CB_GM_LATCH_HEAD;
        for (size_t k = 0; k < count; ++k) {
            const Entry& e = entries[i + k];
            cb_gm_le64(w, e.image);
            cb_gm_le32(w + 8, e.kind);
            cb_gm_le32(w + 12, e.planes);
            cb_gm_le32(w + 16, e.fourcc);
            cb_gm_le16(w + 20, e.width);
            cb_gm_le16(w + 22, e.height);
            w += CB_GM_LATCH_ENTRY;
            if (e.kind == CB_GM_KIND_PICTURE) {
                std::memcpy(w, e.token, 16);
                cb_gm_le32(w + 16, e.surface);
                cb_gm_le32(w + 20, 0);
                cb_gm_le64(w + 24, e.serial);
                w += CB_GM_LATCH_PICTURE;
            } else {
                cb_gm_le32(w, e.pitch);
                cb_gm_le32(w + 4, e.uvOffset);
                cb_gm_le64(w + 8, e.bytes.size());
                w += CB_GM_LATCH_PIXELS;
                if (!e.bytes.empty()) std::memcpy(w, e.bytes.data(), e.bytes.size());
                w += e.bytes.size();
            }
        }
        packets.push_back(std::move(p));
        i += count;
    }
    return packets;
}

// Which surface planes an image holds, checked against the surface's identity.
// Returns 0 when the image does not match the surface's layout.
inline uint32_t planesForIdentity(const ImageDesc& d, const cb_gm_identity& id) {
    unsigned bps = id.fourcc == CB_GM_FOURCC_P010 ? 2u : 1u;
    if (bytesPerSample(d.format) != bps || !d.width || !d.height) return 0;
    const uint32_t cw = (id.width + 1u) / 2u, ch = (id.height + 1u) / 2u;
    if (isTwoPlane(d.format)) {
        if (d.planeCount != 2 || d.offset[0] != 0 || d.offset[1] != id.uv_offset ||
            d.pitch[0] != id.pitch || d.pitch[1] != id.pitch || d.width > id.width || d.height > id.height)
            return 0;
        return CB_GM_PLANE_LUMA | CB_GM_PLANE_CHROMA;
    }
    if (d.planeCount != 1 || d.pitch[0] != id.pitch) return 0;
    if (isLuma(d.format) && d.offset[0] == 0 && d.width <= id.width && d.height <= id.height)
        return CB_GM_PLANE_LUMA;
    if (isChroma(d.format) && d.offset[0] == id.uv_offset && d.width <= cw && d.height <= ch)
        return CB_GM_PLANE_CHROMA;
    return 0;
}

// The picture geometry a foreign import (no identity) implies, as a surface:
// planes, fourcc, picture size, pitch, and the byte offset of each held plane.
struct ForeignLayout {
    uint32_t planes = 0, fourcc = 0, width = 0, height = 0, pitch = 0;
    uint64_t lumaOffset = 0, chromaOffset = 0;
};

inline bool foreignLayout(const ImageDesc& d, ForeignLayout* out) {
    unsigned bps = bytesPerSample(d.format);
    if (!bps || !d.width || !d.height || d.width > 0xffff || d.height > 0xffff) return false;
    ForeignLayout l;
    l.fourcc = bps == 2 ? CB_GM_FOURCC_P010 : CB_GM_FOURCC_NV12;
    if (isTwoPlane(d.format)) {
        if (d.planeCount != 2 || d.pitch[0] != d.pitch[1]) return false;
        l.planes = CB_GM_PLANE_LUMA | CB_GM_PLANE_CHROMA;
        l.width = d.width;
        l.height = d.height;
        l.lumaOffset = d.offset[0];
        l.chromaOffset = d.offset[1];
    } else if (isLuma(d.format)) {
        l.planes = CB_GM_PLANE_LUMA;
        l.width = d.width;
        l.height = d.height;
        l.lumaOffset = d.offset[0];
    } else {
        l.planes = CB_GM_PLANE_CHROMA;
        l.width = d.width * 2u;
        l.height = d.height * 2u;
        if (l.width > 0xffff || l.height > 0xffff) return false;
        l.chromaOffset = d.offset[0];
    }
    if (d.pitch[0] > 0xffffffffu || d.pitch[0] < uint64_t(l.width) * bps) return false;
    l.pitch = static_cast<uint32_t>(d.pitch[0]);
    *out = l;
    return true;
}

// Copies the held planes (luma first, `pitch` bytes per row) out of a mapping.
// Returns false when they do not lie inside it.
inline bool gatherPlanes(const uint8_t* map, size_t size, uint32_t planes, uint32_t pitch,
                         uint32_t height, uint64_t lumaOffset, uint64_t chromaOffset,
                         std::vector<uint8_t>* out, uint32_t* chromaAt) {
    const uint64_t lumaBytes = uint64_t(pitch) * height;
    const uint64_t chromaBytes = uint64_t(pitch) * ((height + 1u) / 2u);
    uint64_t total = 0;
    if (planes & CB_GM_PLANE_LUMA) {
        if (lumaOffset > size || lumaBytes > size - lumaOffset) return false;
        total += lumaBytes;
    }
    if (planes & CB_GM_PLANE_CHROMA) {
        if (chromaOffset > size || chromaBytes > size - chromaOffset) return false;
        total += chromaBytes;
    }
    if (total > 0xffffffffu) return false;
    out->resize(static_cast<size_t>(total));
    size_t at = 0;
    if (planes & CB_GM_PLANE_LUMA) {
        std::memcpy(out->data(), map + lumaOffset, static_cast<size_t>(lumaBytes));
        at = static_cast<size_t>(lumaBytes);
    }
    // The chroma plane's offset within the carried bytes: after the luma rows when both
    // are carried, zero when only chroma is.
    *chromaAt = static_cast<uint32_t>(at);
    if (planes & CB_GM_PLANE_CHROMA)
        std::memcpy(out->data() + at, map + chromaOffset, static_cast<size_t>(chromaBytes));
    return true;
}

// What was last sent for one image.
struct LatchState {
    bool sent = false;      // anything decided yet
    bool identified = false;
    uint32_t state = 0;
    uint8_t token[16] = {};
    uint64_t serial = 0;
    std::vector<uint8_t> shadow; // foreign imports: the pixels last sent
};

enum class Decision { none, latch, mismatch };

// Decides whether `image` (over a dmabuf mapped at map/size) needs a latch now,
// fills *entry if so and updates *state. A surface identity decides by its
// (state, token, serial); a foreign import by whether its pixels changed.
inline Decision evaluate(uint64_t image, const ImageDesc& d, const uint8_t* map, size_t size,
                         LatchState* state, Entry* entry) {
    cb_gm_identity id;
    const cb_gm_identity_page* page = map ? cb_gm_identity_at(const_cast<uint8_t*>(map), size) : nullptr;
    if (page && cb_gm_identity_read(page, size, &id)) {
        if (state->sent && state->identified && state->state == id.state && state->serial == id.serial &&
            !std::memcmp(state->token, id.token, 16))
            return Decision::none;
        state->sent = true;
        state->identified = true;
        state->state = id.state;
        state->serial = id.serial;
        std::memcpy(state->token, id.token, 16);
        state->shadow.clear();
        if (id.state == CB_GM_EMPTY) return Decision::none;
        const uint32_t planes = planesForIdentity(d, id);
        if (!planes) return Decision::mismatch;
        *entry = Entry{};
        entry->image = image;
        entry->planes = planes;
        entry->fourcc = id.fourcc;
        entry->width = id.width;
        entry->height = id.height;
        if (id.state == CB_GM_PHONE) {
            entry->kind = CB_GM_KIND_PICTURE;
            std::memcpy(entry->token, id.token, 16);
            entry->surface = id.surface;
            entry->serial = id.serial;
            return Decision::latch;
        }
        entry->kind = CB_GM_KIND_PIXELS;
        entry->pitch = id.pitch;
        if (!gatherPlanes(map, size, planes, id.pitch, id.height, 0, id.uv_offset, &entry->bytes,
                          &entry->uvOffset))
            return Decision::mismatch;
        return Decision::latch;
    }
    ForeignLayout l;
    if (!map || !foreignLayout(d, &l)) return Decision::mismatch;
    std::vector<uint8_t> bytes;
    uint32_t chromaAt = 0;
    if (!gatherPlanes(map, size, l.planes, l.pitch, l.height, l.lumaOffset, l.chromaOffset, &bytes, &chromaAt))
        return Decision::mismatch;
    if (state->sent && !state->identified && state->shadow == bytes) return Decision::none;
    state->sent = true;
    state->identified = false;
    state->state = 0;
    state->serial = 0;
    state->shadow = bytes;
    *entry = Entry{};
    entry->image = image;
    entry->kind = CB_GM_KIND_PIXELS;
    entry->planes = l.planes;
    entry->fourcc = l.fourcc;
    entry->width = static_cast<uint16_t>(l.width);
    entry->height = static_cast<uint16_t>(l.height);
    entry->pitch = l.pitch;
    entry->uvOffset = chromaAt;
    entry->bytes = std::move(bytes);
    return Decision::latch;
}

}  // namespace caboose::media
