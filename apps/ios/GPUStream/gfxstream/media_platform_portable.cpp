// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// Platforms without a Caboose media decoder (the Linux reference receiver): CAPS lists no
// format, so the guest decodes every stream locally, and LATCH packets are validated and
// leave their images as they were.
#include "media_latch.h"
#include "media_session.h"
#include <cerrno>

namespace caboose::gpuv2 {
namespace media {
namespace {
class NoDecoders final : public DecoderFactory {
public:
    std::vector<Capability> capabilities() override { return {}; }
    std::unique_ptr<Decoder> create(const Open&, DecoderSink&) override { return nullptr; }
};
}
DecoderFactory& platformDecoders() {
    static NoDecoders* factory = new NoDecoders;
    return *factory;
}
}

int executeLatch(uint32_t, const uint8_t* data, size_t size) {
    media::Latch latch;
    return media::parseLatch(data, size, &latch);
}
}
