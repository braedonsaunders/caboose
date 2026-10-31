// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// Apple platform pieces of docs/gpu-media.md: VideoToolbox pictures.
#pragma once
#include "media_session.h"
#include <CoreVideo/CoreVideo.h>

namespace caboose::gpuv2::media {
// A VideoToolbox output: IOSurface-backed, Metal-compatible, in the decoder's own 4:2:0
// bi-planar format (420v, 420f, x420 or xf20), so its samples are the coded values.
class PixelBufferPicture final : public Picture {
public:
    explicit PixelBufferPicture(CVPixelBufferRef buffer) : buffer_(CVPixelBufferRetain(buffer)) {}
    ~PixelBufferPicture() override { CVPixelBufferRelease(buffer_); }
    PixelBufferPicture(const PixelBufferPicture&) = delete;
    PixelBufferPicture& operator=(const PixelBufferPicture&) = delete;
    CVPixelBufferRef buffer() const { return buffer_; }
private:
    CVPixelBufferRef buffer_;
};

// The destination attributes of every VideoToolbox session: IOSurface-backed and Metal
// compatible, in one of the bi-planar 4:2:0 formats. Without a format list VideoToolbox may
// output a compressed private format; with this one it picks the format that matches the
// stream (range and depth) and does not convert the samples. Caller releases.
CFDictionaryRef pictureAttributes();

// Bytes per sample of a bi-planar 4:2:0 pixel buffer format VideoToolbox outputs: 1 or 2,
// or 0 for any other format.
inline unsigned biPlanarBytesPerSample(OSType format) {
    switch (format) {
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return 1;
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
    case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: return 2;
    default: return 0;
    }
}
}
