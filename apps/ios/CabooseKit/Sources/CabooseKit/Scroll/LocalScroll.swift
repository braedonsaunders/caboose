import Foundation

/// Where scrolling content sits in a window's picture, in picture pixels.
public struct ScrollRegion: Equatable, Sendable {
    /// Pixels along the scroll axis.
    public var along: Range<Int>
    /// Pixels across it.
    public var across: Range<Int>

    public init(along: Range<Int>, across: Range<Int>) { self.along = along; self.across = across }

    public func contains(along a: Double, across c: Double) -> Bool {
        Double(along.lowerBound) <= a && a < Double(along.upperBound)
            && Double(across.lowerBound) <= c && c < Double(across.upperBound)
    }
}

/// What is known about a captured frame's content position.
public enum ScrollObservation: Equatable, Sendable {
    /// Its relation to earlier frames is unknown: the first frame of a track, a new page,
    /// a jump beyond what measurement searched.
    case unrelated
    /// Its content moved `shift` pixels forward relative to frame `reference`, within `region`.
    case moved(shift: Int, region: ScrollRegion, reference: UInt64)
    /// Nothing moved relative to frame `reference`.
    case still(reference: UInt64)
    /// A toolkit adapter's authoritative report for this exact frame: the scroll layer's
    /// content offset, the region it occupies, its scroll range when known, and fixed
    /// rectangles inside the region (overlays, scroll bars) that do not move with it. It
    /// replaces measurement for the frame it describes.
    case reported(offset: Double, region: ScrollRegion, bounds: ClosedRange<Double>? = nil, stationary: [ScrollRegion] = [])
}

/// One picture of what the phone shows while it owns a window's scrolling.
public struct ScrollComposition: Equatable, Sendable {
    public struct Layer: Equatable, Sendable {
        /// The captured frame drawn.
        public var frame: UInt64
        /// Its pixels move this far along the axis: picture line `y` shows at `y + shift`.
        public var shift: Int
        /// The lines it covers once moved, within the region.
        public var lines: Range<Int>
    }
    public var axis: ScrollAxis
    /// The newest placed frame, drawn unmoved: everything outside `region` comes from it.
    public var base: UInt64
    public var region: ScrollRegion
    /// Drawn in order, later layers over earlier ones, clipped to `region`.
    public var layers: [Layer]
    /// Region lines no captured frame covers; they show `fillFrom`'s edge colour.
    public var blank: Int
    /// The frame and lines whose mean colour fills the blank, the content nearest it.
    public var fillFrom: (frame: UInt64, lines: Range<Int>)?
    /// Fixed rectangles inside the region, drawn from `base` unmoved over the layers.
    public var stationary: [ScrollRegion] = []

    public static func == (a: ScrollComposition, b: ScrollComposition) -> Bool {
        a.axis == b.axis && a.base == b.base && a.region == b.region && a.layers == b.layers && a.blank == b.blank
            && a.fillFrom?.frame == b.fillFrom?.frame && a.fillFrom?.lines == b.fillFrom?.lines && a.stationary == b.stationary
    }
}

/// The result of one display refresh.
public struct ScrollTick: Equatable, Sendable {
    /// Scroll to forward to the app now, in picture pixels, content direction.
    public var send: CGPoint
    /// The content offset the app is driven to, in the toolkit adapter's coordinates, while
    /// frames are placed by its reports; nil otherwise.
    public var target: Double? = nil
    /// What to show, or nil to show the app's picture as it is.
    public var composition: ScrollComposition?
    /// The scroll still moves, settles or waits for the app: keep refreshing.
    public var isActive: Bool
}

