// SPDX-License-Identifier: MIT
#pragma once
// The GPU's writes of host-coherent memory and what an invalidate reads back of them. A copy
// into a coherent buffer marks the bytes it writes (`imageCopyBytes` sizes a copy from an
// image); a command buffer and a submission keep the marks of each allocation as a few
// disjoint spans (`Spans`); after a wait the invalidate reads the spans no completion record
// delivered, as the ranges `invalidateRanges` plans, each chunk of them one round trip.
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace caboose::memory::gpu {

struct Span {
    uint64_t begin = 0, end = 0;
    bool operator==(const Span& o) const { return begin == o.begin && end == o.end; }
};

// Disjoint, ordered byte ranges [begin, end) of one allocation, at most kMaxSpans of them. A
// range added merges with those it overlaps or touches; one more than kMaxSpans merges the
// two closest neighbours into their hull, so the spans always cover everything added.
class Spans {
public:
    static constexpr size_t kMaxSpans = 8;

    bool empty() const { return count_ == 0; }
    size_t size() const { return count_; }
    const Span* begin() const { return spans_; }
    const Span* end() const { return spans_ + count_; }
    const Span& operator[](size_t i) const { return spans_[i]; }
    void clear() { count_ = 0; }
    uint64_t bytes() const {
        uint64_t total = 0;
        for (const Span& span : *this) total += span.end - span.begin;
        return total;
    }

    // False when the bound merged two spans, so the spans now cover bytes never added.
    bool add(uint64_t begin, uint64_t end) {
        if (end <= begin) return true;
        size_t at = 0;
        while (at < count_ && spans_[at].end < begin) ++at;
        size_t last = at;
        while (last < count_ && spans_[last].begin <= end) {
            begin = std::min(begin, spans_[last].begin);
            end = std::max(end, spans_[last].end);
            ++last;
        }
        // [at, last) are merged into the new span; the rest move to make room for it.
        const size_t removed = last - at;
        if (removed == 0) {
            for (size_t i = count_; i > at; --i) spans_[i] = spans_[i - 1];
            ++count_;
        } else {
            for (size_t i = last; i < count_; ++i) spans_[i - removed + 1] = spans_[i];
            count_ -= removed - 1;
        }
        spans_[at] = {begin, end};
        if (count_ <= kMaxSpans) return true;
        mergeClosest();
        return false;
    }
    bool add(const Spans& other) {
        bool exact = true;
        for (const Span& span : other) exact = add(span.begin, span.end) && exact;
        return exact;
    }
    // Adds the range only if the spans can hold it exactly: false, changing nothing, when
    // that would need more than kMaxSpans spans.
    bool addExactly(uint64_t begin, uint64_t end) {
        Spans next = *this;
        if (!next.add(begin, end)) return false;
        *this = next;
        return true;
    }

    // Whether every byte of [begin, end) is in a span.
    bool covers(uint64_t begin, uint64_t end) const {
        if (end <= begin) return true;
        for (const Span& span : *this)
            if (span.begin <= begin && end <= span.end) return true;
        return false;
    }

    // Removes the bytes `other` covers. What is left may need more spans than the bound: then
    // neighbours merge as add does, and the result still covers every byte not removed.
    void subtract(const Spans& other) {
        if (empty() || other.empty()) return;
        Spans left;
        for (const Span& span : *this) {
            uint64_t from = span.begin;
            for (const Span& cut : other) {
                if (cut.end <= from) continue;
                if (cut.begin >= span.end) break;
                if (cut.begin > from) left.add(from, cut.begin);
                from = std::max(from, cut.end);
                if (from >= span.end) break;
            }
            if (from < span.end) left.add(from, span.end);
        }
        *this = left;
    }

    // Keeps only the bytes in [low, high).
    void clip(uint64_t low, uint64_t high) {
        Spans kept;
        for (const Span& span : *this) {
            const uint64_t b = std::max(span.begin, low), e = std::min(span.end, high);
            if (b < e) kept.add(b, e);
        }
        *this = kept;
    }

private:
    void mergeClosest() {
        size_t closest = 0;
        for (size_t i = 1; i + 1 < count_; ++i)
            if (spans_[i + 1].begin - spans_[i].end < spans_[closest + 1].begin - spans_[closest].end) closest = i;
        spans_[closest].end = spans_[closest + 1].end;
        for (size_t i = closest + 1; i + 1 < count_; ++i) spans_[i] = spans_[i + 1];
        --count_;
    }
    Span spans_[kMaxSpans + 1];
    size_t count_ = 0;
};

// Round trips an invalidate of `bytes` takes, in chunks of `chunk` bytes.
inline uint64_t chunksOf(uint64_t bytes, uint64_t chunk) { return bytes / chunk + (bytes % chunk ? 1 : 0); }

// The ranges an invalidate of `dirty` reads, in order: each span widened to the
// non-coherent atom (its begin down to a multiple of `atom`, its end up to one or to the
// allocation's end) and kept inside the mapping [mapBegin, mapEnd). Neighbours are read as
// one range when that takes no more `chunk`-byte round trips than reading them apart; two
// small writes far apart are read as two ranges, not as everything between them.
inline std::vector<Span> invalidateRanges(const Spans& dirty, uint64_t atom, uint64_t mapBegin, uint64_t mapEnd,
                                          uint64_t allocation, uint64_t chunk) {
    std::vector<Span> out;
    if (!atom) atom = 1;
    if (!chunk) chunk = 1;
    for (const Span& span : dirty) {
        uint64_t begin = std::max(span.begin, mapBegin), end = std::min(span.end, mapEnd);
        if (end <= begin) continue;
        begin = std::max(mapBegin, begin / atom * atom);
        if (end < allocation && end % atom) end = std::min(allocation, end + (atom - end % atom));
        end = std::min(end, mapEnd);
        if (end <= begin) continue;
        if (!out.empty()) {
            Span& last = out.back();
            const uint64_t hull = std::max(end, last.end) - last.begin;
            if (begin <= last.end ||
                chunksOf(hull, chunk) <= chunksOf(last.end - last.begin, chunk) + chunksOf(end - begin, chunk)) {
                last.end = std::max(last.end, end);
                continue;
            }
        }
        out.push_back({begin, end});
    }
    return out;
}

// The bytes a copy between an image and a buffer covers in the buffer, from the region's
// bufferOffset: whole texel blocks of `blockBytes` bytes, each `blockWidth` × `blockHeight`
// texels. `rowLength` and `imageHeight` are the region's bufferRowLength and
// bufferImageHeight in texels (0: the extent's), `slices` its depth times its layer count.
// 0 when the block is not known or the extent is empty; UINT64_MAX when the size does not fit.
inline uint64_t imageCopyBytes(uint32_t blockBytes, uint32_t blockWidth, uint32_t blockHeight, uint32_t rowLength,
                               uint32_t imageHeight, uint32_t width, uint32_t height, uint64_t slices) {
    if (!blockBytes || !blockWidth || !blockHeight || !width || !height || !slices) return 0;
    auto blocks = [](uint64_t texels, uint64_t per) { return (texels + per - 1) / per; };
    const uint64_t rowBlocks = blocks(rowLength ? rowLength : width, blockWidth);
    const uint64_t sliceRows = blocks(imageHeight ? imageHeight : height, blockHeight);
    const uint64_t widthBlocks = blocks(width, blockWidth), heightBlocks = blocks(height, blockHeight);
    // ((slices - 1) * sliceRows + heightBlocks - 1) * rowBlocks + widthBlocks blocks.
    constexpr uint64_t kMax = UINT64_MAX;
    auto mul = [&](uint64_t a, uint64_t b) { return a && b > kMax / a ? kMax : a * b; };
    auto add = [&](uint64_t a, uint64_t b) { return b > kMax - a ? kMax : a + b; };
    const uint64_t rows = add(mul(slices - 1, sliceRows), heightBlocks - 1);
    const uint64_t total = mul(add(mul(rows, rowBlocks), widthBlocks), blockBytes);
    return total;
}

}  // namespace caboose::memory::gpu
