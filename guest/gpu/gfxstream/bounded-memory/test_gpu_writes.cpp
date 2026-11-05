// SPDX-License-Identifier: MIT
// GPU writes of coherent memory: the bounded spans a command buffer and a submission keep,
// the ranges an invalidate reads of them, and the bytes a copy from an image writes.
#include "gpu_writes.h"
#include "ranges.h"

#include <cassert>
#include <cstdio>
#include <vector>

using namespace caboose::memory::gpu;

namespace {
std::vector<Span> spans(const Spans& s) { return std::vector<Span>(s.begin(), s.end()); }
using V = std::vector<Span>;
}  // namespace

int main() {
    // Ranges stay apart unless they overlap or touch; added in any order, they stay ordered.
    {
        Spans s;
        assert(s.empty() && s.bytes() == 0);
        assert(s.add(100, 200) && s.add(0, 10) && s.add(1000, 1010));
        assert(spans(s) == (V{{0, 10}, {100, 200}, {1000, 1010}}));
        assert(s.add(200, 300));  // touching
        assert(spans(s) == (V{{0, 10}, {100, 300}, {1000, 1010}}));
        assert(s.add(5, 150));    // overlapping two
        assert(spans(s) == (V{{0, 300}, {1000, 1010}}) && s.bytes() == 310);
        assert(s.add(50, 60) && s.add(7, 7));  // inside, and empty
        assert(spans(s) == (V{{0, 300}, {1000, 1010}}));
        assert(s.add(0, 2000) && spans(s) == (V{{0, 2000}}));
        assert(s.covers(0, 2000) && s.covers(10, 20) && !s.covers(1999, 2001) && s.covers(5, 5));
    }
    // Past the bound the two closest neighbours merge: everything added stays covered.
    {
        Spans s;
        for (uint64_t i = 0; i < Spans::kMaxSpans; ++i) assert(s.add(i * 1000, i * 1000 + 10));
        assert(s.size() == Spans::kMaxSpans);
        assert(!s.add(2015, 2020));  // 5 bytes from [2000, 2010): those two merge
        assert(s.size() == Spans::kMaxSpans);
        assert(s[2] == (Span{2000, 2020}) && s.covers(2010, 2015));
        for (uint64_t i = 0; i < Spans::kMaxSpans; ++i) assert(s.covers(i * 1000, i * 1000 + 10));
        // addExactly refuses what would need the merge, and changes nothing.
        Spans exact;
        for (uint64_t i = 0; i < Spans::kMaxSpans; ++i) assert(exact.addExactly(i * 1000, i * 1000 + 10));
        const V before = spans(exact);
        assert(!exact.addExactly(2015, 2020) && spans(exact) == before);
        assert(exact.addExactly(2010, 2020) && exact[2] == (Span{2000, 2020}));  // touching fits
    }
    // Subtracting: what a record delivered leaves what is still to be read.
    {
        Spans written, delivered;
        written.add(0, 100);
        written.add(200, 300);
        delivered.add(0, 100);
        delivered.add(200, 300);
        Spans rest = written;
        rest.subtract(delivered);
        assert(rest.empty());
        delivered.clear();
        delivered.add(20, 40);
        delivered.add(250, 400);
        rest = written;
        rest.subtract(delivered);
        assert(spans(rest) == (V{{0, 20}, {40, 100}, {200, 250}}));
        rest = written;
        rest.subtract(Spans{});
        assert(spans(rest) == spans(written));
        // Cuts splitting every span past the bound still cover what remains.
        Spans many;
        for (uint64_t i = 0; i < Spans::kMaxSpans; ++i) many.add(i * 100, i * 100 + 50);
        Spans cuts;
        for (uint64_t i = 0; i < Spans::kMaxSpans; ++i) cuts.add(i * 100 + 20, i * 100 + 30);
        Spans left = many;
        left.subtract(cuts);
        assert(left.size() <= Spans::kMaxSpans);
        for (uint64_t i = 0; i < Spans::kMaxSpans; ++i)
            assert(left.covers(i * 100, i * 100 + 20) && left.covers(i * 100 + 30, i * 100 + 50));
        // Clipping keeps the mapped part.
        Spans clipped = written;
        clipped.clip(50, 250);
        assert(spans(clipped) == (V{{50, 100}, {200, 250}}));
    }
    // The invalidate's ranges: atom-aligned in the mapping; neighbours merge only when that
    // takes no more round trips.
    {
        const uint64_t chunk = caboose::memory::payloadBytes;
        Spans s;
        s.add(100, 200);
        s.add(60000, 60100);
        // Both fit one chunk: one range, one round trip.
        assert(invalidateRanges(s, 64, 0, 1 << 20, 1 << 20, chunk) == (V{{64, 60160}}));
        // Far apart: two ranges, two round trips, not the 17 chunks between them.
        s.clear();
        s.add(100, 200);
        s.add(1 << 20, (1 << 20) + 100);
        const auto apart = invalidateRanges(s, 64, 0, 2 << 20, 2 << 20, chunk);
        assert(apart == (V{{64, 256}, {1 << 20, (1 << 20) + 128}}));
        // Atom alignment keeps to the mapping and ends at the allocation's end.
        s.clear();
        s.add(10, 20);
        s.add(990, 1000);
        assert(invalidateRanges(s, 256, 0, 1000, 1000, chunk) == (V{{0, 1000}}));
        assert(invalidateRanges(s, 256, 512, 1000, 1000, chunk) == (V{{768, 1000}}));
        // Outside the mapping: nothing.
        assert(invalidateRanges(s, 256, 2000, 3000, 4000, chunk).empty());
        // Ranges that overlap once aligned are one.
        s.clear();
        s.add(0, 10);
        s.add(70, 80);
        assert(invalidateRanges(s, 64, 0, 4096, 4096, 1) == (V{{0, 128}}));
        // A hull that would take one more round trip than the parts stays apart.
        s.clear();
        s.add(0, chunk);
        s.add(chunk + 100, chunk + 200);
        assert(invalidateRanges(s, 4, 0, 4 * chunk, 4 * chunk, chunk) == (V{{0, chunk + 200}}));  // 2 either way
        s.clear();
        s.add(0, chunk);
        s.add(2 * chunk + 100, 2 * chunk + 200);
        assert(invalidateRanges(s, 4, 0, 4 * chunk, 4 * chunk, chunk) ==
               (V{{0, chunk}, {2 * chunk + 100, 2 * chunk + 200}}));  // 3 as one, 2 apart
        // The planned ranges pass ranges.h's checks for a transaction.
        s.clear();
        s.add(3, 5);
        s.add(300000, 300001);
        for (const Span& r : invalidateRanges(s, 64, 0, 1 << 20, (1 << 20) - 7, chunk))
            assert(r.begin % 64 == 0 && (r.end % 64 == 0 || r.end == (1 << 20) - 7) && r.end > r.begin);
    }
    // A copy from an image writes whole texel blocks, rows of bufferRowLength and slices of
    // bufferImageHeight, ending at the last block of the last row.
    {
        // 4-byte texels, 64 × 32 tightly packed: 8192 bytes, not 16 per texel.
        assert(imageCopyBytes(4, 1, 1, 0, 0, 64, 32, 1) == 64 * 32 * 4);
        // Rows of 128 texels, 32 rows, the last row only 64 wide.
        assert(imageCopyBytes(4, 1, 1, 128, 0, 64, 32, 1) == (31 * 128 + 64) * 4);
        // Three layers of 64 × 32 with slices of 40 rows.
        assert(imageCopyBytes(2, 1, 1, 0, 40, 64, 32, 3) == ((2 * 40 + 31) * 64 + 64) * 2);
        // BC1: 4 × 4 blocks of 8 bytes; 30 × 30 texels are 8 × 8 blocks.
        assert(imageCopyBytes(8, 4, 4, 0, 0, 30, 30, 1) == 8 * 8 * 8);
        // A depth aspect of a 32-bit format: one 4-byte texel.
        assert(imageCopyBytes(4, 1, 1, 0, 0, 1, 1, 1) == 4);
        // Unknown blocks and empty extents say nothing.
        assert(imageCopyBytes(0, 1, 1, 0, 0, 64, 32, 1) == 0);
        assert(imageCopyBytes(4, 1, 1, 0, 0, 0, 32, 1) == 0);
        assert(imageCopyBytes(4, 1, 1, 0, 0, 64, 32, 0) == 0);
        // Sizes past 64 bits saturate.
        assert(imageCopyBytes(16, 1, 1, 0xFFFFFFFFu, 0xFFFFFFFFu, 0xFFFFFFFFu, 0xFFFFFFFFu, 0xFFFFFFFFull) ==
               UINT64_MAX);
    }
    std::printf("gpu writes: ok\n");
}
