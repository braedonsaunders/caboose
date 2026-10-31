import Foundation
import Testing
@testable import CabooseKit

/// The estimator on pictures built pixel by pixel and summarized by the CPU definition.
struct ScrollMotionEstimatorTests {
    /// A text-like page: rows of glyph runs with gaps, deterministic per content position.
    static func ink(_ x: Int, _ y: Int) -> UInt8 {
        var h = UInt64(bitPattern: Int64(x &* 73_856_093 ^ y &* 19_349_663))
        h ^= h >> 13; h &*= 0x5bd1e995; h ^= h >> 15
        let line = y % 24, word = (x / 37) % 5
        return line < 6 || line > 18 || word == 4 ? 250 : UInt8(120 + h % 120)
    }

    /// A `width`×`height` picture of the page moved by `offset` along `axis`, with a fixed
    /// band of `fixed` pixels (a header for vertical scrolling, a sidebar for horizontal).
    static func picture(axis: ScrollAxis, offset: Int, fixed: Int, width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let along = axis == .vertical ? y : x
                let value: UInt8
                if along < fixed { value = 60 + UInt8((x * 7 + y * 3) % 90) }
                else { value = axis == .vertical ? ink(x, y + offset) : ink(x + offset, y) }
                let p = (y * width + x) * 4
                bytes[p] = value; bytes[p + 1] = value; bytes[p + 2] = value
            }
        }
        return bytes
    }

    static func signature(_ bytes: [UInt8], axis: ScrollAxis, width: Int, height: Int) -> ScrollSignature {
        bytes.withUnsafeBytes {
            ScrollSignature(axis: axis, bands: ScrollSignature.bandCount(span: axis == .vertical ? width : height),
                            width: width, height: height, rowBytes: width * 4, bgra: $0)
        }
    }

    @Test(arguments: [ScrollAxis.vertical, .horizontal])
    func measuresShiftAndFixedBand(axis: ScrollAxis) {
        let width = 640, height = 480, fixed = 48, shift = 53
        let older = Self.signature(Self.picture(axis: axis, offset: 0, fixed: fixed, width: width, height: height), axis: axis, width: width, height: height)
        let newer = Self.signature(Self.picture(axis: axis, offset: shift, fixed: fixed, width: width, height: height), axis: axis, width: width, height: height)
        guard case .moved(let motion) = ScrollMotionEstimator().measure(from: older, to: newer, expected: -64...160) else {
            Issue.record("no motion found"); return
        }
        #expect(motion.shift == shift)
        #expect(motion.lines.lowerBound == fixed)
        #expect(motion.lines.upperBound == (axis == .vertical ? height : width))
        #expect(motion.bands == 0..<newer.bands)
    }

    @Test func standingStillAndUnrelatedPictures() {
        let width = 320, height = 400
        let a = Self.signature(Self.picture(axis: .vertical, offset: 0, fixed: 40, width: width, height: height), axis: .vertical, width: width, height: height)
        #expect(ScrollMotionEstimator().measure(from: a, to: a, expected: -64...64) == .still)
        // A different page entirely (the same header) moved by nothing anyone sent.
        var other = Self.picture(axis: .vertical, offset: 0, fixed: 40, width: width, height: height)
        for i in stride(from: 40 * width * 4, to: other.count, by: 4) { other[i] = 255 &- other[i]; other[i + 1] = other[i]; other[i + 2] = other[i] }
        let b = Self.signature(other, axis: .vertical, width: width, height: height)
        #expect(ScrollMotionEstimator().measure(from: a, to: b, expected: -64...64) == .unexplained)
    }
}

extension ScrollMotionEstimatorTests {
    @Test func findsAFixedOverlayInsideTheRegion() {
        let width = 640, height = 480, shift = 41
        // A floating button with its own detail, fixed over the scrolling page.
        func picture(_ offset: Int) -> [UInt8] {
            var bytes = Self.picture(axis: .vertical, offset: offset, fixed: 48, width: width, height: height)
            for y in 320..<400 { for x in 480..<600 {
                let v = UInt8(40 + (x * 13 + y * 7) % 160), p = (y * width + x) * 4
                bytes[p] = v; bytes[p + 1] = v; bytes[p + 2] = v
            } }
            return bytes
        }
        let older = Self.signature(picture(0), axis: .vertical, width: width, height: height)
        let newer = Self.signature(picture(shift), axis: .vertical, width: width, height: height)
        guard case .moved(let motion) = ScrollMotionEstimator().measure(from: older, to: newer, expected: -64...160) else {
            Issue.record("no motion found"); return
        }
        #expect(motion.shift == shift)
        let found = motion.stationary.map { (lines: $0.lines, pixels: newer.pixels(of: $0.bands)) }
        #expect(found.contains { $0.lines.lowerBound >= 304 && $0.lines.upperBound <= 416 && $0.pixels.lowerBound >= 440 && $0.pixels.upperBound <= 640 })
    }
}