/// Phone-owned scrolling of one window, independent of UIKit and Metal so the same code runs
/// on the device and in the replay harness.
///
/// The phone owns the scroll position: touch and iOS momentum move it at display rate, and
/// the phone shows the window's captured pictures moved to it. The app is driven toward
/// where the phone will be once its pictures arrive: the position `latency` ahead, exact
/// during momentum, extrapolated from finger velocity while tracking. That keeps the app's
/// newest picture at or ahead of the phone, so the content coming into view already exists;
/// the earlier pictures cover the content behind it.
///
/// Each captured picture is placed by measurement (`ScrollMotionEstimator`) or a toolkit
/// adapter's report. Placements teach the app's latency and its response to scroll input
/// (`gain`), so any toolkit follows the finger one to one. When the app stops moving while
/// it is still driven, its content ended: the phone records the edge and resists or bounces
/// as iOS does. When the phone stops, the app is brought to the same position and the
/// phone hands presentation back to the app's own picture.
public struct LocalScroll {
    public struct Configuration: Sendable {
        /// Input-to-picture latency assumed before any is measured.
        public var initialLatency: TimeInterval = 0.1
        public var latencyRange: ClosedRange<TimeInterval> = 0.016...0.6
        /// Longest extrapolation of a moving finger.
        public var trackingLead: TimeInterval = 0.15
        /// Captured frames kept for drawing, newest included.
        public var historyLimit = 6
        /// Most of the region, as a fraction, that may show content not yet captured. The
        /// shown position resists beyond it and catches up as pictures arrive.
        public var revealLimit = 0.25
        /// How long the app may stop answering motion before its content is taken to end.
        public var edgeGrace: TimeInterval = 0.12
        /// Correction rounds before the phone eases onto the app's own position.
        public var corrections = 3
        /// How long the app keeps its lead after a finger stops the content.
        public var haltHold: TimeInterval = 0.2
        /// After a scroll comes to rest, the phone briefly drives the app one region further
        /// in the scroll's direction and back, behind the unchanged picture, so the content a
        /// next flick reveals first already exists on the phone. Zero turns it off.
        public var prefetch = 0.7
        /// While content moves fast, the app is driven this fraction of the region further ahead
        /// than the phone will be, fading with speed below `motionLeadSpeed` picture pixels per
        /// second, so a harder flick on top of a moving one still finds its content captured.
        public var motionLead = 0.5
        public var motionLeadSpeed = 1500.0
        /// Rest before prefetching, so a quick next flick is not raced.
        public var prefetchDelay: TimeInterval = 0.1
        public init() {}
    }

    public enum Phase: Equatable, Sendable { case idle, tracking, coasting, bouncing, settling, prefetching }

    struct Frame {
        let id: UInt64
        let time: TimeInterval
        var offset: Double?
        var region: ScrollRegion?
        var placed: Bool { offset != nil }
    }

