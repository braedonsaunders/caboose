// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// The compressed units of docs/gpu-media.md as Core Media takes them: H.264 and HEVC
// parameter sets and length-prefixed pictures, AV1 temporal units with the av1C record,
// and VP9 frames with the vpcC record. Pure C++; no Apple dependency.
#pragma once
#include <cstddef>
#include <cstdint>
#include <map>
#include <optional>
#include <vector>

namespace caboose::gpuv2::media {
using Bytes = std::vector<uint8_t>;

// Start-code delimited NAL unit payloads of an Annex-B byte stream.
std::vector<Bytes> annexBUnits(const uint8_t* data, size_t size);

// MSB-first bit reader over an RBSP; reads past the end set `overrun` and return zero.
class BitReader {
public:
    BitReader(const uint8_t* data, size_t size) : data_(data), size_(size) {}
    uint32_t bits(unsigned count);
    bool flag() { return bits(1) != 0; }
    uint32_t ue();
    uint32_t uvlc();
    void skip(size_t count);
    bool overrun() const { return overrun_; }
private:
    const uint8_t* data_;
    size_t size_, position_ = 0;
    bool overrun_ = false;
};
Bytes unescapeRbsp(const uint8_t* data, size_t size);

// H.264 and HEVC Annex-B access units: the parameter sets by ID, and each picture's VCL
// units framed with 4-byte big-endian lengths.
class NalFormatter {
public:
    explicit NalFormatter(bool hevc) : hevc_(hevc) {}
    struct Sample { Bytes avcc; bool parametersChanged = false; };
    // False when a parameter set cannot be parsed. avcc is empty when the unit has no VCL.
    bool sample(const uint8_t* data, size_t size, Sample* out);
    // VPS (HEVC), SPS and PPS in that order; empty until each kind has arrived.
    std::vector<Bytes> parameterSets() const;
private:
    bool hevc_;
    std::map<uint32_t, Bytes> vps_, sps_, pps_;
};

// AV1 (AV1 spec §5.5): what the av1C record needs from a sequence header.
struct AV1SequenceHeader {
    uint32_t profile = 0, level = 0, tier = 0;
    bool highBitDepth = false, twelveBit = false, monochrome = false;
    bool subsamplingX = true, subsamplingY = true;
    uint32_t chromaSamplePosition = 0, maxWidth = 0, maxHeight = 0;
    bool fullRange = false;
    uint32_t colorPrimaries = 2, transferCharacteristics = 2, matrixCoefficients = 2;
    static std::optional<AV1SequenceHeader> parse(const uint8_t* payload, size_t size);
    Bytes configurationRecord(const Bytes& sequenceHeaderObu) const;
};

// Temporal units of OBUs: temporal delimiters and padding dropped, every OBU given a size field.
class OBUFormatter {
public:
    struct Sample { Bytes data; bool formatChanged = false; };
    bool sample(const uint8_t* data, size_t size, Sample* out);
    const std::optional<AV1SequenceHeader>& sequence() const { return sequence_; }
    const Bytes& sequenceHeaderObu() const { return sequenceObu_; }
private:
    std::optional<AV1SequenceHeader> sequence_;
    Bytes sequenceObu_;
};

// VP9 (VP9 spec §6.2): the key frame's uncompressed header, for the vpcC record.
struct VP9KeyFrame {
    uint32_t profile = 0, bitDepth = 8, width = 0, height = 0;
    bool subsamplingX = true, subsamplingY = true, fullRange = false;
    uint32_t colorSpace = 0;
    // The first frame of a frame or superframe, when it is a key frame.
    static std::optional<VP9KeyFrame> parse(const uint8_t* data, size_t size);
    Bytes configurationRecord() const;  // vpcC, version 1
};
}
