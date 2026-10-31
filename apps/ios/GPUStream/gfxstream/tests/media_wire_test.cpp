// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// Portable fixture: every record of guest/vaapi/tests/gpu-media-vectors.txt (argv[1]) parses
// to the values the vector was built from, the phone's encoders reproduce its records byte
// for byte, and truncations and corruptions are rejected.
#include "media_wire.h"
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <map>
#include <sstream>
#include <string>

using namespace caboose::gpuv2::media;
#define CHECK(c) do { if (!(c)) { std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c); std::exit(1); } } while (0)

namespace {
std::map<std::string, std::vector<uint8_t>> load(const char* path) {
    std::ifstream in(path);
    CHECK(in);
    std::map<std::string, std::vector<uint8_t>> v;
    std::string line;
    while (std::getline(in, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::istringstream fields(line);
        std::string name, hex;
        fields >> name >> hex;
        CHECK(hex.size() % 2 == 0);
        std::vector<uint8_t> bytes;
        for (size_t i = 0; i < hex.size(); i += 2) bytes.push_back(uint8_t(std::stoul(hex.substr(i, 2), nullptr, 16)));
        v[name] = bytes;
    }
    return v;
}
Token token() { Token t; for (int i = 0; i < 16; ++i) t[i] = uint8_t(0x10 + i); return t; }
// The payload of one record, checking its header.
std::vector<uint8_t> payload(const std::vector<uint8_t>& r, uint32_t type) {
    CHECK(r.size() >= 8 && rd32(r.data()) == type && rd32(r.data() + 4) == r.size() - 8);
    return std::vector<uint8_t>(r.begin() + 8, r.end());
}
}

int main(int argc, char** argv) {
    CHECK(argc == 2);
    auto v = load(argv[1]);
    CHECK(rd32(v.at("stream-flags").data()) == kStreamFlags);

    Token t;
    auto hello = payload(v.at("hello"), kHello);
    CHECK(parseHello(hello.data(), hello.size(), &t) && t == token());
    CHECK(!parseHello(hello.data(), hello.size() - 1, &t));

    Open o;
    auto open = payload(v.at("open-h264-1080p"), kOpen);
    CHECK(parseOpen(open.data(), open.size(), &o));
    CHECK(o.stream == 7 && o.codec == kH264 && o.depth == 8 && o.chroma == 1 && o.width == 1920 && o.height == 1088);
    open = payload(v.at("open-av1-10bit"), kOpen);
    CHECK(parseOpen(open.data(), open.size(), &o) && o.codec == kAV1 && o.depth == 10 && o.width == 3840 && o.height == 2160);
    open[7] = 1;
    CHECK(!parseOpen(open.data(), open.size(), &o));

    Unit u;
    auto unit = payload(v.at("unit-key"), kUnit);
    CHECK(parseUnit(unit.data(), unit.size(), &u));
    CHECK(u.stream == 7 && u.seq == 0 && u.surface == 0x03000002 && u.flags == kUnitKey && u.serial == 41);
    CHECK(u.width == 1920 && u.height == 1088 && u.size == 8 && u.data[4] == 0x65);
    unit = payload(v.at("unit-hidden-replay"), kUnit);
    CHECK(parseUnit(unit.data(), unit.size(), &u));
    CHECK(u.flags == (kUnitHidden | kUnitReplay) && u.serial == 0x0102030405060708ull && u.seq == 12 && u.size == 2);
    CHECK(!parseUnit(unit.data(), 31, &u));

    uint32_t word;
    auto close = payload(v.at("close"), kClose);
    CHECK(parseWord(close.data(), close.size(), &word) && word == 7);
    auto gone = payload(v.at("surface-gone"), kSurfaceGone);
    CHECK(parseWord(gone.data(), gone.size(), &word) && word == 0x03000002);

    CHECK(encodeCaps({{kH264, 8, 4096, 2304}, {kHEVC, 10, 8192, 4320}, {kAV1, 10, 8192, 4352}}) == v.at("caps"));
    CHECK(encodeCaps({}) == v.at("caps-empty"));
    CHECK(encodeFail(7, kFailDecode) == v.at("fail-decode"));
    CHECK(encodeReplay(9) == v.at("replay"));

    // Identity records: the layout the guest writes into each surface's last page.
    auto id = v.at("identity-phone-nv12-1080p");
    CHECK(id.size() == 64 && !std::memcmp(id.data(), "CBVAID01", 8) && rd32(id.data() + 12) == 1);
    CHECK(rd64(id.data() + 32) == 41 && rd32(id.data() + 44) == kFourccNV12 && rd16(id.data() + 48) == 1920);
    id = v.at("identity-pixels-p010-720p");
    CHECK(rd32(id.data() + 12) == 2 && rd32(id.data() + 44) == kFourccP010 && rd32(id.data() + 52) == 2560);

    Latch latch;
    auto both = v.at("latch-picture-and-pixels");
    CHECK(parseLatch(both.data(), both.size(), &latch) == 0);
    CHECK(latch.queue == 0x00000b0000000001ull && latch.entries.size() == 2);
    const auto& pic = latch.entries[0];
    CHECK(pic.kind == kPicture && pic.image == 0x00000a0000000011ull && pic.planes == 3 && pic.fourcc == kFourccNV12);
    CHECK(pic.width == 1920 && pic.height == 1080 && pic.token == token() && pic.surface == 0x03000002 && pic.serial == 41);
    const auto& pix = latch.entries[1];
    CHECK(pix.kind == kPixels && pix.width == 4 && pix.height == 2 && pix.pitch == 4 && pix.uvOffset == 8);
    CHECK(pix.pixelBytes == 12 && pix.pixels[0] == 0 && pix.pixels[11] == 0x83);
    for (size_t n = 0; n < both.size(); ++n) CHECK(parseLatch(both.data(), n, &latch) == EPROTO);
    auto corrupt = both;
    corrupt[16] = 0;  // no entries
    CHECK(parseLatch(corrupt.data(), corrupt.size(), &latch) == EPROTO);
    corrupt = both;
    corrupt[24 + 8] = 3;  // unknown kind
    CHECK(parseLatch(corrupt.data(), corrupt.size(), &latch) == EPROTO);
    corrupt = both;
    for (int i = 0; i < 8; ++i) corrupt[24 + 24 + 24 + i] = 0;  // zero serial
    CHECK(parseLatch(corrupt.data(), corrupt.size(), &latch) == EPROTO);
    corrupt = both;
    corrupt[both.size() - 12 - 8] = 13;  // pixel length disagrees with the planes
    CHECK(parseLatch(corrupt.data(), corrupt.size(), &latch) == EPROTO);
    auto luma = v.at("latch-luma-plane");
    CHECK(parseLatch(luma.data(), luma.size(), &latch) == 0 && latch.entries.size() == 1 && latch.entries[0].planes == kPlaneLuma);
    std::printf("media wire: %zu vectors checked\n", v.size());
    return 0;
}
