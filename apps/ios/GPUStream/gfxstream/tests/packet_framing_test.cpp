// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// Portable source fixture. No decoder, GPU, or window is used.
#include "packet_framing.h"
#include <cassert>
#include <cstdint>
#include <cstring>
#include <vector>
using caboose::gpuv2::FrameStatus;
using caboose::gpuv2::inspectFrame;
namespace {
template <typename T> void put(std::vector<uint8_t>& out, T v) {
    auto start = out.size(); out.resize(start + sizeof(T));
    std::memcpy(out.data() + start, &v, sizeof(T));
}
std::vector<uint8_t> flush(bool seq, bool extension) {
    std::vector<uint8_t> b;
    put<uint32_t>(b, 20025); put<uint32_t>(b, 8 + (seq ? 4 : 0) + 8 + 4 + 2 * 32);
    if (seq) put<uint32_t>(b, 1);
    put<uint64_t>(b, 11); put<uint32_t>(b, 2);
    for (int i = 0; i < 2; ++i) {
        put<uint32_t>(b, 6); put<uint32_t>(b, (i == 0 && extension) ? 0x01000000 : 0);
        put<uint64_t>(b, 100 + i); put<uint64_t>(b, 0); put<uint64_t>(b, 3);
    }
    put<uint64_t>(b, 3); b.insert(b.end(), {1, 2, 3});
    put<uint64_t>(b, 2); b.insert(b.end(), {4, 5});
    return b;
}
}
int main() {
    for (bool seq : {false, true}) {
        auto b = flush(seq, false);
        for (size_t i = 0; i < b.size(); ++i) {
            auto r = inspectFrame(b.data(), i, 4096, seq);
            assert(r.status == FrameStatus::need_more && r.size > i && r.size <= b.size());
        }
        auto r = inspectFrame(b.data(), b.size(), 4096, seq);
        assert(r.status == FrameStatus::ready && r.size == b.size());
        auto n = b.size(); b.insert(b.end(), {1,2,3,4,5,6,7,8});
        r = inspectFrame(b.data(), b.size(), 4096, seq);
        assert(r.status == FrameStatus::ready && r.size == n);
        b = flush(seq, true);
        assert(inspectFrame(b.data(), b.size(), 4096, seq).status == FrameStatus::unsupported);
        b = flush(seq, false);
        assert(inspectFrame(b.data(), b.size(), b.size() - 1, seq).status == FrameStatus::invalid);
    }
    std::vector<uint8_t> unknown;
    put<uint32_t>(unknown, 0); put<uint32_t>(unknown, 8);
    assert(inspectFrame(unknown.data(), unknown.size(), 4096, false).status == FrameStatus::invalid);
    std::vector<uint8_t> normal;
    put<uint32_t>(normal, 20000); put<uint32_t>(normal, 8);
    assert(inspectFrame(normal.data(), normal.size(), 4096, false).status == FrameStatus::ready);
}
