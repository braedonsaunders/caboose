// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// Real VideoToolbox fixture: streams encoded here (H.264 with B-frames in video and full
// range, HEVC Main 10) are sent as the guest driver sends them, Annex-B with parameter sets
// at key frames, through runMediaSession and the platform decoders. Every serial must reach
// the registry while a latch would wait for it, in the stream's own format, with luma within
// a PSNR bound of the source frame. With the directory tests/media_fixtures.sh writes as
// argv[1], AV1 and VP9 streams are checked the same way against FFmpeg's decode of them.
#include "media_apple.h"
#include <VideoToolbox/VideoToolbox.h>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <string>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>
#include <vector>

using namespace caboose::gpuv2::media;
#define CHECK(c) do { if (!(c)) { std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c); std::exit(1); } } while (0)

namespace {
constexpr int kWidth = 640, kHeight = 360, kFrames = 30;

CVPixelBufferRef frame(OSType format, int index) {
    NSDictionary* attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
    CVPixelBufferRef pb = nullptr;
    CHECK(CVPixelBufferCreate(kCFAllocatorDefault, kWidth, kHeight, format, (__bridge CFDictionaryRef)attributes, &pb) == kCVReturnSuccess);
    const bool wide = biPlanarBytesPerSample(format) == 2;
    CVPixelBufferLockBaseAddress(pb, 0);
    for (size_t plane = 0; plane < 2; ++plane) {
        auto* base = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pb, plane));
        const size_t stride = CVPixelBufferGetBytesPerRowOfPlane(pb, plane);
        const size_t w = CVPixelBufferGetWidthOfPlane(pb, plane) * (plane ? 2 : 1), h = CVPixelBufferGetHeightOfPlane(pb, plane);
        for (size_t y = 0; y < h; ++y)
            for (size_t x = 0; x < w; ++x) {
                unsigned v = plane ? 128 + int((x % 2 ? 40 : -40) * std::sin((y + index) * 0.05))
                                   : 40 + (x + y + 3 * index) % 160;
                const int sx = 100 + 8 * index, sy = 80;
                if (!plane && int(x) >= sx && int(x) < sx + 120 && int(y) >= sy && int(y) < sy + 120) v = 230;
                if (wide) reinterpret_cast<uint16_t*>(base + y * stride)[x] = uint16_t(v << 8);
                else base[y * stride + x] = uint8_t(v);
            }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

struct Encoded { std::vector<uint8_t> annexB; bool key; int64_t pts; };

// Encodes kFrames frames, returning units in decode order as the guest driver sends them.
std::vector<Encoded> encode(CMVideoCodecType codec, OSType format, CFStringRef profile, bool reorder) {
    __block std::vector<Encoded> units;
    VTCompressionSessionRef session = nullptr;
    CHECK(VTCompressionSessionCreate(kCFAllocatorDefault, kWidth, kHeight, codec, nullptr, nullptr, nullptr,
                                     nullptr, nullptr, &session) == noErr);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_ProfileLevel, profile);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_AllowFrameReordering, reorder ? kCFBooleanTrue : kCFBooleanFalse);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFNumberRef)@10);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFNumberRef)@4000000);
    for (int i = 0; i < kFrames; ++i) {
        CVPixelBufferRef pb = frame(format, i);
        CHECK(VTCompressionSessionEncodeFrameWithOutputHandler(session, pb, CMTimeMake(i, 30), kCMTimeInvalid, nullptr,
            nullptr, ^(OSStatus status, VTEncodeInfoFlags, CMSampleBufferRef sample) {
                CHECK(status == noErr && sample);
                CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
                bool key = true;
                if (attachments && CFArrayGetCount(attachments)) {
                    auto dict = (CFDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
                    key = !CFDictionaryContainsKey(dict, kCMSampleAttachmentKey_NotSync);
                }
                Encoded e{{}, key, CMSampleBufferGetPresentationTimeStamp(sample).value};
                const uint8_t start[] = {0, 0, 0, 1};
                CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
                if (key) {
                    size_t count = 0;
                    for (size_t k = 0;; ++k) {
                        const uint8_t* set; size_t size; int header;
                        OSStatus r = codec == kCMVideoCodecType_H264
                            ? CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, k, &set, &size, &count, &header)
                            : CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, k, &set, &size, &count, &header);
                        if (r != noErr || k >= count) break;
                        e.annexB.insert(e.annexB.end(), start, start + 4);
                        e.annexB.insert(e.annexB.end(), set, set + size);
                    }
                }
                CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
                size_t length = 0; char* bytes = nullptr;
                CHECK(CMBlockBufferGetDataPointer(block, 0, nullptr, &length, &bytes) == kCMBlockBufferNoErr);
                for (size_t at = 0; at + 4 <= length;) {
                    const auto* p = reinterpret_cast<const uint8_t*>(bytes + at);
                    const size_t n = size_t(p[0]) << 24 | size_t(p[1]) << 16 | size_t(p[2]) << 8 | p[3];
                    e.annexB.insert(e.annexB.end(), start, start + 4);
                    e.annexB.insert(e.annexB.end(), p + 4, p + 4 + n);
                    at += 4 + n;
                }
                units.push_back(std::move(e));
            }) == noErr);
        CVPixelBufferRelease(pb);
    }
    VTCompressionSessionCompleteFrames(session, kCMTimeInvalid);
    VTCompressionSessionInvalidate(session);
    CFRelease(session);
    CHECK(units.size() == kFrames);
    return units;
}

