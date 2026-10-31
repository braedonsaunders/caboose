// SPDX-License-Identifier: MIT
// Unit tests for caboose-media/media_import.h against the golden vectors of
// docs/gpu-media.md (guest/vaapi/tests/gpu-media-vectors.txt).
//
//   c++ -std=c++17 -I caboose-media caboose-media/media_import_test.cpp -o /tmp/media-import-test
//   /tmp/media-import-test path/to/gpu-media-vectors.txt
#include "media_import.h"

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <map>
#include <sstream>
#include <string>

using namespace caboose::media;

static int failures = 0;
#define CHECK(c)                                                              \
    do {                                                                      \
        if (!(c)) {                                                           \
            std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #c); \
            ++failures;                                                       \
        }                                                                     \
    } while (0)

static std::map<std::string, std::vector<uint8_t>> loadVectors(const char* path) {
    std::map<std::string, std::vector<uint8_t>> out;
    std::ifstream in(path);
    std::string line;
    while (std::getline(in, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::istringstream s(line);
        std::string name, hex;
        s >> name >> hex;
        std::vector<uint8_t> bytes;
        for (size_t i = 0; i + 1 < hex.size(); i += 2)
            bytes.push_back(static_cast<uint8_t>(std::stoul(hex.substr(i, 2), nullptr, 16)));
        out[name] = bytes;
    }
    return out;
}

static const uint8_t kToken[16] = {0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
                                   0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f};

// A fake surface: planes, then the identity page holding `record`.
static std::vector<uint8_t> surface(size_t planeBytes, const std::vector<uint8_t>& record) {
    size_t size = (planeBytes + 4095) / 4096 * 4096 + CB_GM_IDENTITY_PAGE;
    std::vector<uint8_t> m(size, 0);
    std::memcpy(m.data() + size - CB_GM_IDENTITY_PAGE, record.data(), record.size());
    return m;
}

static void testEncoding(const std::map<std::string, std::vector<uint8_t>>& v) {
    Entry pic;
    pic.image = 0x00000a0000000011ull;
    pic.kind = CB_GM_KIND_PICTURE;
    pic.planes = 3;
    pic.fourcc = CB_GM_FOURCC_NV12;
    pic.width = 1920;
    pic.height = 1080;
    std::memcpy(pic.token, kToken, 16);
    pic.surface = 0x03000002;
    pic.serial = 41;
    Entry pix;
    pix.image = 0x00000a0000000012ull;
    pix.kind = CB_GM_KIND_PIXELS;
    pix.planes = 3;
    pix.fourcc = CB_GM_FOURCC_NV12;
    pix.width = 4;
    pix.height = 2;
    pix.pitch = 4;
    pix.uvOffset = 8;
    pix.bytes = {0, 1, 2, 3, 4, 5, 6, 7, 0x80, 0x81, 0x82, 0x83};
    auto packets = encodeLatches(0x00000b0000000001ull, {pic, pix});
    CHECK(packets.size() == 1);
    CHECK(packets[0] == v.at("latch-picture-and-pixels"));

    Entry luma = pic;
    luma.image = 0x00000a0000000013ull;
    luma.planes = CB_GM_PLANE_LUMA;
    packets = encodeLatches(0x00000b0000000001ull, {luma});
    CHECK(packets.size() == 1 && packets[0] == v.at("latch-luma-plane"));
}

static void testSplitting() {
    std::vector<Entry> many(130);
    for (size_t i = 0; i < many.size(); ++i) {
        many[i].kind = CB_GM_KIND_PICTURE;
        many[i].image = i + 1;
    }
    auto packets = encodeLatches(7, many);
    CHECK(packets.size() == 3);
    CHECK(cb_gm_rd32(packets[0].data() + 16) == 64);
    CHECK(cb_gm_rd32(packets[1].data() + 16) == 64);
    CHECK(cb_gm_rd32(packets[2].data() + 16) == 2);
    for (auto& p : packets) CHECK(cb_gm_rd32(p.data() + 4) == p.size());
    // Entries of the last packet are the last two images, in order.
    CHECK(cb_gm_rd64(packets[2].data() + CB_GM_LATCH_HEAD) == 129);

    // A byte budget splits early; an oversized entry travels alone.
    Entry big;
    big.kind = CB_GM_KIND_PIXELS;
    big.bytes.resize(1000);
    packets = encodeLatches(7, {big, big, big}, CB_GM_LATCH_HEAD + 2 * encodedSize(big));
    CHECK(packets.size() == 2);
    CHECK(cb_gm_rd32(packets[0].data() + 16) == 2 && cb_gm_rd32(packets[1].data() + 16) == 1);
    packets = encodeLatches(7, {big, big}, 500);
    CHECK(packets.size() == 2);
    CHECK(encodeLatches(7, {}).empty());
}

static void testIdentityAndPlanes(const std::map<std::string, std::vector<uint8_t>>& v) {
    // The 1080p NV12 vector: pitch 2048, chroma at 2048*1088.
    const size_t uv = 2048u * 1088u, planeBytes = uv + 2048u * 544u;
    auto map = surface(planeBytes, v.at("identity-phone-nv12-1080p"));
    cb_gm_identity id;
    CHECK(cb_gm_identity_read(cb_gm_identity_at(map.data(), map.size()), map.size(), &id));
    CHECK(id.state == CB_GM_PHONE && id.serial == 41 && id.surface == 0x03000002 && id.width == 1920 &&
          id.height == 1080 && id.pitch == 2048 && id.uv_offset == uv);
    CHECK(!std::memcmp(id.token, kToken, 16));

    ImageDesc nv12{PlaneFormat::twoPlane8, 1920, 1080, 2, {0, uv}, {2048, 2048}};
    ImageDesc y{PlaneFormat::luma8, 1920, 1080, 1, {0, 0}, {2048, 0}};
    ImageDesc uvImg{PlaneFormat::chroma8, 960, 540, 1, {uv, 0}, {2048, 0}};
    CHECK(planesForIdentity(nv12, id) == 3);
    CHECK(planesForIdentity(y, id) == CB_GM_PLANE_LUMA);
    CHECK(planesForIdentity(uvImg, id) == CB_GM_PLANE_CHROMA);
    ImageDesc wrongPitch = nv12;
    wrongPitch.pitch[1] = 1920;
    CHECK(planesForIdentity(wrongPitch, id) == 0);
    ImageDesc tenBit = nv12;
    tenBit.format = PlaneFormat::twoPlane16;
    CHECK(planesForIdentity(tenBit, id) == 0);
    ImageDesc chromaAtZero = uvImg;
    chromaAtZero.offset[0] = 0;
    CHECK(planesForIdentity(chromaAtZero, id) == 0);
    ImageDesc tooBig = y;
    tooBig.height = 1088;
    CHECK(planesForIdentity(tooBig, id) == 0);

    // Picture latch, then nothing until the serial changes.
    LatchState s;
    Entry e;
    CHECK(evaluate(5, nv12, map.data(), map.size(), &s, &e) == Decision::latch);
    CHECK(e.kind == CB_GM_KIND_PICTURE && e.serial == 41 && e.planes == 3 && e.surface == 0x03000002);
    CHECK(evaluate(5, nv12, map.data(), map.size(), &s, &e) == Decision::none);
    cb_gm_identity next = id;
    next.serial = 42;
    cb_gm_identity_write(cb_gm_identity_at(map.data(), map.size()), &next);
    CHECK(evaluate(5, nv12, map.data(), map.size(), &s, &e) == Decision::latch && e.serial == 42);

    // Empty: nothing to latch, but the change is remembered.
    next.state = CB_GM_EMPTY;
    next.serial = 0;
    cb_gm_identity_write(cb_gm_identity_at(map.data(), map.size()), &next);
    CHECK(evaluate(5, nv12, map.data(), map.size(), &s, &e) == Decision::none);
    CHECK(s.state == CB_GM_EMPTY);

    // Pixels: the chroma image carries only the chroma rows, at offset 0.
    next.state = CB_GM_PIXELS;
    next.serial = 43;
    cb_gm_identity_write(cb_gm_identity_at(map.data(), map.size()), &next);
    map[uv] = 0x5a;
    map[uv + 2048u * 539u + 1] = 0xa5;
    LatchState sc;
    CHECK(evaluate(6, uvImg, map.data(), map.size(), &sc, &e) == Decision::latch);
    CHECK(e.kind == CB_GM_KIND_PIXELS && e.planes == CB_GM_PLANE_CHROMA && e.uvOffset == 0 &&
          e.bytes.size() == 2048u * 540u && e.bytes[0] == 0x5a && e.bytes[2048u * 539u + 1] == 0xa5);
    // The whole surface: luma rows then chroma rows.
    LatchState sb;
    CHECK(evaluate(5, nv12, map.data(), map.size(), &sb, &e) == Decision::latch);
    CHECK(e.bytes.size() == 2048u * 1620u && e.uvOffset == 2048u * 1080u);
    CHECK(e.bytes[2048u * 1080u] == 0x5a);

    // A layout that contradicts the identity is a mismatch, not latched.
    LatchState sm;
    CHECK(evaluate(5, wrongPitch, map.data(), map.size(), &sm, &e) == Decision::mismatch);
    CHECK(evaluate(5, wrongPitch, map.data(), map.size(), &sm, &e) == Decision::none);

    // The P010 vector reads as pixels.
    const size_t uv10 = 2560u * 736u;
    auto map10 = surface(uv10 + 2560u * 368u, v.at("identity-pixels-p010-720p"));
    CHECK(cb_gm_identity_read(cb_gm_identity_at(map10.data(), map10.size()), map10.size(), &id));
    CHECK(id.state == CB_GM_PIXELS && id.fourcc == CB_GM_FOURCC_P010 && id.serial == 42);
    ImageDesc p010{PlaneFormat::twoPlane16, 1280, 720, 2, {0, uv10}, {2560, 2560}};
    CHECK(planesForIdentity(p010, id) == 3);

    // A record mid-update (odd sequence) is not trusted.
    auto odd = v.at("identity-phone-nv12-1080p");
    odd[8] |= 1;
    auto mapOdd = surface(planeBytes, odd);
    CHECK(!cb_gm_identity_read(cb_gm_identity_at(mapOdd.data(), mapOdd.size()), mapOdd.size(), &id));
    // A record whose planes would not fit the buffer is rejected.
    auto tiny = surface(4096, v.at("identity-phone-nv12-1080p"));
    CHECK(!cb_gm_identity_read(cb_gm_identity_at(tiny.data(), tiny.size()), tiny.size(), &id));
}

static void testForeign() {
    // 4x2 NV12 with no identity: pixels on first sight, then only when they change.
    std::vector<uint8_t> map(8192, 0);
    for (int i = 0; i < 8; ++i) map[i] = static_cast<uint8_t>(i);
    map[64] = 0x80;
    ImageDesc d{PlaneFormat::twoPlane8, 4, 2, 2, {0, 64}, {4, 4}};
    LatchState s;
    Entry e;
    CHECK(evaluate(9, d, map.data(), map.size(), &s, &e) == Decision::latch);
    CHECK(e.kind == CB_GM_KIND_PIXELS && e.fourcc == CB_GM_FOURCC_NV12 && e.pitch == 4 && e.uvOffset == 8 &&
          e.bytes.size() == 12 && e.bytes[8] == 0x80 && e.bytes[7] == 7);
    CHECK(evaluate(9, d, map.data(), map.size(), &s, &e) == Decision::none);
    map[65] = 1;
    CHECK(evaluate(9, d, map.data(), map.size(), &s, &e) == Decision::latch && e.bytes[9] == 1);
    // A chroma-only foreign image implies a picture twice its size.
    ImageDesc c{PlaneFormat::chroma8, 2, 1, 1, {64, 0}, {4, 0}};
    LatchState sc;
    CHECK(evaluate(10, c, map.data(), map.size(), &sc, &e) == Decision::latch);
    CHECK(e.width == 4 && e.height == 2 && e.planes == CB_GM_PLANE_CHROMA && e.bytes.size() == 4);
    // Planes outside the mapping are a mismatch.
    ImageDesc outside{PlaneFormat::luma8, 4, 2, 1, {8190, 0}, {4, 0}};
    LatchState so;
    CHECK(evaluate(11, outside, map.data(), map.size(), &so, &e) == Decision::mismatch);
    // Unequal plane pitches cannot be described by one pitch.
    ImageDesc pitches{PlaneFormat::twoPlane8, 4, 2, 2, {0, 64}, {4, 8}};
    LatchState sp;
    CHECK(evaluate(12, pitches, map.data(), map.size(), &sp, &e) == Decision::mismatch);
}

int main(int argc, char** argv) {
    if (argc != 2) {
        std::fprintf(stderr, "usage: %s gpu-media-vectors.txt\n", argv[0]);
        return 2;
    }
    auto v = loadVectors(argv[1]);
    if (v.empty()) {
        std::fprintf(stderr, "no vectors in %s\n", argv[1]);
        return 2;
    }
    testEncoding(v);
    testSplitting();
    testIdentityAndPlanes(v);
    testForeign();
    if (failures) {
        std::fprintf(stderr, "%d failures\n", failures);
        return 1;
    }
    std::printf("media_import: all tests passed\n");
    return 0;
}
