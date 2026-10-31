import Foundation
@testable import CabooseKit

/// A deterministic replay of finger gestures against a simulated remote app, run through the
/// real `LocalScroll` and `ScrollMotionEstimator` at 120 Hz. The app applies forwarded scroll
/// after an input delay with its own gain, clamps to its content, renders at its own frame
/// rate with jitter and hitches, and its pictures reach the phone after an output delay.
/// Pictures are line signatures of a synthetic page: a fixed toolbar, text, images and an
/// optional fixed footer and sidebar, with coding noise.
struct ScrollReplay {
    struct App {
        var inputDelay: TimeInterval = 0.02
        var outputDelay: TimeInterval = 0.04
        var fps: Double = 30
        var jitter: TimeInterval = 0.004
        /// (every, duration): a stall of `duration` once every `every` seconds.
        var hitch: (every: TimeInterval, duration: TimeInterval)? = nil
        var gain: Double = 1
        var pageLines = 20000
        var startOffset = 4000.0
        var noise: Float = 0.8
        var footer = 0
        var sidebar = 0
        var latency: TimeInterval { inputDelay + outputDelay + 0.5 / fps }
    }

    /// One finger gesture: positions in points (content direction) sampled at 120 Hz, then lift.
    struct Gesture {
        var start: TimeInterval
        var samples: [(time: TimeInterval, position: Double)]
        var release: TimeInterval { samples.last!.time }
        var releaseVelocity: Double { LocalScrollGesture(label: "", samples: samples).releaseVelocity }

        /// The scripted gestures the device replay plays, here starting at `start`.
        init(at start: TimeInterval, _ gesture: LocalScrollGesture) {
            self.start = start
            samples = gesture.samples.map { (start + $0.time, $0.position) }
        }
        init(start: TimeInterval, samples: [(time: TimeInterval, position: Double)]) {
            self.start = start; self.samples = samples
        }
        static func flick(at start: TimeInterval, peak: Double, duration: TimeInterval) -> Gesture {
            Gesture(at: start, .flick("", peak: peak, duration: duration))
        }
        static func drag(at start: TimeInterval, speed: Double, duration: TimeInterval, hold: TimeInterval = 0.2) -> Gesture {
            Gesture(at: start, .drag("", speed: speed, duration: duration, hold: hold))
        }
    }

    struct Report {
        var name = ""
        var blank: [Double] = []          // fraction of the region blank, per active refresh
        var trackingError: [Double] = []  // |shown − native iOS reference| px, per active refresh
        var misplacement = 0.0            // worst layer drawn at the wrong content position, px
        var responseRefreshes = Int.max   // refreshes from first finger movement to moved content
        var settleTime: TimeInterval = .infinity // the phone at rest to handing back to the app
        var finalError = 0.0              // app's final offset vs phone's final position, px
        var handoffJump = 0.0             // worst content jump against the phone's own motion, px
        var appLeadMax = 0.0              // furthest the app ran ahead of the phone while moving, px
        var learnedLatency: TimeInterval = 0
        var learnedGain = 0.0
        var edgeFound = false
        var bounced = false

        func percentile(_ values: [Double], _ p: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
        }
        var line: String {
            func pct(_ v: Double) -> String { String(format: "%5.1f%%", v * 100) }
            return String(format: "%-34@ blank p50 %@ p95 %@ max %@ | track p95 %5.1f px | misplaced %4.1f px | resp %d | settle %4.0f ms | final %4.1f px | jump %4.1f px | lead %5.0f px | L %3.0f ms g %.2f",
                          name as NSString, pct(percentile(blank, 0.5)), pct(percentile(blank, 0.95)), pct(blank.max() ?? 0),
                          percentile(trackingError, 0.95), misplacement, responseRefreshes, settleTime * 1000, finalError,
                          handoffJump, appLeadMax, learnedLatency * 1000, learnedGain)
        }
    }

    let app: App
    let gestures: [Gesture]
    let lines = 2556, span = 1179, header = 330
    let scale = 3.0
    var duration: TimeInterval = 4

    init(app: App, gestures: [Gesture], duration: TimeInterval = 4) {
        self.app = app; self.gestures = gestures; self.duration = duration
    }

