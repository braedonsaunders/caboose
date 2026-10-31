// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// The phone's decoded pictures, per media connection token and surface (docs/gpu-media.md).
// Executor-wide: a latch in any process stream may name a picture any media stream decoded.
#pragma once
#include "media_wire.h"
#include <chrono>
#include <condition_variable>
#include <map>
#include <memory>
#include <mutex>

namespace caboose::gpuv2::media {
// A decoded picture; the platform decoder subclasses it (a CVPixelBuffer on Apple).
class Picture {
public:
    virtual ~Picture() = default;
};

class Registry {
public:
    static Registry& instance();
    // At most this many surfaces are retained per connection; more are not kept.
    static constexpr size_t kMaxSurfaces = 512;

    void open(const Token& token);
    // Forgets the connection's pictures and wakes its waiters.
    void close(const Token& token);
    void forget(const Token& token, uint32_t surface);
    // The surface now holds `serial`. Older serials are ignored.
    void publish(const Token& token, uint32_t surface, uint64_t serial, std::shared_ptr<Picture> picture);
    // `serial` will not be decoded (an error, or a picture the decoder did not output).
    void failed(const Token& token, uint32_t surface, uint64_t serial);

    enum class Wait { ready, superseded, failed, timeout, gone };
    Wait waitFor(const Token& token, uint32_t surface, uint64_t serial,
                 std::chrono::steady_clock::time_point deadline, std::shared_ptr<Picture>* out);

private:
    struct Surface {
        uint64_t serial = 0, failed = 0;
        std::shared_ptr<Picture> picture;
    };
    std::mutex mutex_;
    std::condition_variable changed_;
    std::map<Token, std::map<uint32_t, Surface>> connections_;
};
}