double lumaPsnr(CVPixelBufferRef a, CVPixelBufferRef b) {
    CVPixelBufferLockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    const unsigned bps = biPlanarBytesPerSample(CVPixelBufferGetPixelFormatType(a));
    double error = 0;
    for (int y = 0; y < kHeight; ++y) {
        auto* ra = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(a, 0)) + y * CVPixelBufferGetBytesPerRowOfPlane(a, 0);
        auto* rb = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(b, 0)) + y * CVPixelBufferGetBytesPerRowOfPlane(b, 0);
        for (int x = 0; x < kWidth; ++x) {
            const double va = bps == 2 ? reinterpret_cast<const uint16_t*>(ra)[x] / 256.0 : ra[x];
            const double vb = bps == 2 ? reinterpret_cast<const uint16_t*>(rb)[x] / 256.0 : rb[x];
            error += (va - vb) * (va - vb);
        }
    }
    CVPixelBufferUnlockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    const double mse = error / (kWidth * kHeight);
    return mse == 0 ? 99 : 10 * std::log10(255.0 * 255.0 / mse);
}

void send(int fd, uint32_t type, const std::vector<uint8_t>& payload) {
    auto r = record(type, payload);
    CHECK(::send(fd, r.data(), r.size(), 0) == ssize_t(r.size()));
}

// Luma PSNR of a decoded picture against a reference frame in a raw nv12/p010le file.
double lumaPsnr(CVPixelBufferRef a, const std::vector<uint8_t>& raw, size_t index, unsigned bps, int w, int h) {
    const size_t frameBytes = size_t(w) * h * 3 / 2 * bps;
    CHECK(raw.size() >= (index + 1) * frameBytes);
    const uint8_t* ref = raw.data() + index * frameBytes;
    CVPixelBufferLockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    double error = 0;
    for (int y = 0; y < h; ++y) {
        auto* ra = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(a, 0)) + y * CVPixelBufferGetBytesPerRowOfPlane(a, 0);
        for (int x = 0; x < w; ++x) {
            const double va = bps == 2 ? (reinterpret_cast<const uint16_t*>(ra)[x] >> 6) / 4.0 : ra[x];
            const double vb = bps == 2 ? (reinterpret_cast<const uint16_t*>(ref + size_t(y) * w * 2)[x] >> 6) / 4.0 : ref[size_t(y) * w + x];
            error += (va - vb) * (va - vb);
        }
    }
    CVPixelBufferUnlockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    const double mse = error / (double(w) * h);
    return mse == 0 ? 99 : 10 * std::log10(255.0 * 255.0 / mse);
}

std::vector<uint8_t> readFile(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    return std::vector<uint8_t>(std::istreambuf_iterator<char>(in), {});
}

// A low-overhead OBU stream split at its temporal delimiters.
std::vector<Encoded> temporalUnits(const std::vector<uint8_t>& obus) {
    std::vector<Encoded> units;
    size_t at = 0;
    while (at < obus.size()) {
        const size_t begin = at;
        const uint8_t header = obus[at];
        const unsigned type = (header >> 3) & 15;
        at += (header & 4) ? 2 : 1;
        uint64_t size = 0;
        for (unsigned shift = 0;; shift += 7) {
            const uint8_t b = obus[at++];
            size |= uint64_t(b & 0x7f) << shift;
            if (!(b & 0x80)) break;
        }
        at += size_t(size);
        if (type == 2) units.push_back({{}, false, int64_t(units.size())});
        CHECK(!units.empty());
        units.back().annexB.insert(units.back().annexB.end(), obus.begin() + begin, obus.begin() + at);
        if (type == 1) units.back().key = true;
    }
    return units;
}

// IVF frames.
std::vector<Encoded> ivfFrames(const std::vector<uint8_t>& ivf) {
    std::vector<Encoded> units;
    CHECK(ivf.size() >= 32 && !std::memcmp(ivf.data(), "DKIF", 4));
    for (size_t at = 32; at + 12 <= ivf.size();) {
        const size_t size = rd32(ivf.data() + at);
        at += 12;
        Encoded e{std::vector<uint8_t>(ivf.begin() + at, ivf.begin() + at + size), false, int64_t(units.size())};
        e.key = (e.annexB[0] & 0x04) == 0;  // frame_type 0 in profiles 0-2 without show_existing
        units.push_back(std::move(e));
        at += size;
    }
    return units;
}

