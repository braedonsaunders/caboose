// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "media_bitstream.h"

namespace caboose::gpuv2::media {
std::vector<Bytes> annexBUnits(const uint8_t* b, size_t n) {
    std::vector<Bytes> units;
    size_t i = 0;
    bool started = false;
    size_t begin = 0;
    while (i + 2 < n) {
        if (b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1) {
            if (started) {
                size_t end = i;
                while (end > begin && b[end - 1] == 0) --end;  // a four-byte start code, or trailing zeros
                if (end > begin) units.emplace_back(b + begin, b + end);
            }
            i += 3;
            begin = i;
            started = true;
        } else {
            ++i;
        }
    }
    if (started && begin < n) units.emplace_back(b + begin, b + n);
    return units;
}

uint32_t BitReader::bits(unsigned count) {
    uint32_t v = 0;
    for (unsigned k = 0; k < count; ++k) {
        if (position_ >= size_ * 8) { overrun_ = true; return 0; }
        v = v << 1 | ((data_[position_ / 8] >> (7 - position_ % 8)) & 1u);
        ++position_;
    }
    return v;
}
uint32_t BitReader::ue() {
    unsigned zeros = 0;
    while (!bits(1)) {
        if (overrun_ || ++zeros > 31) { overrun_ = true; return 0; }
    }
    return zeros ? (bits(zeros) + (1u << zeros) - 1u) : 0;
}
uint32_t BitReader::uvlc() {
    unsigned zeros = 0;
    while (!bits(1)) {
        if (overrun_) return 0;
        if (++zeros >= 32) return UINT32_MAX;
    }
    return zeros ? bits(zeros) + (1u << zeros) - 1u : 0;
}
void BitReader::skip(size_t count) {
    position_ += count;
    if (position_ > size_ * 8) { position_ = size_ * 8; overrun_ = true; }
}

Bytes unescapeRbsp(const uint8_t* d, size_t n) {
    Bytes out;
    out.reserve(n);
    unsigned zeros = 0;
    for (size_t i = 0; i < n; ++i) {
        if (zeros >= 2 && d[i] == 3) { zeros = 0; continue; }
        zeros = d[i] == 0 ? zeros + 1 : 0;
        out.push_back(d[i]);
    }
    return out;
}

namespace {
// The parameter set's own ID, read from its RBSP after the NAL header.
bool parameterId(bool hevc, unsigned type, const Bytes& unit, uint32_t* id) {
    const size_t header = hevc ? 2 : 1;
    if (unit.size() <= header) return false;
    Bytes rbsp = unescapeRbsp(unit.data() + header, unit.size() - header);
    BitReader r(rbsp.data(), rbsp.size());
    if (!hevc) {
        if (type == 7) r.skip(24);  // profile_idc, constraint flags, level_idc
        *id = r.ue();
        return !r.overrun() && *id < 256;
    }
    if (type == 32) { *id = r.bits(4); return !r.overrun(); }
    if (type == 34) { *id = r.ue(); return !r.overrun() && *id < 64; }
    r.skip(4);  // sps_video_parameter_set_id
    const uint32_t subLayers = r.bits(3);
    r.skip(1);
    r.skip(96);  // general profile_tier_level and general_level_idc
    bool profile[8] = {}, level[8] = {};
    for (uint32_t i = 0; i < subLayers; ++i) { profile[i] = r.flag(); level[i] = r.flag(); }
    if (subLayers > 0)
        for (uint32_t i = subLayers; i < 8; ++i) r.skip(2);
    for (uint32_t i = 0; i < subLayers; ++i) {
        if (profile[i]) r.skip(88);
        if (level[i]) r.skip(8);
    }
    *id = r.ue();
    return !r.overrun() && *id < 16;
}
void appendLength(Bytes& out, size_t n) {
    for (int s = 24; s >= 0; s -= 8) out.push_back(uint8_t(n >> s));
}
}

bool NalFormatter::sample(const uint8_t* data, size_t size, Sample* out) {
    out->avcc.clear();
    out->parametersChanged = false;
    for (auto& unit : annexBUnits(data, size)) {
        if (unit.empty()) continue;
        const unsigned type = hevc_ ? (unit[0] >> 1) & 0x3f : unit[0] & 0x1f;
        std::map<uint32_t, Bytes>* sets = nullptr;
        if (hevc_) {
            if (type == 32) sets = &vps_;
            else if (type == 33) sets = &sps_;
            else if (type == 34) sets = &pps_;
        } else {
            if (type == 7) sets = &sps_;
            else if (type == 8) sets = &pps_;
        }
        if (sets) {
            uint32_t id;
            if (!parameterId(hevc_, type, unit, &id)) return false;
            auto& slot = (*sets)[id];
            if (slot != unit) { slot = unit; out->parametersChanged = true; }
            continue;
        }
        const bool vcl = hevc_ ? type <= 31 : (type >= 1 && type <= 5);
        if (!vcl) continue;  // SEI, delimiters and filler carry nothing the decoder needs
        appendLength(out->avcc, unit.size());
        out->avcc.insert(out->avcc.end(), unit.begin(), unit.end());
    }
    return true;
}

std::vector<Bytes> NalFormatter::parameterSets() const {
    std::vector<Bytes> sets;
    if ((hevc_ && vps_.empty()) || sps_.empty() || pps_.empty()) return sets;
    for (auto* m : {&vps_, &sps_, &pps_})
        for (auto& [id, unit] : *m) { (void)id; sets.push_back(unit); }
    return sets;
}

std::optional<AV1SequenceHeader> AV1SequenceHeader::parse(const uint8_t* payload, size_t size) {
    BitReader b(payload, size);
    AV1SequenceHeader h;
    h.profile = b.bits(3);
    b.skip(1);  // still_picture
    const bool reduced = b.flag();
    if (reduced) {
        h.level = b.bits(5);
    } else {
        bool decoderModel = false;
        unsigned bufferDelayLength = 0;
        if (b.flag()) {  // timing_info_present_flag
            b.skip(64);
            if (b.flag()) b.uvlc();  // equal_picture_interval
            decoderModel = b.flag();
            if (decoderModel) {
                bufferDelayLength = b.bits(5) + 1;
                b.skip(32 + 5 + 5);
            }
        }
        const bool initialDisplayDelay = b.flag();
        const uint32_t points = b.bits(5) + 1;
        for (uint32_t i = 0; i < points; ++i) {
            b.skip(12);  // operating_point_idc
            const uint32_t level = b.bits(5);
            const uint32_t tier = level > 7 ? b.bits(1) : 0;
            if (i == 0) { h.level = level; h.tier = tier; }
            if (decoderModel && b.flag()) b.skip(2 * bufferDelayLength + 1);
            if (initialDisplayDelay && b.flag()) b.skip(4);
        }
    }
    const unsigned widthBits = b.bits(4) + 1, heightBits = b.bits(4) + 1;
    h.maxWidth = b.bits(widthBits) + 1;
    h.maxHeight = b.bits(heightBits) + 1;
    if (!reduced && b.flag()) b.skip(7);  // frame_id_numbers_present_flag, its lengths
    b.skip(3);  // use_128x128_superblock, enable_filter_intra, enable_intra_edge_filter
    if (!reduced) {
        b.skip(4);  // interintra, masked compound, warped motion, dual filter
        const bool orderHint = b.flag();
        if (orderHint) b.skip(2);  // jnt_comp, ref_frame_mvs
        const uint32_t screenContent = b.flag() ? 2 : b.bits(1);
        if (screenContent > 0 && !b.flag()) b.skip(1);  // seq_force_integer_mv
        if (orderHint) b.skip(3);
    }
    b.skip(3);  // superres, cdef, restoration
    h.highBitDepth = b.flag();
    h.twelveBit = h.profile == 2 && h.highBitDepth ? b.flag() : false;
    h.monochrome = h.profile == 1 ? false : b.flag();
    if (b.flag()) {
        h.colorPrimaries = b.bits(8);
        h.transferCharacteristics = b.bits(8);
        h.matrixCoefficients = b.bits(8);
    }
    if (h.monochrome) {
        h.fullRange = b.flag();
    } else if (h.colorPrimaries == 1 && h.transferCharacteristics == 13 && h.matrixCoefficients == 0) {
        h.fullRange = true;
        h.subsamplingX = h.subsamplingY = false;
    } else {
        h.fullRange = b.flag();
        if (h.profile == 1) {
            h.subsamplingX = h.subsamplingY = false;
        } else if (h.profile == 2) {
            if (h.twelveBit) {
                h.subsamplingX = b.flag();
                h.subsamplingY = h.subsamplingX ? b.flag() : false;
            } else {
                h.subsamplingX = true;
                h.subsamplingY = false;
            }
        }
        if (h.subsamplingX && h.subsamplingY) h.chromaSamplePosition = b.bits(2);
    }
    if (b.overrun()) return std::nullopt;
    return h;
}

Bytes AV1SequenceHeader::configurationRecord(const Bytes& obu) const {
    Bytes out{0x81, uint8_t(profile << 5 | (level & 0x1f))};
    uint8_t flags = uint8_t(tier << 7);
    if (highBitDepth) flags |= 0x40;
    if (twelveBit) flags |= 0x20;
    if (monochrome) flags |= 0x10;
    if (subsamplingX) flags |= 0x08;
    if (subsamplingY) flags |= 0x04;
    flags |= uint8_t(chromaSamplePosition & 3);
    out.push_back(flags);
    out.push_back(0);  // no initial_presentation_delay
    out.insert(out.end(), obu.begin(), obu.end());
    return out;
}

bool OBUFormatter::sample(const uint8_t* d, size_t n, Sample* out) {
    out->data.clear();
    out->formatChanged = false;
    size_t i = 0;
    while (i < n) {
        const uint8_t first = d[i];
        if (first & 0x80) return false;  // obu_forbidden_bit
        const unsigned type = (first >> 3) & 0x0f;
        const size_t headerLength = (first & 0x04) ? 2 : 1;
        if (n - i < headerLength) return false;
        const size_t headerAt = i;
        i += headerLength;
        uint64_t length = 0;
        if (first & 0x02) {
            unsigned shift = 0;
            for (;;) {
                if (i >= n || shift >= 56) return false;
                const uint8_t byte = d[i++];
                length |= uint64_t(byte & 0x7f) << shift;
                shift += 7;
                if (!(byte & 0x80)) break;
            }
        } else {
            length = n - i;
        }
        if (length > n - i) return false;
        const uint8_t* payload = d + i;
        i += size_t(length);
        if (type == 2 || type == 15) continue;  // temporal delimiter, padding: not in a sample
        Bytes sized(d + headerAt, d + headerAt + headerLength);
        sized[0] |= 0x02;  // obu_has_size_field
        uint64_t v = length;
        do {
            uint8_t byte = v & 0x7f;
            v >>= 7;
            if (v) byte |= 0x80;
            sized.push_back(byte);
        } while (v);
        sized.insert(sized.end(), payload, payload + length);
        if (type == 1 && sized != sequenceObu_) {
            auto header = AV1SequenceHeader::parse(payload, size_t(length));
            if (!header) return false;
            sequence_ = header;
            sequenceObu_ = sized;
            out->formatChanged = true;
        }
        out->data.insert(out->data.end(), sized.begin(), sized.end());
    }
    return true;
}

std::optional<VP9KeyFrame> VP9KeyFrame::parse(const uint8_t* d, size_t n) {
    if (!n) return std::nullopt;
    // A superframe ends in its index; its first frame is the one decoding starts with.
    const uint8_t marker = d[n - 1];
    if ((marker & 0xe0) == 0xc0) {
        const unsigned frames = (marker & 7) + 1, mag = ((marker >> 3) & 3) + 1;
        const size_t index = 2 + size_t(mag) * frames;
        if (n >= index && d[n - index] == marker) {
            size_t first = 0;
            for (unsigned k = 0; k < mag; ++k) first |= size_t(d[n - index + 1 + k]) << (8 * k);
            if (!first || first > n - index) return std::nullopt;
            n = first;
        }
    }
    BitReader b(d, n);
    if (b.bits(2) != 2) return std::nullopt;  // frame_marker
    VP9KeyFrame f;
    const uint32_t low = b.bits(1), high = b.bits(1);
    f.profile = high << 1 | low;
    if (f.profile == 3) b.skip(1);
    if (b.flag()) return std::nullopt;   // show_existing_frame
    if (b.flag()) return std::nullopt;   // frame_type: not a key frame
    b.skip(2);                           // show_frame, error_resilient_mode
    if (b.bits(24) != 0x498342) return std::nullopt;  // frame_sync_code
    if (f.profile >= 2) f.bitDepth = b.flag() ? 12 : 10;
    f.colorSpace = b.bits(3);
    if (f.colorSpace != 7) {
        f.fullRange = b.flag();
        if (f.profile == 1 || f.profile == 3) {
            f.subsamplingX = b.flag();
            f.subsamplingY = b.flag();
            b.skip(1);
        }
    } else {
        f.fullRange = true;
        f.subsamplingX = f.subsamplingY = false;
        if (f.profile == 1 || f.profile == 3) b.skip(1);
    }
    f.width = b.bits(16) + 1;
    f.height = b.bits(16) + 1;
    if (b.overrun()) return std::nullopt;
    return f;
}

Bytes VP9KeyFrame::configurationRecord() const {
    // VP9 colour spaces as H.273 primaries, transfer characteristics and matrix.
    static const uint8_t colours[8][3] = {{2, 2, 2}, {6, 6, 6}, {1, 1, 1}, {6, 6, 6},
                                          {7, 7, 7}, {9, 14, 9}, {2, 2, 2}, {1, 13, 0}};
    const uint8_t* c = colours[colorSpace & 7];
    const uint8_t chroma = subsamplingX && subsamplingY ? 1 : subsamplingX ? 2 : 3;
    return Bytes{1, 0, 0, 0, uint8_t(profile), 0,
                 uint8_t(bitDepth << 4 | chroma << 1 | (fullRange ? 1 : 0)), c[0], c[1], c[2], 0, 0};
}
}
