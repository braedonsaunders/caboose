import Foundation

/// How a picture's content moved relative to an older picture of the same window.
public struct ScrollMotion: Equatable, Sendable {
    /// Line `y` of the newer picture shows what line `y + shift` of the older one showed:
    /// positive when the content advanced (scrolled down or right).
    public var shift: Int
    /// The moving span along the axis, in the newer picture's lines. Lines outside it are
    /// fixed: toolbars, sticky headers, status bars.
    public var lines: Range<Int>
    /// The contiguous run of moving bands across the axis. Bands outside it are fixed:
    /// sidebars, gutters that do not scroll.
    public var bands: Range<Int>
    /// The fraction of sampled detail that this motion explains, 0–1.
    public var support: Double

    public init(shift: Int, lines: Range<Int>, bands: Range<Int>, support: Double) {
        self.shift = shift; self.lines = lines; self.bands = bands; self.support = support
    }
}

public enum ScrollMeasurement: Equatable, Sendable {
    /// Part of the picture moved rigidly.
    case moved(ScrollMotion)
    /// Nothing moved; content may have changed in place.
    case still
    /// The content changed in a way no rigid motion within the searched range explains
    /// (a new page, a reflow, a jump beyond the search).
    case unexplained
}

/// Measures rigid content motion between two pictures from their line signatures.
///
/// Detailed cells of the newer picture are sampled and each candidate shift is scored by
/// how many of them reappear, within tolerance, `shift` lines further along in the older
/// picture. Flat cells (blank page, uniform panels) match every shift and are not sampled.
/// The best shift other than zero must explain detail that zero does not; cells explained
/// only by zero are fixed and bound the moving region. Ties between periodic matches (a
/// list of identical rows) go to the shift nearest the expected one.
public struct ScrollMotionEstimator: Sendable {
    /// Largest per-cell luma and detail difference that still matches, on a 0–255 scale.
    /// Signature cells average tens of pixels, so video coding noise stays well within it.
    public var tolerance: Float = 2.5
    /// Most detailed cells scored per candidate shift.
    public var maximumSamples = 2048
    /// Fewest sampled cells that the motion must explain beyond what standing still does.
    public var minimumEvidence = 12
    /// Least fraction of the sampled detail not explained by standing still that a motion
    /// within the expected shifts must explain, and one outside them.
    public var minimumSupport = 0.15
    public var unexpectedSupport = 0.35

    public init() {}

    /// - Parameters:
    ///   - expected: shifts to search. Zero is always scored.
    ///   - center: the most likely shift, which breaks ties between periodic matches.
    ///   - anchor: the band under the scroll gesture, whose moving run is the region.
    public func measure(from older: ScrollSignature, to newer: ScrollSignature,
                        expected: ClosedRange<Int>, center: Int? = nil, anchor: Int? = nil) -> ScrollMeasurement {
        guard older.lines == newer.lines, older.bands == newer.bands, older.axis == newer.axis else { return .unexplained }
        let lines = newer.lines, bands = newer.bands
        let limit = lines - 16
        guard limit > 0 else { return .unexplained }
        let low = Swift.max(-limit, expected.lowerBound), high = Swift.min(limit, expected.upperBound)
        let result = measure(older, newer, low: low, high: high, center: center, anchor: anchor, support: minimumSupport)
        // A jump beyond the expectation (a stall, a page key) is still worth one full search,
        // which must be explained by much more of the picture.
        if result == .unexplained, low > -limit || high < limit {
            return measure(older, newer, low: -limit, high: limit, center: center, anchor: anchor, support: unexpectedSupport)
        }
        return result
    }

