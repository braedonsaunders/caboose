// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// Hardware decoding of media streams with VideoToolbox (docs/gpu-media.md).
#include "media_apple.h"
#include "media_bitstream.h"
#include <CoreMedia/CoreMedia.h>
#include <VideoToolbox/VideoToolbox.h>
#include <mutex>

namespace caboose::gpuv2::media {
CFDictionaryRef pictureAttributes() {
    const OSType formats[] = {kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                              kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange};
    CFNumberRef numbers[4];
    for (int i = 0; i < 4; ++i) numbers[i] = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &formats[i]);
    CFArrayRef list = CFArrayCreate(kCFAllocatorDefault, (const void**)numbers, 4, &kCFTypeArrayCallBacks);
    CFDictionaryRef surface = CFDictionaryCreate(kCFAllocatorDefault, nullptr, nullptr, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const void* keys[] = {kCVPixelBufferMetalCompatibilityKey, kCVPixelBufferIOSurfacePropertiesKey,
                          kCVPixelBufferPixelFormatTypeKey};
    const void* values[] = {kCFBooleanTrue, surface, list};
    CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 3,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(surface); CFRelease(list);
    for (auto* n : numbers) CFRelease(n);
    return attributes;
}

namespace {
CFDataRef data(const Bytes& b) { return CFDataCreate(kCFAllocatorDefault, b.data(), CFIndex(b.size())); }

// A format description carrying one sample-description extension atom.
CMVideoFormatDescriptionRef atomFormat(CMVideoCodecType codec, uint32_t width, uint32_t height,
                                       const char* atom, const Bytes& record, bool fullRange) {
    CFStringRef key = CFStringCreateWithCString(kCFAllocatorDefault, atom, kCFStringEncodingASCII);
    CFDataRef value = data(record);
    CFDictionaryRef atoms = CFDictionaryCreate(kCFAllocatorDefault, (const void**)&key, (const void**)&value, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const void* keys[] = {kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms,
                          kCMFormatDescriptionExtension_FullRangeVideo};
    const void* values[] = {atoms, fullRange ? kCFBooleanTrue : kCFBooleanFalse};
    CFDictionaryRef extensions = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CMVideoFormatDescriptionRef format = nullptr;
    if (CMVideoFormatDescriptionCreate(kCFAllocatorDefault, codec, int32_t(width), int32_t(height),
                                       extensions, &format) != noErr) format = nullptr;
    CFRelease(extensions); CFRelease(atoms); CFRelease(value); CFRelease(key);
    return format;
}

class VideoToolboxDecoder final : public Decoder {
public:
    VideoToolboxDecoder(const Open& open, DecoderSink& sink)
        : open_(open), sink_(sink), nal_(open.codec == kHEVC) {}
    ~VideoToolboxDecoder() override {
        dropSession();
        if (format_) CFRelease(format_);
    }

    bool decode(const Unit& unit) override {
        const uint8_t* bytes = unit.data;
        size_t size = unit.size;
        Bytes sample;
        bool changed = false;
        switch (open_.codec) {
        case kH264:
        case kHEVC: {
            NalFormatter::Sample s;
            if (!nal_.sample(unit.data, unit.size, &s)) return false;
            if (s.parametersChanged && !nalFormat()) return false;
            changed = s.parametersChanged;
            sample = std::move(s.avcc);
            break;
        }
        case kAV1: {
            OBUFormatter::Sample s;
            if (!obu_.sample(unit.data, unit.size, &s)) return false;
            if (s.formatChanged) {
                const auto& h = *obu_.sequence();
                if (!replaceFormat(atomFormat(kCMVideoCodecType_AV1, h.maxWidth, h.maxHeight, "av1C",
                                              h.configurationRecord(obu_.sequenceHeaderObu()), h.fullRange)))
                    return false;
                changed = true;
            }
            sample = std::move(s.data);
            break;
        }
        case kVP9: {
            if (auto key = VP9KeyFrame::parse(unit.data, unit.size)) {
                Bytes record = key->configurationRecord();
                if (!format_ || record != vp9Record_ || key->width != vp9Width_ || key->height != vp9Height_) {
                    if (!replaceFormat(atomFormat(kCMVideoCodecType_VP9, key->width, key->height, "vpcC",
                                                  record, key->fullRange))) return false;
                    vp9Record_ = record; vp9Width_ = key->width; vp9Height_ = key->height;
                    changed = true;
                }
            }
            sample.assign(bytes, bytes + size);
            break;
        }
        default: return false;
        }
        if (!format_ || sample.empty()) return false;
        if (changed && session_ && !VTDecompressionSessionCanAcceptFormatDescription(session_, format_))
            dropSession();
        if (!session_ && !makeSession()) return false;
        CMSampleBufferRef buffer = sampleBuffer(sample);
        if (!buffer) return false;
        DecoderSink& sink = sink_;
        const uint32_t surface = unit.surface;
        const uint64_t serial = unit.serial;
        const OSStatus status = VTDecompressionSessionDecodeFrameWithOutputHandler(session_, buffer,
            kVTDecodeFrame_EnableAsynchronousDecompression, nullptr,
            ^(OSStatus result, VTDecodeInfoFlags info, CVImageBufferRef image, CMTime, CMTime) {
                if (result != noErr) { sink.failed(surface, serial); return; }
                if (!image || (info & kVTDecodeInfo_FrameDropped)) { sink.dropped(surface, serial); return; }
                if (!biPlanarBytesPerSample(CVPixelBufferGetPixelFormatType(image))) {
                    sink.failed(surface, serial);
                    return;
                }
                sink.decoded(surface, serial, std::make_shared<PixelBufferPicture>(image));
            });
        CFRelease(buffer);
        if (status != noErr) {
            if (status == kVTInvalidSessionErr) dropSession();
            return false;
        }
        return true;
    }

private:
    bool replaceFormat(CMVideoFormatDescriptionRef format) {
        if (!format) return false;
        if (format_) CFRelease(format_);
        format_ = format;
        return true;
    }
    bool nalFormat() {
        auto sets = nal_.parameterSets();
        if (sets.empty()) return true;  // the rest arrive with the next unit
        std::vector<const uint8_t*> pointers;
        std::vector<size_t> sizes;
        for (auto& s : sets) { pointers.push_back(s.data()); sizes.push_back(s.size()); }
        CMFormatDescriptionRef format = nullptr;
        const OSStatus status = open_.codec == kH264
            ? CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, sets.size(),
                  pointers.data(), sizes.data(), 4, &format)
            : CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault, sets.size(),
                  pointers.data(), sizes.data(), 4, nullptr, &format);
        return status == noErr && replaceFormat(format);
    }
    bool makeSession() {
        const void* specKeys[] = {kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder};
        const void* specValues[] = {kCFBooleanTrue};
        CFDictionaryRef spec = CFDictionaryCreate(kCFAllocatorDefault, specKeys, specValues, 1,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFDictionaryRef attributes = pictureAttributes();
        VTDecompressionSessionRef session = nullptr;
        const OSStatus status = VTDecompressionSessionCreate(kCFAllocatorDefault, format_, spec, attributes,
                                                             nullptr, &session);
        CFRelease(attributes); CFRelease(spec);
        if (status != noErr || !session) return false;
        VTSessionSetProperty(session, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
        session_ = session;
        return true;
    }
    void dropSession() {
        if (!session_) return;
        VTDecompressionSessionWaitForAsynchronousFrames(session_);
        VTDecompressionSessionInvalidate(session_);
        CFRelease(session_);
        session_ = nullptr;
    }
    CMSampleBufferRef sampleBuffer(const Bytes& bytes) {
        CMBlockBufferRef block = nullptr;
        if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, bytes.size(), kCFAllocatorDefault,
                nullptr, 0, bytes.size(), kCMBlockBufferAssureMemoryNowFlag, &block) != noErr) return nullptr;
        CMSampleBufferRef sample = nullptr;
        const size_t size = bytes.size();
        if (CMBlockBufferReplaceDataBytes(bytes.data(), block, 0, size) != noErr ||
            CMSampleBufferCreateReady(kCFAllocatorDefault, block, format_, 1, 0, nullptr, 1, &size, &sample) != noErr)
            sample = nullptr;
        CFRelease(block);
        return sample;
    }