    // MARK: Synthetic page

    private static func hash(_ a: Int, _ b: Int, _ c: Int) -> UInt64 {
        var x = UInt64(bitPattern: Int64(a)) &* 0x9E37_79B9_7F4A_7C15
        x ^= UInt64(bitPattern: Int64(b)) &* 0xC2B2_AE3D_27D4_EB4F
        x ^= UInt64(bitPattern: Int64(c)) &* 0x1656_67B1_9E37_79F9
        x ^= x >> 31; x &*= 0xBF58_476D_1CE4_E5B9; x ^= x >> 29
        return x
    }
    private static func unit(_ a: Int, _ b: Int, _ c: Int) -> Float { Float(hash(a, b, c) % 10_000) / 10_000 }

    /// The page's (luma, detail) at content line `row` in `band`: paragraphs of text lines,
    /// paragraph gaps, and images.
    private func page(_ row: Int, _ band: Int, bands: Int) -> (Float, Float) {
        guard row >= 0, row < app.pageLines else { return (255, 0) }
        let block = row / 900, within = row % 900
        if Self.hash(block, 0, 7) % 4 == 0 && within < 600 {
            // An image: smooth rows with texture.
            let base = 60 + 120 * Self.unit(block, band, 1)
            return (base + 40 * sin(Float(row) * 0.05 + Float(band)), 6 + 10 * Self.unit(row / 3, band, 2))
        }
        let line = within / 36, glyphRow = within % 36
        if within >= 840 || glyphRow < 8 || glyphRow >= 30 { return (255, 0) }
        // The last line of a paragraph is shorter.
        let length = line % 7 == 6 ? Int(Self.hash(block, line, 3) % UInt64(bands)) : bands
        guard band < length else { return (255, 0) }
        let ink = Self.unit(row, band, 4)
        return (200 + 45 * ink, 15 + 45 * Self.unit(row, band, 5))
    }

    private func fixedCell(_ line: Int, _ band: Int, kind: Int) -> (Float, Float) {
        // Toolbars and sidebars: their own detail, never moving.
        if line % 24 < 4 { return (120, 0) }
        return (180 + 50 * Self.unit(line, band, 10 + kind), 10 + 30 * Self.unit(line, band, 20 + kind))
    }

    func signature(offset: Int, seed: Int) -> ScrollSignature {
        let bands = ScrollSignature.bandCount(span: span)
        var luma = [Float](repeating: 0, count: lines * bands), detail = luma
        let sidebarBands = app.sidebar * bands / span
        for line in 0..<lines {
            for band in 0..<bands {
                var cell: (Float, Float)
                if line < header { cell = fixedCell(line, band, kind: 0) }
                else if line >= lines - app.footer { cell = fixedCell(line, band, kind: 1) }
                else if band < sidebarBands { cell = fixedCell(line, band, kind: 2) }
                else { cell = page(offset + line, band, bands: bands) }
                let n1 = (Self.unit(seed, line, band) - 0.5) * 2 * app.noise
                let n2 = (Self.unit(seed, band, line) - 0.5) * 2 * app.noise
                luma[line * bands + band] = cell.0 + n1
                detail[line * bands + band] = max(0, cell.1 + n2)
            }
        }
        var color = [Float](repeating: 0, count: lines * bands * 3)
        for (i, l) in luma.enumerated() { color[i * 3] = l; color[i * 3 + 1] = l; color[i * 3 + 2] = l }
        return ScrollSignature(axis: .vertical, lines: lines, bands: bands, span: span, luma: luma, detail: detail, color: color)
    }

    // MARK: Run