    private func measure(_ older: ScrollSignature, _ newer: ScrollSignature, low: Int, high: Int, center: Int?, anchor: Int?, support: Double) -> ScrollMeasurement {
        let lines = newer.lines, bands = newer.bands
        return newer.luma.withUnsafeBufferPointer { nl in
            newer.detail.withUnsafeBufferPointer { nd in
                older.luma.withUnsafeBufferPointer { ol in
                    older.detail.withUnsafeBufferPointer { od in
                        measure(nl: nl, nd: nd, ol: ol, od: od, lines: lines, bands: bands,
                                low: low, high: high, center: center, anchor: anchor, support: support)
                    }
                }
            }
        }
    }

    private func informative(_ l: UnsafeBufferPointer<Float>, _ d: UnsafeBufferPointer<Float>, line: Int, band: Int, lines: Int, bands: Int) -> Bool {
        let cell = line * bands + band
        if d[cell] >= 1.5 { return true }
        let above = line > 0 ? abs(l[cell] - l[cell - bands]) : 0
        let below = line + 1 < lines ? abs(l[cell + bands] - l[cell]) : 0
        return above + below >= 4
    }

    @inline(__always) private func matches(_ nl: UnsafeBufferPointer<Float>, _ nd: UnsafeBufferPointer<Float>, _ a: Int,
                                           _ ol: UnsafeBufferPointer<Float>, _ od: UnsafeBufferPointer<Float>, _ b: Int) -> Bool {
        abs(nl[a] - ol[b]) <= tolerance && abs(nd[a] - od[b]) <= tolerance + 0.1 * nd[a]
    }

