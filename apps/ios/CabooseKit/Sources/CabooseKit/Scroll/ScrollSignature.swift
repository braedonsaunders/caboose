import Foundation

/// The axis a local scroll moves content along.
public enum ScrollAxis: Int, Sendable, Equatable {
    case vertical, horizontal

    /// The dominant axis of a movement, vertical on a tie.
    public static func dominant(_ delta: CGPoint) -> ScrollAxis {
        abs(delta.x) > abs(delta.y) ? .horizontal : .vertical
    }

    public func component(_ point: CGPoint) -> CGFloat { self == .vertical ? point.y : point.x }
    public func component(_ size: CGSize) -> CGFloat { self == .vertical ? size.height : size.width }
    public func cross(_ size: CGSize) -> CGFloat { self == .vertical ? size.width : size.height }
    public func point(along value: CGFloat) -> CGPoint {
        self == .vertical ? CGPoint(x: 0, y: value) : CGPoint(x: value, y: 0)
    }
}

/// Per-line summaries of one picture along one axis, the input of motion measurement.
///
/// For vertical scrolling a line is a pixel row and a band is a vertical strip of columns;
/// for horizontal scrolling it is the transpose. Each (line, band) cell holds the mean
/// sRGB-encoded colour on a 0–255 scale and `detail`, the mean absolute luma difference
/// between neighbouring pixels along the line. Rigidly scrolled content keeps its cells and
/// only changes line index, which is what `ScrollMotionEstimator` looks for. The GPU kernel
/// in `LocalScrollRenderer` and `init(bgra:)` compute identical values.
public struct ScrollSignature: Sendable, Equatable {
    public let axis: ScrollAxis
    public let lines: Int
    public let bands: Int
    /// The picture's extent across the lines, in pixels; band `b` covers
    /// `b * span / bands ..< (b + 1) * span / bands`.
    public let span: Int
    /// `[line * bands + band]`
    public internal(set) var luma: [Float]
    public internal(set) var detail: [Float]
    /// Mean red, green and blue, `[(line * bands + band) * 3 + channel]`.
    public internal(set) var color: [Float]

    public init(axis: ScrollAxis, lines: Int, bands: Int, span: Int, luma: [Float], detail: [Float], color: [Float]) {
        precondition(lines > 0 && bands > 0 && span >= bands)
        precondition(luma.count == lines * bands && detail.count == luma.count && color.count == luma.count * 3)
        self.axis = axis; self.lines = lines; self.bands = bands; self.span = span
        self.luma = luma; self.detail = detail; self.color = color
    }

    /// Unpacks the GPU kernel's output: four floats per cell, red, green, blue and detail.
    public init(axis: ScrollAxis, lines: Int, bands: Int, span: Int, packed: UnsafeBufferPointer<Float>) {
        precondition(packed.count >= lines * bands * 4)
        var luma = [Float](repeating: 0, count: lines * bands)
        var detail = luma
        var color = [Float](repeating: 0, count: lines * bands * 3)
        for cell in 0..<(lines * bands) {
            let r = packed[cell * 4], g = packed[cell * 4 + 1], b = packed[cell * 4 + 2]
            color[cell * 3] = r; color[cell * 3 + 1] = g; color[cell * 3 + 2] = b
            luma[cell] = Self.luma(r, g, b)
            detail[cell] = packed[cell * 4 + 3]
        }
        self.init(axis: axis, lines: lines, bands: bands, span: span, luma: luma, detail: detail, color: color)
    }

    /// The reference computation over BGRA pixels, used by tests and as the definition the
    /// GPU kernel follows.
    public init(axis: ScrollAxis, bands requested: Int, width: Int, height: Int, rowBytes: Int, bgra: UnsafeRawBufferPointer) {
        let lines = axis == .vertical ? height : width
        let span = axis == .vertical ? width : height
        let bands = Swift.max(1, Swift.min(requested, span))
        var luma = [Float](repeating: 0, count: lines * bands)
        var detail = luma
        var color = [Float](repeating: 0, count: lines * bands * 3)
        for line in 0..<lines {
            for band in 0..<bands {
                let start = band * span / bands, end = (band + 1) * span / bands
                var r: Float = 0, g: Float = 0, b: Float = 0, sum: Float = 0, previous: Float = 0
                for i in start..<end {
                    let x = axis == .vertical ? i : line, y = axis == .vertical ? line : i
                    let p = y * rowBytes + x * 4
                    let pb = Float(bgra[p]), pg = Float(bgra[p + 1]), pr = Float(bgra[p + 2])
                    r += pr; g += pg; b += pb
                    let l = Self.luma(pr, pg, pb)
                    if i > start { sum += abs(l - previous) }
                    previous = l
                }
                let n = Float(end - start), cell = line * bands + band
                color[cell * 3] = r / n; color[cell * 3 + 1] = g / n; color[cell * 3 + 2] = b / n
                luma[cell] = Self.luma(r / n, g / n, b / n)
                detail[cell] = sum / Swift.max(1, n - 1)
            }
        }
        self.init(axis: axis, lines: lines, bands: bands, span: span, luma: luma, detail: detail, color: color)
    }

    @inline(__always) static func luma(_ r: Float, _ g: Float, _ b: Float) -> Float {
        0.299 * r + 0.587 * g + 0.114 * b
    }

    /// The pixel range across the lines that `bands` covers.
    public func pixels(of bands: Range<Int>) -> Range<Int> {
        let lower = Swift.max(0, Swift.min(self.bands, bands.lowerBound)), upper = Swift.max(lower, Swift.min(self.bands, bands.upperBound))
        return (lower * span / self.bands)..<(upper * span / self.bands)
    }

    /// The band containing pixel `position` across the lines.
    public func band(at position: Int) -> Int {
        Swift.max(0, Swift.min(bands - 1, position * bands / Swift.max(1, span)))
    }

    /// The mean colour of `lines` within `bands`, 0–1, for filling content not yet seen.
    public func meanColor(lines: Range<Int>, bands: Range<Int>) -> SIMD3<Float> {
        let lines = lines.clamped(to: 0..<self.lines), bands = bands.clamped(to: 0..<self.bands)
        guard !lines.isEmpty, !bands.isEmpty else { return SIMD3(0, 0, 0) }
        var sum = SIMD3<Float>(0, 0, 0)
        for line in lines {
            for band in bands {
                let cell = (line * self.bands + band) * 3
                sum += SIMD3(color[cell], color[cell + 1], color[cell + 2])
            }
        }
        return sum / Float(lines.count * bands.count) / 255
    }

    /// The default number of bands for a picture `span` pixels across: about 40 pixels
    /// each, so a sidebar or a scroll bar's column separates from the content beside it.
    public static func bandCount(span: Int) -> Int { Swift.max(8, Swift.min(64, span / 40)) }
}