void run(const char* name, uint8_t wireCodec, uint8_t depth, OSType format, const std::vector<Encoded>& units,
         const std::vector<uint8_t>* reference) {
    int fds[2];
    CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0);
    std::atomic_bool stop{false};
    int result = -1;
    std::thread phone([&] { result = runMediaSession(fds[1], stop, platformDecoders()); });
    Token token;
    for (int i = 0; i < 16; ++i) token[i] = uint8_t(0xA0 + i + wireCodec);
    std::vector<uint8_t> hello; put32(hello, kVersion); hello.insert(hello.end(), token.begin(), token.end());
    send(fds[0], kHello, hello);
    uint8_t head[8];
    CHECK(recv(fds[0], head, 8, MSG_WAITALL) == 8 && rd32(head) == kCaps);
    std::vector<uint8_t> caps(rd32(head + 4));
    CHECK(recv(fds[0], caps.data(), caps.size(), MSG_WAITALL) == ssize_t(caps.size()));
    bool advertised = false;
    for (uint32_t i = 0; i < rd32(caps.data() + 4); ++i) advertised |= caps[8 + 8 * i] == wireCodec;
    CHECK(advertised);
    std::vector<uint8_t> open; put32(open, 1); open.push_back(wireCodec); open.push_back(depth); open.push_back(1); open.push_back(0);
    put16(open, kWidth); put16(open, kHeight);
    send(fds[0], kOpen, open);
    double worst = 99;
    for (size_t k = 0; k < units.size(); ++k) {
        const uint32_t surface = uint32_t(k % 6);
        const uint64_t serial = 1000 + k;
        std::vector<uint8_t> u; put32(u, 1); put32(u, uint32_t(k)); put32(u, surface); put32(u, units[k].key ? kUnitKey : 0);
        put32(u, uint32_t(serial)); put32(u, 0); put16(u, kWidth); put16(u, kHeight); put32(u, 0);
        u.insert(u.end(), units[k].annexB.begin(), units[k].annexB.end());
        send(fds[0], kUnit, u);
        std::shared_ptr<caboose::gpuv2::media::Picture> picture;
        const auto r = Registry::instance().waitFor(token, surface, serial,
                                                    std::chrono::steady_clock::now() + std::chrono::seconds(2), &picture);
        CHECK(r == Registry::Wait::ready);
        CVPixelBufferRef decoded = static_cast<PixelBufferPicture&>(*picture).buffer();
        CHECK(CVPixelBufferGetPixelFormatType(decoded) == format);  // the stream's format, unconverted
        CHECK(CVPixelBufferGetWidth(decoded) == kWidth && CVPixelBufferGetHeight(decoded) == kHeight);
        double psnr;
        if (reference) {
            psnr = lumaPsnr(decoded, *reference, size_t(units[k].pts), depth > 8 ? 2 : 1, kWidth, kHeight);
            CHECK(psnr > 45);  // two decoders of one bitstream
        } else {
            CVPixelBufferRef source = frame(format, int(units[k].pts));
            psnr = lumaPsnr(decoded, source);
            CVPixelBufferRelease(source);
            CHECK(psnr > 30);  // against the encoder's source
        }
        worst = std::min(worst, psnr);
    }
    shutdown(fds[0], SHUT_WR);
    phone.join();
    CHECK(result == 0);
    close(fds[0]); close(fds[1]);
    std::printf("ok %s: %zu pictures, worst luma PSNR %.1f dB\n", name, units.size(), worst);
}
}

int main(int argc, char** argv) {
    @autoreleasepool {
        const OSType v8 = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, v10 = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
        run("H.264 High, B-frames, video range", kH264, 8, v8,
            encode(kCMVideoCodecType_H264, v8, kVTProfileLevel_H264_High_AutoLevel, true), nullptr);
        run("H.264 Main, full range", kH264, 8, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            encode(kCMVideoCodecType_H264, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kVTProfileLevel_H264_Main_AutoLevel, false), nullptr);
        run("HEVC Main 10", kHEVC, 10, v10, encode(kCMVideoCodecType_HEVC, v10, kVTProfileLevel_HEVC_Main10_AutoLevel, true), nullptr);
        if (argc > 1) {
            const std::string dir = argv[1];
            struct { const char* name; const char* file; uint8_t codec, depth; OSType format; } cases[] = {
                {"AV1 8-bit", "av1-8bit", kAV1, 8, v8}, {"AV1 10-bit", "av1-10bit", kAV1, 10, v10},
                {"VP9 profile 0, alt-ref", "vp9-profile0", kVP9, 8, v8}, {"VP9 profile 2, alt-ref", "vp9-profile2", kVP9, 10, v10}};
            for (auto& c : cases) {
                const bool av1 = c.codec == kAV1;
                if (!VTIsHardwareDecodeSupported(av1 ? kCMVideoCodecType_AV1 : kCMVideoCodecType_VP9)) {
                    std::printf("skip %s: no hardware decoder\n", c.name);
                    continue;
                }
                const auto stream = readFile(dir + "/" + c.file + (av1 ? ".obu" : ".ivf"));
                const auto reference = readFile(dir + "/" + c.file + ".yuv");
                run(c.name, c.codec, c.depth, c.format, av1 ? temporalUnits(stream) : ivfFrames(stream), &reference);
            }
        }
        std::printf("media videotoolbox: all checks passed\n");
    }
    return 0;
}