    private func measure(nl: UnsafeBufferPointer<Float>, nd: UnsafeBufferPointer<Float>,
                         ol: UnsafeBufferPointer<Float>, od: UnsafeBufferPointer<Float>,
                         lines: Int, bands: Int, low: Int, high: Int, center: Int?, anchor: Int?, support minimum: Double) -> ScrollMeasurement {
        // Detailed cells of the newer picture, evenly thinned to the sample budget.
        var detailed: [Int32] = []
        detailed.reserveCapacity(lines * bands / 4)
        for line in 0..<lines {
            for band in 0..<bands where informative(nl, nd, line: line, band: band, lines: lines, bands: bands) {
                detailed.append(Int32(line * bands + band))
            }
        }
        let still = { () -> ScrollMeasurement in
            var same = 0
            for cell in 0..<(lines * bands) where self.matches(nl, nd, cell, ol, od, cell) { same += 1 }
            return Double(same) >= 0.9 * Double(lines * bands) ? .still : .unexplained
        }
        guard detailed.count >= minimumEvidence else { return still() }
        var samples: [Int32]
        if detailed.count > maximumSamples {
            samples = []
            samples.reserveCapacity(maximumSamples)
            let step = Double(detailed.count) / Double(maximumSamples)
            for i in 0..<maximumSamples { samples.append(detailed[Int(Double(i) * step)]) }
        } else {
            samples = detailed
        }

        // Score zero and every candidate shift by the sampled cells they explain.
        let count = samples.count, total = lines * bands
        var atZero = [Bool](repeating: false, count: count)
        var zeroScore = 0
        for (i, cell) in samples.enumerated() where matches(nl, nd, Int(cell), ol, od, Int(cell)) {
            atZero[i] = true
            zeroScore += 1
        }
        var scores: [(shift: Int, moved: Int)] = []
        if low <= high {
            scores.reserveCapacity(high - low + 1)
            samples.withUnsafeBufferPointer { cells in
                for shift in low...high where shift != 0 {
                    let offset = shift * bands
                    var moved = 0
                    for i in 0..<count {
                        let a = Int(cells[i]), b = a + offset
                        guard b >= 0, b < total, !atZero[i] else { continue }
                        if matches(nl, nd, a, ol, od, b) { moved += 1 }
                    }
                    scores.append((shift, moved))
                }
            }
        }
        let best = scores.max { $0.moved < $1.moved }?.moved ?? 0
        let support = Double(best) / Double(Swift.max(1, count - zeroScore))
        guard best >= minimumEvidence, Double(best) >= 0.04 * Double(count), support >= minimum else {
            return Double(zeroScore) >= 0.5 * Double(count) ? .still : .unexplained
        }
        // Periodic content scores several shifts alike: take the one nearest the expectation.
        let preferred = center ?? 0
        let shift = scores.filter { Double($0.moved) >= 0.97 * Double(best) }
            .min { abs($0.shift - preferred) < abs($1.shift - preferred) }!.shift

        // Classify every detailed cell: explained by the motion only, or by standing still only.
        var movedByBand = [Int](repeating: 0, count: bands), fixedByBand = movedByBand
        var label = [Int8](repeating: 0, count: total) // 1 moved only, -1 fixed only, 2 neither
        for cell in detailed {
            let a = Int(cell), b = a + shift * bands
            let moves = b >= 0 && b < total && matches(nl, nd, a, ol, od, b)
            let stays = matches(nl, nd, a, ol, od, a)
            // Only cells whose content could have moved here vote on which bands move.
            let overlaps = b >= 0 && b < total
            if moves && !stays { label[a] = 1; movedByBand[a % bands] += 1 }
            else if stays && !moves { label[a] = -1; if overlaps { fixedByBand[a % bands] += 1 } }
            else if !moves && !stays { label[a] = 2 }
        }

        // The moving bands: those whose detail mostly moved, joined across featureless bands.
        func moving(_ band: Int) -> Bool { movedByBand[band] >= 3 && movedByBand[band] >= fixedByBand[band] }
        func neutral(_ band: Int) -> Bool { movedByBand[band] == 0 && fixedByBand[band] == 0 }
        var runs: [Range<Int>] = []
        var band = 0
        while band < bands {
            guard moving(band) else { band += 1; continue }
            var end = band + 1
            while end < bands {
                if moving(end) { end += 1; continue }
                var gap = end
                while gap < bands, neutral(gap) { gap += 1 }
                if gap < bands, moving(gap) { end = gap + 1 } else { break }
            }
            var start = band
            while start > 0, neutral(start - 1) { start -= 1 }
            while end < bands, neutral(end) { end += 1 }
            runs.append(start..<end)
            band = end
        }
        let weight = { (run: Range<Int>) in run.reduce(0) { $0 + movedByBand[$1] } }
        guard let run = runs.first(where: { anchor.map($0.contains) ?? false }) ?? runs.max(by: { weight($0) < weight($1) })
        else { return Double(zeroScore) >= 0.5 * Double(count) ? .still : .unexplained }

        // The moving lines. A fixed band is a solid run of lines whose detail stayed: each
        // boundary is placed where the lines beyond it are most consistently fixed. Lines
        // that moved, or match neither way (content newly revealed), count against it;
        // featureless lines count for neither, so they join the moving region.
        var evidence = [Int](repeating: 0, count: lines)
        var anyMoved = false
        for line in 0..<lines {
            var moved = 0, fixed = 0, neither = 0
            for band in run {
                switch label[line * bands + band] {
                case 1: moved += 1
                case -1: fixed += 1
                case 2: neither += 1
                default: break
                }
            }
            if fixed > moved + neither { evidence[line] = 1 }
            else if moved + neither > 0 { evidence[line] = -1 }
            if moved > fixed { anyMoved = true }
        }
        guard anyMoved else { return .still }
        var top = 0, strongest = 0, sum = 0
        for line in 0..<lines {
            sum += evidence[line]
            if sum > strongest { strongest = sum; top = line + 1 }
        }
        var bottom = lines
        strongest = 0; sum = 0
        for line in stride(from: lines - 1, through: top, by: -1) {
            sum += evidence[line]
            if sum > strongest { strongest = sum; bottom = line }
        }
        guard top < bottom else { return .still }
        return .moved(ScrollMotion(shift: shift, lines: top..<bottom, bands: run, support: support))
    }
}
