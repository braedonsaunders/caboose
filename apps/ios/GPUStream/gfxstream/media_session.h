// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// One media connection (docs/gpu-media.md, "Media stream"): the records after the CBVM
// flags word, decoded through a platform decoder into the executor-wide Registry.
#pragma once
#include "media_registry.h"
#include <atomic>
#include <memory>
#include <vector>

namespace caboose::gpuv2::media {
// Where a decoder reports each unit's outcome. Called from any thread, until the
// decoder's destructor returns.
class DecoderSink {
public:
    virtual ~DecoderSink() = default;
    virtual void decoded(uint32_t surface, uint64_t serial, std::shared_ptr<Picture> picture) = 0;
    // The decoder produced no picture without an error (a frame it never outputs).
    virtual void dropped(uint32_t surface, uint64_t serial) = 0;
    virtual void failed(uint32_t surface, uint64_t serial) = 0;
};

class Decoder {
public:
    // Returns once no sink call is in progress or will follow.
    virtual ~Decoder() = default;
    // Queues one unit in decode order. False when it fails at once; the sink is not called then.
    virtual bool decode(const Unit& unit) = 0;
};

class DecoderFactory {
public:
    virtual ~DecoderFactory() = default;
    // The formats decoded in hardware, as CAPS reports them.
    virtual std::vector<Capability> capabilities() = 0;
    // Null when this stream cannot be decoded after all.
    virtual std::unique_ptr<Decoder> create(const Open& open, DecoderSink& sink) = 0;
};

// The failure policy: FAIL 2 after this many failed pictures within the window; one
// REPLAY per failure otherwise, until the replayed key frame arrives.
constexpr unsigned kFailuresBeforeFail = 3;
constexpr std::chrono::seconds kFailureWindow{10};
constexpr size_t kMaxStreams = 64;

// Runs the connection on `fd` after its flags word. The caller retains fd and interrupts
// blocking reads with shutdown. Returns 0 at a clean end of stream or a requested stop,
// otherwise an errno value (EPROTO for a malformed stream).
int runMediaSession(int fd, std::atomic_bool& stop, DecoderFactory& factory);

// The platform's hardware decoders (VideoToolbox on Apple platforms).
DecoderFactory& platformDecoders();
}
