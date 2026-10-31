// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// Portable fixture for media_bitstream.cpp: Annex-B splitting, parameter sets kept by ID,
// AVCC framing, OBU re-framing and AV1 and VP9 key-frame headers. The AV1 sequence header
// and VP9 frame header are from SVT-AV1 and libvpx streams (tests/media_fixtures.sh).
#include "media_bitstream.h"
#include <cstdio>
#include <cstdlib>

using namespace caboose::gpuv2::media;
#define CHECK(c) do { if (!(c)) { std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c); std::exit(1); } } while (0)

int main() {
    // Three- and four-byte start codes; trailing zero bytes are not part of a unit.
    const Bytes stream{0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 0, 1, 0x65, 9, 9};
    auto units = annexBUnits(stream.data(), stream.size());
    CHECK(units.size() == 3 && units[0] == Bytes({0x67, 1, 2}) && units[1] == Bytes({0x68, 3}) && units[2] == Bytes({0x65, 9, 9}));

    // H.264: SPS id 0 (ue "1"), PPS ids 0 and 1, then a slice framed with a 4-byte length.
    NalFormatter h264(false);
    NalFormatter::Sample s;
    const Bytes au{0, 0, 0, 1, 0x67, 0x64, 0x00, 0x1f, 0x80,    // SPS: profile, flags, level, id 0
                   0, 0, 0, 1, 0x68, 0x80,                        // PPS id 0
                   0, 0, 0, 1, 0x68, 0x40,                        // PPS id 1 ("010")
                   0, 0, 0, 1, 0x06, 0x05,                        // SEI: dropped
                   0, 0, 0, 1, 0x65, 0x88, 0x84};
    CHECK(h264.sample(au.data(), au.size(), &s) && s.parametersChanged);
    CHECK(s.avcc == Bytes({0, 0, 0, 3, 0x65, 0x88, 0x84}));
    CHECK(h264.parameterSets().size() == 3);
    CHECK(h264.sample(au.data(), au.size(), &s) && !s.parametersChanged);  // unchanged sets
    // A changed PPS 1 replaces only PPS 1.
    const Bytes pps{0, 0, 1, 0x68, 0x40, 0x10, 0, 0, 1, 0x41, 0x9a};
    CHECK(h264.sample(pps.data(), pps.size(), &s) && s.parametersChanged && h264.parameterSets().size() == 3);
    CHECK(s.avcc == Bytes({0, 0, 0, 2, 0x41, 0x9a}));
    NalFormatter incomplete(false);
    const Bytes spsOnly{0, 0, 1, 0x67, 0x64, 0x00, 0x1f, 0x80};
    CHECK(incomplete.sample(spsOnly.data(), spsOnly.size(), &s) && incomplete.parameterSets().empty());

    // HEVC: VPS, an SPS with no sub-layers (id after 12 header bytes), a PPS.
    NalFormatter hevc(true);
    Bytes hau{0, 0, 1, 0x40, 0x01, 0x0c};                         // VPS id 0
    hau.insert(hau.end(), {0, 0, 1, 0x42, 0x01, 0x01});            // SPS: vps 0, 0 sub-layers, nesting 1
    for (int i = 0; i < 12; ++i) hau.push_back(0x11);              // profile_tier_level
    hau.push_back(0xa0);                                           // sps id 0 ("1"), more bits
    hau.insert(hau.end(), {0, 0, 1, 0x44, 0x01, 0xc0});            // PPS id 0
    hau.insert(hau.end(), {0, 0, 1, 0x26, 0x01, 0xaf});            // IDR_W_RADL slice
    CHECK(hevc.sample(hau.data(), hau.size(), &s) && s.parametersChanged && hevc.parameterSets().size() == 3);
    CHECK(s.avcc == Bytes({0, 0, 0, 3, 0x26, 0x01, 0xaf}));

    // AV1: temporal delimiter dropped, the sequence header parsed (10-bit 640x360), sizes added.
    const Bytes tu{0x12, 0x00, 0x0a, 0x0b, 0x00, 0x00, 0x00, 0x0c, 0xc4, 0xff, 0x67, 0x1a, 0xbe, 0x70, 0x10,
                   0x32, 0x03, 0xaa, 0xbb, 0xcc};
    OBUFormatter obu;
    OBUFormatter::Sample a;
    CHECK(obu.sample(tu.data(), tu.size(), &a) && a.formatChanged && obu.sequence());
    CHECK(a.data == Bytes(tu.begin() + 2, tu.end()));
    const auto& h = *obu.sequence();
    CHECK(h.profile == 0 && h.highBitDepth && !h.monochrome && h.subsamplingX && h.subsamplingY);
    CHECK(h.maxWidth == 640 && h.maxHeight == 360);
    const Bytes av1c = h.configurationRecord(obu.sequenceHeaderObu());
    CHECK(av1c.size() == 4 + 13 && av1c[0] == 0x81 && (av1c[2] & 0x4c) == 0x4c);
    CHECK(obu.sample(tu.data(), tu.size(), &a) && !a.formatChanged);
    const Bytes unsized{0x30, 0xaa, 0xbb};  // a frame OBU without a size field: given one
    CHECK(obu.sample(unsized.data(), unsized.size(), &a) && a.data == Bytes({0x32, 0x02, 0xaa, 0xbb}));
    const Bytes forbidden{0x80, 0x00};
    CHECK(!obu.sample(forbidden.data(), forbidden.size(), &a));

    // VP9: a profile 2 key frame from libvpx (10-bit, 4:2:0, 640x360).
    const Bytes key{0x92, 0x49, 0x83, 0x42, 0x00, 0x13, 0xf8, 0x0b, 0x3b, 0x03, 0x1c, 0x12};
    auto vp9 = VP9KeyFrame::parse(key.data(), key.size());
    CHECK(vp9 && vp9->profile == 2 && vp9->bitDepth == 10 && vp9->width == 640 && vp9->height == 360);
    CHECK(vp9->subsamplingX && vp9->subsamplingY);
    const Bytes vpcc = vp9->configurationRecord();
    CHECK(vpcc.size() == 12 && vpcc[0] == 1 && vpcc[4] == 2 && (vpcc[6] >> 4) == 10);
    // The same frame as the first of a two-frame superframe; and an inter frame is not a key frame.
    Bytes super = key;
    super.insert(super.end(), {0x86, 0x00});                                 // a second, inter frame
    super.insert(super.end(), {0xc1, uint8_t(key.size()), 0x02, 0xc1});     // index: 2 frames, 1-byte sizes
    vp9 = VP9KeyFrame::parse(super.data(), super.size());
    CHECK(vp9 && vp9->width == 640);
    const Bytes inter{0x86, 0x00, 0x00};
    CHECK(!VP9KeyFrame::parse(inter.data(), inter.size()));
    std::printf("media bitstream: all checks passed\n");
    return 0;
}