    /// Metrics count from `measureFrom`; earlier gestures warm the window up (its region,
    /// latency and gain become known), as any window the user has scrolled before.
    func run(name: String, configuration: LocalScroll.Configuration = .init(), model initial: LocalScroll? = nil,
             measureFrom: TimeInterval = -1, trace: Bool = false) -> (Report, LocalScroll) {
        var report = Report(name: name)
        var model = initial ?? LocalScroll(configuration: configuration)
        let estimator = ScrollMotionEstimator()
        let tick = 1.0 / 120
        let maxOffset = Double(app.pageLines - (lines - header - app.footer))
        var appOffset = app.startOffset
        var inbound: [(time: TimeInterval, wire: Double)] = []
        var outbound: [(time: TimeInterval, id: UInt64, offset: Int)] = []
        var nextRender = 0.0
        var nextID: UInt64 = 1
        var frameOffsets: [UInt64: Int] = [:]
        var signatures: [UInt64: ScrollSignature] = [:]
        var previousSignature: (id: UInt64, signature: ScrollSignature)?
        var pendingMeasure: [(id: UInt64, hint: (range: ClosedRange<Int>, center: Int))] = []
        var reference = 0.0 // the native iOS trajectory of the same gesture, in pixels
        var referencePhysics = ScrollPhysics()
        var gestureIndex = 0
        var sampleIndex = 0
        var lastPosition: Double?
        var firstMove: TimeInterval?
        var lastRelease: TimeInterval = 0
        var lastMotion: TimeInterval = 0
        var wasActive = false
        var lastShown: Double?
        var restSince: TimeInterval?
        var lastComposing = false
        var lastReference = 0.0
        var newestArrived: UInt64 = 0
        var hitchUntil = -1.0

        // The window's first picture, at rest.
        func render(at time: TimeInterval) {
            let id = nextID; nextID += 1
            let offset = Int(appOffset.rounded())
            frameOffsets[id] = offset
            outbound.append((time + app.outputDelay, id, offset))
        }
        render(at: -0.5)
        var t = -0.4
        while t < duration {
            t += tick
            // App: input arrives, frames render.
            while let first = inbound.first, first.time <= t {
                inbound.removeFirst()
                appOffset = min(maxOffset, max(0, appOffset + first.wire * app.gain))
            }
            if let hitch = app.hitch, t > 0, t.truncatingRemainder(dividingBy: hitch.every) < tick { hitchUntil = t + hitch.duration }
            if t >= nextRender, t >= hitchUntil {
                render(at: t)
                let jitter = (Double(Self.unit(Int(t * 1000), 1, 2)) - 0.5) * 2 * app.jitter
                nextRender = t + 1 / app.fps + jitter
            }
            // Phone: pictures arrive and are measured (results land on the next refresh).
            for job in pendingMeasure {
                let signature = signatures[job.id]!
                let observation: ScrollObservation
                if let previous = previousSignature {
                    switch estimator.measure(from: previous.signature, to: signature, expected: job.hint.range, center: job.hint.center, anchor: nil) {
                    case .moved(let motion):
                        observation = .moved(shift: motion.shift, region: ScrollRegion(along: motion.lines, across: signature.pixels(of: motion.bands)), reference: previous.id)
                    case .still: observation = .still(reference: previous.id)
                    case .unexplained: observation = .unrelated
                    }
                } else {
                    observation = .unrelated
                }
                previousSignature = (job.id, signature)
                model.observe(job.id, observation)
                if trace {
                    let placed = model.debugOffset(job.id)
                    print(String(format: "t=%.3f frame %d true %d placed %@ obs %@ L=%.0fms", t, Int(job.id), frameOffsets[job.id]! - Int(app.startOffset),
                                 placed.map { String(format: "%.1f", $0) } ?? "nil", "\(observation)".prefix(60) as CVarArg, model.latency * 1000))
                }
            }
            pendingMeasure.removeAll()
            while let first = outbound.first, first.time <= t {
                outbound.removeFirst()
                signatures[first.id] = signature(offset: first.offset, seed: Int(first.id))
                newestArrived = first.id
                let hint = model.captured(first.id, at: t)
                pendingMeasure.append((first.id, hint))
            }
            // Finger.
            if gestureIndex < gestures.count {
                let gesture = gestures[gestureIndex]
                if sampleIndex == 0, t >= gesture.start {
                    let first = gesture.samples[0]
                    model.halt(at: t)
                    referencePhysics.begin(at: gesture.start)
                    model.begin(at: gesture.start, axis: .vertical, anchor: CGPoint(x: 700, y: 1500), scale: CGSize(width: scale, height: scale))
                    // UIKit recognizes the pan with its first movement already made.
                    model.track(CGPoint(x: 0, y: first.position), at: first.time)
                    referencePhysics.append(CGPoint(x: 0, y: first.position), at: first.time)
                    if firstMove == nil, t >= measureFrom { firstMove = t }
                    sampleIndex = 1
                }
                while sampleIndex > 0, sampleIndex < gesture.samples.count, gesture.samples[sampleIndex].time <= t {
                    let a = gesture.samples[sampleIndex - 1], b = gesture.samples[sampleIndex]
                    model.track(CGPoint(x: 0, y: b.position - a.position), at: b.time)
                    referencePhysics.append(CGPoint(x: 0, y: b.position - a.position), at: b.time)
                    sampleIndex += 1
                }
                if sampleIndex >= gesture.samples.count, t >= gesture.release {
                    let velocity = CGPoint(x: 0, y: gesture.releaseVelocity)
                    model.release(at: t, velocity: velocity)
                    referencePhysics.end(at: t, velocity: velocity)
                    lastRelease = t
                    gestureIndex += 1
                    sampleIndex = 0
                }
            }
            // Refresh.
            let result = model.tick(at: t)
            reference += Double(referencePhysics.frame(elapsed: tick).y) * scale
            if result.send.y != 0 { inbound.append((t + app.inputDelay, Double(result.send.y))) }
            // Model coordinates start at zero where the app started.
            let phone = model.position + app.startOffset
            let shown: Double
            let measuring = t >= measureFrom
            if let composition = result.composition {
                if measuring { report.blank.append(Double(composition.blank) / Double(composition.region.along.count)) }
                for layer in composition.layers where measuring {
                    report.misplacement = max(report.misplacement, abs(phone - (Double(frameOffsets[layer.frame]!) - Double(layer.shift))))
                }
                shown = composition.layers.last.map { Double(frameOffsets[$0.frame]!) - Double($0.shift) } ?? phone
            } else {
                if model.isActive, measuring { report.blank.append(0) }
                shown = Double(frameOffsets[newestArrived] ?? Int(app.startOffset))
            }
            // On-screen discontinuity: the shown content against the motion it should have made,
            // the phone's own while it composes, the gesture's when the app's picture shows.
            let composing = result.composition != nil
            if measuring, model.isActive || wasActive, let previous = lastShown, let last = lastPosition {
                let expected = composing && lastComposing ? model.position - last : reference - lastReference
                report.handoffJump = max(report.handoffJump, abs((shown - previous) - expected))
            }
            lastComposing = composing
            lastReference = reference
            if model.isActive, measuring, model.phase != .prefetching {
                report.appLeadMax = max(report.appLeadMax, appOffset - phone)
                if model.edges == (nil, nil) { report.trackingError.append(abs(model.position - reference)) }
            }
            if measuring, let last = lastPosition, abs(model.position - last) > 0.01, report.responseRefreshes == .max, let first = firstMove {
                report.responseRefreshes = Int(((t - first) / tick).rounded())
            }
            if model.isActive, let last = lastPosition, abs(model.position - last) > 0.01 { lastMotion = t }
            if wasActive, !model.isActive, gestureIndex >= gestures.count { report.settleTime = t - lastMotion }
            if trace, (model.isActive || wasActive), t < 2.2 {
                print(String(format: "  tick %.3f phase %@ pos %.0f cmd %.0f app %.0f placed %@ blank %d", t, "\(model.phase)", model.position, model.commanded,
                             appOffset - app.startOffset, model.placedOffset.map { String(format: "%.0f", $0) } ?? "nil", result.composition?.blank ?? -1))
            }
            lastPosition = model.position
            lastShown = shown
            wasActive = model.isActive
            if model.edges != (nil, nil) { report.edgeFound = true }
            if model.phase == .bouncing { report.bounced = true }
            // Done once every gesture is over and the phone has handed back and stays so.
            if gestureIndex >= gestures.count, !model.isActive { restSince = restSince ?? t } else { restSince = nil }
            if let since = restSince, t - since > 0.3 { break }
        }
        report.finalError = abs(model.position + app.startOffset - appOffset)
        report.learnedLatency = model.latency
        report.learnedGain = model.gain
        return (report, model)
    }
}