    public let configuration: Configuration
    public private(set) var phase: Phase = .idle
    public private(set) var axis: ScrollAxis = .vertical
    /// Picture pixels per view point along and across the axis.
    private var scale: CGSize?
    private var physics = ScrollPhysics()
    /// The position the gesture asks for, before edges and the reveal limit.
    private var requested = 0.0
    /// The position the gesture asks for after edges, before the reveal limit.
    private var wanted = 0.0
    /// The position shown.
    public private(set) var position = 0.0
    /// Where the app is expected to be once everything sent has applied.
    public private(set) var commanded = 0.0
    private var commandedHistory: [(time: TimeInterval, value: Double)] = []
    private var spring: ScrollSpring?
    private var springTarget = 0.0
    private var lastTick: TimeInterval?
    private var lastSend: TimeInterval = -.infinity
    private var frames: [Frame] = []
    public private(set) var region: ScrollRegion?
    private var anchor: (along: Double, across: Double)?
    public private(set) var edges: (lower: Double?, upper: Double?) = (nil, nil)
    /// The app's response to forwarded scroll: content pixels per pixel sent.
    public private(set) var gain = 1.0
    public private(set) var latency: TimeInterval
    private var latencySamples: [TimeInterval] = []
    private var lastAppMotion: TimeInterval = -.infinity
    private var unansweredSince: TimeInterval?
    /// Where the content was when the current run of gestures began, for the prefetch direction.
    private var travelStart: Double?
    /// Scroll sent and the app's position at a moment nothing was in flight: the baseline the
    /// app's gain is measured against once it is at rest again.
    private var gainBaseline: (sent: Double, offset: Double)?
    private var sent = 0.0
    private var correctionsLeft = 0
    private var reportedBias: Double?
    /// Fixed rectangles inside the region, from a toolkit adapter.
    public private(set) var stationary: [ScrollRegion] = []
    public private(set) var interrupted = false
    private var composing = false
    /// After a finger stops the content, the app keeps its lead this long in case the finger
    /// flicks on in the same direction.
    private var holdUntil: TimeInterval = -.infinity
    private struct Prefetch {
        var pinned: UInt64
        var origin: Double
        var target: Double
        var returning = false
        var deadline: TimeInterval
    }
    private var prefetch: Prefetch?
    private var prefetchAt: (time: TimeInterval, direction: Double)?

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
        latency = configuration.initialLatency
    }

    func debugOffset(_ id: UInt64) -> Double? { frames.first { $0.id == id }?.offset }

    /// The newest frame with a known position.
    public var placedOffset: Double? { frames.last(where: \.placed)?.offset }
    /// Captured frames still worth keeping for drawing.
    public var retainedFrames: [UInt64] { frames.map(\.id) }
    public var isActive: Bool { phase != .idle }
    /// Whether a tap now only stops the scroll, as on iOS, instead of clicking.
    public var isMoving: Bool {
        phase == .coasting || phase == .bouncing || (phase == .tracking && abs(axisVelocity) > 60 * scaleAlong)
    }

    private var scaleAlong: Double { Double(scale.map { axis == .vertical ? $0.height : $0.width } ?? 1) }
    private var scaleAcross: Double { Double(scale.map { axis == .vertical ? $0.width : $0.height } ?? 1) }
    private var axisVelocity: Double { Double(axis.component(physics.velocity)) * scaleAlong }
    private var regionLength: Double { Double(region.map { $0.along.count } ?? 0) }
    /// The extra lead for fast motion, signed in its direction.
    private var motionLead: Double {
        let v = axisVelocity, speed = abs(v)
        guard speed > 0, configuration.motionLeadSpeed > 0 else { return 0 }
        return (v > 0 ? 1 : -1) * configuration.motionLead * regionLength * min(1, speed / configuration.motionLeadSpeed)
    }

    // MARK: Gesture

    /// A pan began: `delta` is its first movement in view points (content direction),
    /// `anchor` the picture pixel under it, `scale` picture pixels per point.
    public mutating func begin(at time: TimeInterval, axis requestedAxis: ScrollAxis, anchor point: CGPoint, scale: CGSize) {
        let fromRest = phase == .idle
        if fromRest || phase == .prefetching { travelStart = prefetch?.origin ?? placedOffset ?? position }
        // Only a start from rest knows what the app had applied of everything sent.
        gainBaseline = fromRest && !frames.contains(where: { !$0.placed }) ? (sent, placedOffset ?? position) : nil
        // Frames measured along another axis or at another mapping cannot be reused.
        if requestedAxis != axis || (self.scale.map { $0 != scale } ?? false) { resetTrack() }
        axis = requestedAxis
        self.scale = scale
        prefetchAt = nil
        if let p = prefetch { position = p.origin; requested = p.origin; wanted = p.origin; prefetch = nil }
        halt(at: time)
        anchor = (Double(axis.component(point)), Double(axis == .vertical ? point.x : point.y))
        if let region, let anchor, !region.contains(along: anchor.along, across: anchor.across) { self.region = nil }
        physics.begin(at: time)
        phase = .tracking
        correctionsLeft = configuration.corrections
        interrupted = false
    }

    public mutating func track(_ delta: CGPoint, at time: TimeInterval) {
        guard phase == .tracking else { return }
        physics.append(delta, at: time)
    }

    /// The finger lifted: `velocity` is UIKit's release velocity in points per second,
    /// content direction. `coast` is false for hardware scrolling, which has its own.
    public mutating func release(at time: TimeInterval, velocity: CGPoint?, coast: Bool = true) {
        guard phase == .tracking else { return }
        physics.end(at: time, velocity: velocity, coast: coast)
        if let edge = edge(beyond: requested) {
            // Released past the end: spring back from where the content shows.
            startSpring(from: position, to: edge, velocity: 0)
        } else {
            phase = physics.isCoasting ? .coasting : .settling
        }
    }

    /// A finger touched down: the content stops where it shows, as a scroll view does.
    public mutating func halt(at time: TimeInterval? = nil) {
        if phase == .coasting || phase == .tracking, let time { holdUntil = time + configuration.haltHold }
        physics.cancel()
        spring = nil
        requested = position
        wanted = position
        if phase != .idle { phase = .settling }
    }

    /// Other input reached the window (a tap, a key): a prefetch returns the app at once and
    /// none is started until the next scroll.
    public mutating func interrupt() {
        prefetchAt = nil
        if var p = prefetch { p.returning = true; prefetch = p }
    }

    /// The window, its geometry or the connection changed: forget the gesture, the
    /// captured frames and what was learned about the content.
    public mutating func cancel() {
        resetTrack()
        phase = .idle
    }

    private mutating func resetTrack() {
        physics.cancel()
        spring = nil
        frames.removeAll()
        prefetch = nil
        prefetchAt = nil
        region = nil
        edges = (nil, nil)
        requested = 0; wanted = 0; position = 0; commanded = 0; sent = 0
        commandedHistory.removeAll()
        travelStart = nil
        gainBaseline = nil
        reportedBias = nil
        stationary = []
        unansweredSince = nil
        lastAppMotion = -.infinity
        lastTick = nil
    }

    // MARK: Frames

    /// A new picture of the window was captured. Returns the shifts worth searching when
    /// measuring it against the previous capture, and the most likely one.
    public mutating func captured(_ id: UInt64, at time: TimeInterval) -> (range: ClosedRange<Int>, center: Int) {
        let previous = frames.last?.offset ?? position
        frames.append(Frame(id: id, time: time, offset: nil, region: nil))
        // The app can be anywhere it was commanded to over the input still in flight.
        var lowest = commanded, highest = commanded
        let since = time - 2 * latency - 0.1
        for entry in commandedHistory.reversed() {
            if entry.time < since { break }
            lowest = min(lowest, entry.value); highest = max(highest, entry.value)
        }
        let margin = 64 + 0.25 * (highest - lowest)
        let low = Int((min(0, lowest - previous) - margin).rounded(.down))
        let high = Int((max(0, highest - previous) + margin).rounded(.up))
        // The app has applied about what was sent `latency` ago.
        let center = Int((value(at: time - latency, in: commandedHistory) ?? commanded) - previous)
        return (low...high, max(low, min(high, center)))
    }

    /// Places a captured frame. Frames are placed in capture order.
    public mutating func observe(_ id: UInt64, _ observation: ScrollObservation) {
        guard let index = frames.firstIndex(where: { $0.id == id }) else { return }
        let frame = frames[index]
        let before = frames[..<index].last(where: \.placed)
        var offset: Double
        var region: ScrollRegion?
        switch observation {
        case .unrelated:
            if before == nil {
                offset = phase == .idle ? position : (value(at: frame.time - latency, in: commandedHistory) ?? commanded)
            } else {
                offset = value(at: frame.time - latency, in: commandedHistory) ?? commanded
                // Earlier frames cannot be related to this one.
                frames.removeSubrange(..<index)
                edges = (nil, nil)
            }
            region = self.region
        case .moved(let shift, let measured, let reference):
            stationary = []
            guard let base = frames.first(where: { $0.id == reference })?.offset ?? before?.offset else {
                return observe(id, .unrelated)
            }
            offset = base + Double(shift)
            region = measured
        case .still(let reference):
            guard let ref = frames.first(where: { $0.id == reference }) ?? before, let base = ref.offset else {
                return observe(id, .unrelated)
            }
            offset = base
            region = ref.region ?? self.region
        case .reported(let reported, let measured, let bounds, let fixed):
            if reportedBias == nil {
                reportedBias = (before == nil ? position : (value(at: frame.time - latency, in: commandedHistory) ?? commanded)) - reported
            }
            let bias = reportedBias!
            offset = reported + bias
            region = measured
            stationary = fixed
            if let bounds { edges = (bounds.lowerBound + bias, bounds.upperBound + bias) }
        }
        guard let i = frames.firstIndex(where: { $0.id == id }) else { return }
        frames[i].offset = offset
        frames[i].region = region
        if let region { self.region = region }
        learn(from: frames[i], previous: before)
        if phase == .idle {
            // At rest the app's picture is shown as it is: the phone is where the app is.
            position = offset; requested = offset; wanted = offset; commanded = offset
        }
        prune()
    }

    private mutating func learn(from frame: Frame, previous: Frame?) {
        guard let offset = frame.offset else { return }
        guard let previousOffset = previous?.offset else { lastAppMotion = frame.time; return }
        if abs(offset - previousOffset) >= 1 {
            lastAppMotion = frame.time
            unansweredSince = nil
            // Latency: when was the app expected where this picture shows it?
            if phase != .idle, let sentAt = time(when: offset, movingFrom: previousOffset) {
                let sample = frame.time - sentAt
                if configuration.latencyRange.contains(sample) {
                    latencySamples.append(sample)
                    if latencySamples.count > 9 { latencySamples.removeFirst() }
                    let sorted = latencySamples.sorted()
                    latency = sorted[min(sorted.count - 1, sorted.count * 3 / 4)]
                }
            }
        }
    }

    /// Keeps the newest frame, then greedily the frames that add the most content near the
    /// phone's and the app's positions, up to `historyLimit`.
    private mutating func prune() {
        guard let newest = frames.last(where: \.placed), let newestOffset = newest.offset,
              let region = newest.region ?? self.region else { return }
        let length = Double(region.along.count)
        let low = min(position, newestOffset) + Double(region.along.lowerBound) - 2 * length
        let high = max(position, newestOffset) + Double(region.along.upperBound) + length
        func span(_ frame: Frame) -> Range<Double>? {
            guard let offset = frame.offset, let own = frame.region ?? self.region else { return nil }
            let lower = max(low, offset + Double(own.along.lowerBound)), upper = min(high, offset + Double(own.along.upperBound))
            return lower < upper ? lower..<upper : nil
        }
        var keep: Set<UInt64> = [newest.id]
        var covered = span(newest).map { [$0] } ?? []
        if let pinned = prefetch?.pinned { keep.insert(pinned); if let f = frames.first(where: { $0.id == pinned }), let r = span(f) { covered.append(r) } }
        var candidates = frames.filter { $0.placed && !keep.contains($0.id) }
        while keep.count < configuration.historyLimit, !candidates.isEmpty {
            let scored = candidates.map { frame in (frame, span(frame).map { Self.uncovered($0, by: covered) } ?? 0) }
            guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= 16 else { break }
            keep.insert(best.0.id)
            if let r = span(best.0) { covered.append(r) }
            candidates.removeAll { $0.id == best.0.id }
        }
        frames.removeAll { $0.placed && !keep.contains($0.id) }
    }

    private static func uncovered(_ range: Range<Double>, by covered: [Range<Double>]) -> Double {
        var pieces = [range]
        for c in covered {
            pieces = pieces.flatMap { piece -> [Range<Double>] in
                guard piece.overlaps(c) else { return [piece] }
                var result: [Range<Double>] = []
                if piece.lowerBound < c.lowerBound { result.append(piece.lowerBound..<c.lowerBound) }
                if c.upperBound < piece.upperBound { result.append(c.upperBound..<piece.upperBound) }
                return result
            }
        }
        return pieces.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    // MARK: Refresh

    /// Advances to the display refresh at `time` and says what to send and show.
    public mutating func tick(at time: TimeInterval) -> ScrollTick {
        let elapsed = max(0, min(0.1, time - (lastTick ?? time)))
        lastTick = time
        if phase == .idle {
            composing = false
            guard let scheduled = prefetchAt, time >= scheduled.time else {
                return ScrollTick(send: .zero, composition: nil, isActive: prefetchAt != nil)
            }
            // A picture still being measured is waited for.
            if !frames.contains(where: { !$0.placed }) {
                prefetchAt = nil
                startPrefetch(direction: scheduled.direction, at: time)
            }
            guard phase == .prefetching else { return ScrollTick(send: .zero, composition: nil, isActive: false) }
        }
        // Until the first composition the app's own picture is on screen: the phone takes over
        // from where that picture shows the content and catches up with the gesture.
        let composable = region != nil && placedOffset != nil
        if composable, !composing, let shown = placedOffset { position = shown }
        composing = composable

        // 1. Move: finger and momentum along the axis; across it, scroll passes straight through.
        let movement = physics.frame(elapsed: elapsed)
        let along = Double(axis.component(movement)) * scaleAlong
        let acrossValue = Double(axis == .vertical ? movement.x : movement.y) * scaleAcross
        let previousWanted = wanted
        switch phase {
        case .tracking:
            requested += along
            wanted = constrained(requested)
        case .coasting:
            requested += along
            if let edge = edge(beyond: requested) {
                startSpring(from: wanted, to: edge, velocity: axisVelocity)
            } else {
                wanted = requested
                if !physics.isCoasting { phase = .settling }
            }
        case .bouncing:
            if var s = spring {
                s.advance(elapsed)
                spring = s
                wanted = springTarget + s.offset
                requested = wanted
                if s.isSettled { spring = nil; wanted = springTarget; requested = wanted; phase = .settling }
            }
        case .settling, .idle, .prefetching:
            break
        }
        position = revealLimited(wanted, previousWanted: previousWanted, elapsed: elapsed)

        // 2. Drive the app toward where the phone will be when its picture arrives.
        var target: Double
        switch phase {
        case .tracking:
            let lead = axisVelocity * min(latency, configuration.trackingLead)
            target = clampToEdges(requested + lead + motionLead)
        case .coasting:
            target = clampToEdges(requested + Double(axis.component(physics.projectedDistance(over: latency))) * scaleAlong + motionLead)
        case .prefetching:
            target = clampToEdges(prefetch.map { $0.returning ? $0.origin : $0.target } ?? position)
        default:
            target = time < holdUntil && phase == .settling ? commanded
                : clampToEdges(phase == .bouncing ? springTarget : position)
        }
        var send = CGPoint.zero
        let change = target - commanded
        if abs(change) >= 0.01 {
            commanded = target
            let wire = change / gain
            sent += wire
            lastSend = time
            if unansweredSince == nil { unansweredSince = time }
            send = axis.point(along: CGFloat(wire))
        }
        commandedHistory.append((time, commanded))
        if commandedHistory.count > 240 { commandedHistory.removeFirst(commandedHistory.count - 240) }
        if acrossValue != 0 {
            if axis == .vertical { send.x += CGFloat(acrossValue) } else { send.y += CGFloat(acrossValue) }
        }

        // 3. The app stopped answering: its content ends where it stopped.
        detectEdge(at: time)

        // 4. At rest, bring the app here, then hand the picture back to it.
        if phase == .settling { settle(at: time) }
        if phase == .prefetching { advancePrefetch(at: time) }

        let composition = phase == .idle ? nil : compose()
        return ScrollTick(send: send, target: reportedBias.map { commanded - $0 },
                          composition: composition, isActive: phase != .idle)
    }

    private mutating func detectEdge(at time: TimeInterval) {
        guard let app = placedOffset, let since = unansweredSince, phase != .idle else { return }
        let ahead = commanded - app
        guard abs(ahead) > 24 else { return }
        let grace = 2 * latency + configuration.edgeGrace
        guard time - max(since, lastAppMotion) > grace else { return }
        if ahead > 0 { edges.upper = app } else { edges.lower = app }
        commanded = app
        unansweredSince = nil
        switch phase {
        case .coasting:
            startSpring(from: position, to: app, velocity: axisVelocity)
        case .settling:
            if abs(position - app) > 0.5 { startSpring(from: position, to: app, velocity: 0) }
        default:
            break
        }
    }

    private mutating func settle(at time: TimeInterval) {
        guard let app = placedOffset else {
            // Nothing to show the phone's position with: let the app's picture stand.
            phase = .idle
            return
        }
        let pending = frames.contains { !$0.placed }
        if abs(app - position) < 0.5 && abs(commanded - position) < 0.5 && !pending {
            let travelled = app - (travelStart ?? app)
            learnGain(app: app)
            position = app; requested = app; wanted = app; commanded = app
            phase = .idle
            if configuration.prefetch > 0, abs(travelled) >= 1 {
                prefetchAt = (time + configuration.prefetchDelay, travelled > 0 ? 1 : -1)
            }
            return
        }
        // Wait for what was sent to land before judging the app's position.
        guard time - lastSend > 2 * latency + 0.05, time - (frames.last?.time ?? -.infinity) > 0.05 || !pending else { return }
        learnGain(app: app)
        commanded = app
        if correctionsLeft > 0, abs(app - position) >= 0.5 {
            correctionsLeft -= 1
            // The next refresh sends the difference at the newly learned gain.
            unansweredSince = nil
        } else if abs(app - position) >= 0.5 {
            // The app will not reach the phone's position: ease the phone onto the app's.
            startSpring(from: position, to: app, velocity: 0, stiffness: 14)
        }
    }

    private mutating func startPrefetch(direction: Double, at time: TimeInterval) {
        guard let region, let base = frames.last(where: \.placed), let offset = base.offset,
              abs(offset - position) < 0.5 else { return }
        var distance = configuration.prefetch * Double(region.along.count) * direction
        if let upper = edges.upper, direction > 0 { distance = min(distance, upper - position) }
        if let lower = edges.lower, direction < 0 { distance = max(distance, lower - position) }
        // Content already captured there needs no visit.
        if let span = coverage() {
            let reach = position + Double(direction > 0 ? region.along.upperBound : region.along.lowerBound) + distance
            if span.contains(reach) { return }
        }
        guard abs(distance) >= 32 else { return }
        prefetch = Prefetch(pinned: base.id, origin: position, target: position + distance,
                            deadline: time + 4 * latency + 0.25)
        gainBaseline = (sent, offset)
        phase = .prefetching
    }

    private mutating func advancePrefetch(at time: TimeInterval) {
        guard var p = prefetch, let app = placedOffset else { phase = .idle; prefetch = nil; return }
        if !p.returning, abs(app - p.target) < 1 || time > p.deadline || edges.upper.map({ app >= $0 }) == true
            || edges.lower.map({ app <= $0 }) == true {
            p.returning = true
            p.deadline = time + 4 * latency + 0.25
        } else if p.returning, abs(app - p.origin) < 0.5, !frames.contains(where: { !$0.placed }) {
            prefetch = nil
            phase = .idle
            return
        } else if p.returning, time > p.deadline {
            // The app did not come back: the phone follows it, as after any correction.
            prefetch = nil
            phase = .settling
            correctionsLeft = configuration.corrections
            return
        }
        prefetch = p
    }

    private mutating func learnGain(app: Double) {
        guard let start = gainBaseline else { return }
        let wire = sent - start.sent, moved = app - start.offset
        guard abs(wire) >= 96, abs(moved) >= 48, moved * wire > 0, edges == (nil, nil) || abs(moved) > abs(wire) * 0.25 else { return }
        gain = min(4, max(0.25, moved / wire))
        gainBaseline = (sent, app)
    }

    private mutating func startSpring(from: Double, to edge: Double, velocity: Double, stiffness: Double = 10) {
        physics.cancel()
        spring = ScrollSpring(offset: from - edge, velocity: velocity, stiffness: stiffness)
        springTarget = edge
        wanted = from
        requested = from
        phase = .bouncing
    }

    private func edge(beyond value: Double) -> Double? {
        if let upper = edges.upper, value > upper { return upper }
        if let lower = edges.lower, value < lower { return lower }
        return nil
    }

    private func clampToEdges(_ value: Double) -> Double {
        var v = value
        if let upper = edges.upper { v = min(v, upper) }
        if let lower = edges.lower { v = max(v, lower) }
        return v
    }

    /// Past an edge while tracking, the content follows the finger with UIScrollView's resistance.
    private func constrained(_ value: Double) -> Double {
        guard let edge = edge(beyond: value) else { return value }
        return edge + ScrollSpring.rubberBand(value - edge, dimension: max(1, regionLength))
    }

    /// Content beyond every captured frame may fill at most `revealLimit` of the region; the
    /// shown position resists past that. Once pictures arrive it catches up, smoothly and never
    /// slower than the gesture itself moves.
    private func revealLimited(_ wanted: Double, previousWanted: Double, elapsed: TimeInterval) -> Double {
        var limited = wanted
        if phase != .bouncing, let region, let span = coverage() {
            let length = Double(region.along.count), allowance = configuration.revealLimit * length
            let upperWall = span.upperBound - Double(region.along.upperBound) + allowance
            let lowerWall = span.lowerBound - Double(region.along.lowerBound) - allowance
            if wanted > upperWall { limited = upperWall + ScrollSpring.rubberBand(wanted - upperWall, dimension: 0.1 * length) }
            if wanted < lowerWall { limited = lowerWall + ScrollSpring.rubberBand(wanted - lowerWall, dimension: 0.1 * length) }
        }
        let shown = position
        guard abs(shown - previousWanted) > 0.5 else { return limited }
        // Catching up from a limit: approach exponentially, at least at the gesture's own pace.
        let approach = shown + (limited - shown) * (1 - exp(-elapsed / 0.06))
        let paced = shown + (wanted - previousWanted)
        let next = limited > shown ? min(limited, max(approach, paced)) : max(limited, min(approach, paced))
        return next
    }

    /// The content range, in content pixels, that placed frames cover.
    private func coverage() -> ClosedRange<Double>? {
        var low = Double.infinity, high = -Double.infinity
        for frame in frames {
            guard let offset = frame.offset, let region = frame.region ?? region else { continue }
            low = min(low, offset + Double(region.along.lowerBound))
            high = max(high, offset + Double(region.along.upperBound))
        }
        return low <= high ? low...high : nil
    }

    private func compose() -> ScrollComposition? {
        if let p = prefetch, let region, let pinned = frames.first(where: { $0.id == p.pinned }), let offset = pinned.offset {
            // The picture the user saw, unchanged, while the app visits what lies ahead.
            let own = pinned.region ?? region
            let shift = Int((offset - position).rounded())
            return ScrollComposition(axis: axis, base: pinned.id, region: region,
                                     layers: [.init(frame: pinned.id, shift: shift, lines: own.along)], blank: 0, fillFrom: nil)
        }
        guard let region, let base = frames.last(where: \.placed), let baseOffset = base.offset else { return nil }
        // At the app's own position the app's picture is what would be composed.
        if abs(baseOffset - position) < 0.5, (base.region ?? region) == region, frames.last?.placed == true,
           phase == .settling || phase == .idle { return nil }
        var layers: [ScrollComposition.Layer] = []
        var covered: [Range<Int>] = []
        for frame in frames {
            guard let offset = frame.offset else { continue }
            let own = frame.region ?? region
            let shift = Int((offset - position).rounded())
            let lower = max(region.along.lowerBound, own.along.lowerBound + shift)
            let upper = min(region.along.upperBound, own.along.upperBound + shift)
            guard lower < upper else { continue }
            layers.append(.init(frame: frame.id, shift: shift, lines: lower..<upper))
            covered.append(lower..<upper)
        }
        // Drop layers that newer ones hide entirely.
        var visible: [ScrollComposition.Layer] = []
        var above: [Range<Double>] = []
        for layer in layers.reversed() {
            let range = Double(layer.lines.lowerBound)..<Double(layer.lines.upperBound)
            if Self.uncovered(range, by: above) > 0 { visible.append(layer) }
            above.append(range)
        }
        let whole = Double(region.along.lowerBound)..<Double(region.along.upperBound)
        let blank = Int(Self.uncovered(whole, by: covered.map { Double($0.lowerBound)..<Double($0.upperBound) }).rounded())
        var fill: (UInt64, Range<Int>)?
        if blank > 0, let nearest = visible.first {
            // Fill from the edge of the layer that lies toward the unseen content.
            let forward = (layers.map(\.lines.upperBound).max() ?? region.along.upperBound) < region.along.upperBound
            let own = (frames.first { $0.id == nearest.frame }?.region ?? region).along
            fill = (nearest.frame, forward ? max(own.lowerBound, own.upperBound - 16)..<own.upperBound
                                           : own.lowerBound..<min(own.upperBound, own.lowerBound + 16))
        }
        return ScrollComposition(axis: axis, base: base.id, region: region, layers: visible.reversed(),
                                 blank: blank, fillFrom: fill, stationary: stationary)
    }

    // MARK: Timeline

    private func value(at time: TimeInterval, in history: [(time: TimeInterval, value: Double)]) -> Double? {
        guard let first = history.first else { return nil }
        if time <= first.time { return first.value }
        for i in stride(from: history.count - 1, through: 0, by: -1) where history[i].time <= time {
            guard i + 1 < history.count else { return history[i].value }
            let a = history[i], b = history[i + 1]
            let f = b.time > a.time ? (time - a.time) / (b.time - a.time) : 1
            return a.value + (b.value - a.value) * f
        }
        return first.value
    }

    /// The latest time the app was commanded through `offset` while moving from `from`.
    private func time(when offset: Double, movingFrom from: Double) -> TimeInterval? {
        let direction = offset > from ? 1.0 : -1.0
        for i in stride(from: commandedHistory.count - 1, to: 0, by: -1) {
            let a = commandedHistory[i - 1], b = commandedHistory[i]
            guard (b.value - a.value) * direction > 0 else { continue }
            let low = min(a.value, b.value), high = max(a.value, b.value)
            if low <= offset && offset <= high {
                let f = high > low ? (offset - a.value) / (b.value - a.value) : 1
                return a.time + (b.time - a.time) * f
            }
        }
        return nil
    }
}