    Open open_;
    DecoderSink& sink_;
    NalFormatter nal_;
    OBUFormatter obu_;
    Bytes vp9Record_;
    uint32_t vp9Width_ = 0, vp9Height_ = 0;
    CMVideoFormatDescriptionRef format_ = nullptr;
    VTDecompressionSessionRef session_ = nullptr;
};

class VideoToolboxFactory final : public DecoderFactory {
public:
    std::vector<Capability> capabilities() override {
        std::call_once(probed_, [this] {
            if (VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)) caps_.push_back({kH264, 8, 4096, 2304});
            if (VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) caps_.push_back({kHEVC, 10, 8192, 4320});
#if TARGET_OS_OSX
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9);
#endif
            if (VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9)) caps_.push_back({kVP9, 10, 8192, 4352});
            if (VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)) caps_.push_back({kAV1, 10, 8192, 4352});
        });
        return caps_;
    }
    std::unique_ptr<Decoder> create(const Open& open, DecoderSink& sink) override {
        return std::make_unique<VideoToolboxDecoder>(open, sink);
    }
private:
    std::once_flag probed_;
    std::vector<Capability> caps_;
};
}

DecoderFactory& platformDecoders() {
    static VideoToolboxFactory* factory = new VideoToolboxFactory;
    return *factory;
}
}
