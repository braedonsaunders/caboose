// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// Portable source fixture. No decoder, GPU, or window is used.
#include "packet_framing.h"
#include "decode_diagnostic.h"
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
    // Exact ordinary single-range flush header plus announced 32 MiB tail.
    // The wire header declares 52 bytes; no payload allocation is necessary to
    // prove rejection under the unchanged 16 MiB complete-frame budget.
    std::vector<uint8_t> large;
    put<uint32_t>(large, 20025); put<uint32_t>(large, 52);
    put<uint64_t>(large, 11); put<uint32_t>(large, 1);
    put<uint32_t>(large, 6); put<uint32_t>(large, 0);
    put<uint64_t>(large, 100); put<uint64_t>(large, 0);
    put<uint64_t>(large, 32u * 1024u * 1024u);
    put<uint64_t>(large, 32u * 1024u * 1024u);
    assert(large.size() == 60);
    caboose::gpuv2::FrameDiagnostic diagnostic;
    auto limited = inspectFrame(large.data(), large.size(), 16u * 1024u * 1024u, false, &diagnostic);
    assert(limited.status == FrameStatus::invalid);
    assert(diagnostic.rangeCount == 1 && diagnostic.rangeIndex == 0);
    assert(diagnostic.tailPresent && diagnostic.tailBytes == 32u * 1024u * 1024u);
    assert(diagnostic.tailOffset == 60);
    // An incomplete tail length must never be reported as an observed size.
    limited = inspectFrame(large.data(), 59, 16u * 1024u * 1024u, false, &diagnostic);
    assert(limited.status == FrameStatus::need_more && !diagnostic.tailPresent);
    caboose::gpuv2::DecodeDiagnosticBudget budget;
    for (unsigned i = 0; i < 65; ++i) assert(budget.take() == i);
    for (unsigned i = 0; i < 100; ++i) assert(budget.take() == 65);
    std::vector<uint8_t> unknown;
    put<uint32_t>(unknown, 0); put<uint32_t>(unknown, 8);
    assert(inspectFrame(unknown.data(), unknown.size(), 4096, false).status == FrameStatus::invalid);
    std::vector<uint8_t> normal;
    put<uint32_t>(normal, 20000); put<uint32_t>(normal, 8);
    assert(inspectFrame(normal.data(), normal.size(), 4096, false).status == FrameStatus::ready);
}
