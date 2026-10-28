import SwiftUI

// The Caboose brand, drawn natively: "caboose" standing on a rail with its o's for
// wheels. Same geometry and timing as apps/web/src/brand/brand.ts, which renders the
// README, favicon and app icon; change the two together.
//
//   CabooseWordmark(motion: .intro)     draws in, rolls three wheel-turns, again every 24 s
//   CabooseWordmark(motion: .idle)      the still logo, rolling three wheel-turns every 24 s
//   CabooseWordmark(motion: .rolling)   wheels turning (waking)
//   CabooseWordmark(lit: false)         hubs unlit: the computer is parked
//   CabooseWheel()                      one wheel, a power button
//   CabooseWheel(motion: .rolling)      one wheel turning: something is at work
//
// Ink is the environment's foreground style; lit hubs are amber. At rest the rail stands
// alone; the ties show only while the train rolls. Motion stops under Reduce Motion.

enum BrandMotion: Equatable {
    case intro, idle, rolling, still
}

struct CabooseWordmark: View {
    var motion: BrandMotion = .still
    /// Amber hubs while the computer is up; unlit while it is parked.
    var lit = true

    var body: some View {
        BrandCanvas(box: Brand.wordmarkBox, motion: motion) { context, frame in
            Brand.drawWordmark(in: &context, frame: frame, lit: lit)
        }
        .accessibilityElement()
        .accessibilityLabel("Caboose")
    }
}

/// One wheel of the wordmark: rim, spoke and amber hub. It reads as a power button where it
/// stands for the computer, and rolls (`motion: .rolling`) where something is at work.
struct CabooseWheel: View {
    var motion: BrandMotion = .still
    var lit = true

    var body: some View {
        BrandCanvas(box: Brand.wheelBox, motion: motion == .intro ? .still : motion) { context, frame in
            Brand.drawWheel(in: &context, x: 0, start: 0, frame: frame, lit: lit)
        }
        .accessibilityElement()
        .accessibilityLabel("Caboose")
    }
}

/// Fits a brand drawing's unit box into the view and drives its clock.
private struct BrandCanvas: View {
    let box: CGRect
    let motion: BrandMotion
    let draw: (inout GraphicsContext, BrandFrame) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date.now

    var body: some View {
        let moving = motion != .still && !reduceMotion
        TimelineView(BrandSchedule(start: start, motion: moving ? motion : .still)) { timeline in
            Canvas { context, size in
                let scale = min(size.width / box.width, size.height / box.height)
                context.translateBy(x: (size.width - box.width * scale) / 2, y: (size.height - box.height * scale) / 2)
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: -box.minX, y: -box.minY)
                draw(&context, BrandFrame(motion: moving ? motion : .still, time: timeline.date.timeIntervalSince(start)))
            }
        }
        .aspectRatio(box.width / box.height, contentMode: .fit)
        .onAppear { start = .now }
    }
}

/// Frames while something moves, and none while the train is at rest between rolls: a
/// resting logo costs no redraws.
private struct BrandSchedule: TimelineSchedule {
    let start: Date
    let motion: BrandMotion

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        if motion == .still { return AnySequence(CollectionOfOne(startDate)) }
        return AnySequence(sequence(first: startDate) { date in
            let time = date.timeIntervalSince(start)
            guard let rest = BrandFrame.nextMove(motion: motion, after: time) else { return date + 1.0 / 60 }
            return start + rest
        })
    }
}

/// Where every animated part is at one instant. A still frame is the finished logo.
struct BrandFrame {
    let motion: BrandMotion
    let time: TimeInterval

    /// Stroke drawn so far, 0...1, for a stroke that starts at `delay`.
    func drawn(_ delay: Double, duration: Double = Brand.Timing.draw) -> Double {
        guard motion == .intro else { return 1 }
        return Brand.Easing.standard(progress(delay, duration))
    }

    func faded(_ delay: Double, duration: Double = 0.3) -> Double {
        guard motion == .intro else { return 1 }
        return progress(delay, duration)
    }

    /// Scale and opacity of a part that pops in at `delay` (overshooting spring).
    func popped(_ delay: Double) -> (scale: Double, opacity: Double) {
        guard motion == .intro else { return (1, 1) }
        let p = progress(delay, Brand.Timing.pop)
        return (0.2 + 0.8 * Brand.Easing.overshoot(p), p)
    }

    /// How far the train still has to roll, in wheel revolutions: 1 is a full turn behind
    /// its resting place (a roll starts `Brand.Timing.rollTurns` behind), 0 is at rest. Ties
    /// sit `roll × ROLL` to the right and wheels `roll × 360°` anticlockwise of rest.
    var roll: Double {
        let (duration, turns) = (Brand.Timing.rollDuration, Brand.Timing.rollTurns)
        switch motion {
        case .still:
            return 0
        case .rolling:
            let period = 1.8
            return 1 - time.truncatingRemainder(dividingBy: period) / period
        case .intro:
            let delay = Brand.Timing.rollDelay
            if time < delay { return turns }
            if time < delay + duration { return turns * (1 - Brand.Easing.roll((time - delay) / duration)) }
            guard let phase = Self.phase(time, since: delay + Brand.Timing.cycle) else { return 0 }
            return phase < duration ? turns * (1 - Brand.Easing.cycle(phase / duration)) : 0
        case .idle:
            guard let phase = Self.phase(time, since: Brand.Timing.idleDelay) else { return 0 }
            return phase < duration ? turns * (1 - Brand.Easing.cycle(phase / duration)) : 0
        }
    }

    /// How much of the ties shows, 0...1: none at rest; they fade in as a roll starts and
    /// out after it stops. Busy, they always show.
    var ties: Double {
        switch motion {
        case .still: return 0
        case .rolling: return 1
        case .intro, .idle:
            guard let phase = Self.phase(time, since: Self.firstRoll(motion)) else { return 0 }
            let (fadeIn, fadeOut, duration) = (Brand.Timing.tiesIn, Brand.Timing.tiesOut, Brand.Timing.rollDuration)
            if phase < fadeIn { return phase / fadeIn }
            if phase < duration { return 1 }
            return max(0, 1 - (phase - duration) / fadeOut)
        }
    }

    /// When the train next starts to move after `time`, or nil while it is moving now.
    static func nextMove(motion: BrandMotion, after time: TimeInterval) -> TimeInterval? {
        if motion == .rolling { return nil }
        let first = firstRoll(motion)
        // The intro draws in before its first roll; an idle logo waits still for its first.
        if time < first { return motion == .intro ? nil : first }
        let phase = (time - first).truncatingRemainder(dividingBy: Brand.Timing.cycle)
        if phase < Brand.Timing.rollDuration + Brand.Timing.tiesOut { return nil }
        return time - phase + Brand.Timing.cycle
    }

    private static func firstRoll(_ motion: BrandMotion) -> TimeInterval {
        motion == .idle ? Brand.Timing.idleDelay : Brand.Timing.rollDelay
    }

    /// Seconds into the current cycle of rolls that began at `delay`, or nil before it.
    private static func phase(_ time: TimeInterval, since delay: TimeInterval) -> TimeInterval? {
        time < delay ? nil : (time - delay).truncatingRemainder(dividingBy: Brand.Timing.cycle)
    }

    private func progress(_ delay: Double, _ duration: Double) -> Double {
        min(max((time - delay) / duration, 0), 1)
    }
}

enum Brand {
    static let amber = Color(red: 0xF5 / 255, green: 0xA6 / 255, blue: 0x23 / 255)

    /// Six ties per wheel revolution (2πr / 6), so a full turn lands seamlessly.
    static let tie = 2 * Double.pi * 40 / 6
    static let rollDistance = tie * 6

    static let wordmarkBox = CGRect(x: -4, y: -42, width: 784, height: 172)
    /// One wheel with a little room for its stroke's anti-aliasing.
    static let wheelBox = CGRect(x: -2, y: -2, width: 104, height: 104)

    enum Timing {
        static let draw = 0.55
        static let pop = 0.45
        static let hubAfter = 0.5
        static let rollDelay = 0.7
        static let rollDuration = 3.2
        /// Wheel revolutions in every roll.
        static let rollTurns = 3.0
        /// The ties fade in as the train starts and fade out after it stops.
        static let tiesIn = 0.4
        static let tiesOut = 0.8
        /// An idle logo first rolls this long after it appears, and every logo at rest
        /// rolls again once a cycle.
        static let idleDelay = 6.0
        static let cycle = 24.0
        static func letter(_ index: Int) -> Double { 0.25 + Double(index) * 0.07 }
    }

    /// The CSS cubic-béziers the web logo uses.
    enum Easing {
        static let standard = CubicBezier(0.4, 0, 0.2, 1)
        static let overshoot = CubicBezier(0.34, 1.56, 0.64, 1)
        static let roll = CubicBezier(0.3, 0.1, 0.2, 1)
        static let cycle = CubicBezier(0.45, 0, 0.2, 1)
    }

    // MARK: Wordmark

    /// Left edge of each letter of "caboose", spaced by the clear space between their ink.
    private static let letterX: [CGFloat] = [0, 99, 223, 347, 461, 568, 676]
    /// The rail's ends; its round caps reach flush with the c and the e.
    private static let rail: (CGFloat, CGFloat) = (6, 770)

    private static func ring(_ cx: CGFloat) -> Path {
        var path = Path()
        // Starts at three o'clock and runs clockwise on screen, like an SVG circle.
        path.addArc(center: CGPoint(x: cx, y: 50), radius: 40, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
        return path
    }

    private static func line(_ points: [CGPoint]...) -> Path {
        var path = Path()
        for run in points { path.addLines(run) }
        return path
    }

    /// Letter strokes in glyph units (x-height 0...100), excluding the o-wheels.
    private static let glyphs: [Character: [Path]] = {
        var c = Path()
        c.addArc(center: CGPoint(x: 50, y: 50), radius: 40, startAngle: .degrees(-42.06), endAngle: .degrees(42.06), clockwise: true)
        // Two stacked elliptical bowls, the lower a little fuller, ending near level.
        var s = Path()
        s.addArc(center: .zero, radius: 1, startAngle: .degrees(-14), endAngle: .degrees(90), clockwise: true,
                 transform: CGAffineTransform(a: 31, b: 0, c: 0, d: 19, tx: 50, ty: 29))
        s.addArc(center: .zero, radius: 1, startAngle: .degrees(-90), endAngle: .degrees(166), clockwise: false,
                 transform: CGAffineTransform(a: 33, b: 0, c: 0, d: 21, tx: 50, ty: 69))
        var e = Path()
        e.addArc(center: CGPoint(x: 50, y: 50), radius: 40, startAngle: .zero, endAngle: .degrees(35), clockwise: true)
        return [
            "c": [c],
            "a": [ring(50), line([CGPoint(x: 90, y: 0), CGPoint(x: 90, y: 100)])],
            "b": [line([CGPoint(x: 10, y: -38), CGPoint(x: 10, y: 100)]), ring(60)],
            "s": [s],
            "e": [e, line([CGPoint(x: 10, y: 50), CGPoint(x: 100, y: 50)])],
        ]
    }()

    static func drawWordmark(in context: inout GraphicsContext, frame: BrandFrame, lit: Bool = true) {
        drawTrack(in: &context, frame: frame, rail: rail, railDrawn: frame.drawn(0.05, duration: 0.7))
        let stroke = StrokeStyle(lineWidth: 20, lineCap: .butt, lineJoin: .round)
        for (index, letter) in "caboose".enumerated() {
            let x = letterX[index]
            let start = Timing.letter(index)
            if letter == "o" {
                drawWheel(in: &context, x: x, start: start, frame: frame, lit: lit)
                continue
            }
            for path in glyphs[letter] ?? [] {
                context.stroke(path.trimmedPath(from: 0, to: frame.drawn(start)).offsetBy(dx: x, dy: 0),
                               with: .foreground, style: stroke)
            }
        }
    }

    // MARK: Shared parts

    /// Rail and ties. The ties show only while the train rolls, sliding left as it rolls right.
    private static func drawTrack(in context: inout GraphicsContext, frame: BrandFrame,
                                  rail: (CGFloat, CGFloat), railDrawn: Double) {
        if frame.ties > 0 {
            var ties = context
            ties.clip(to: Path(CGRect(x: rail.0, y: 100, width: rail.1 - rail.0, height: 40)))
            ties.opacity = 0.32 * frame.ties
            let shift = frame.roll * rollDistance
            var k = Int(((Double(rail.0) - rollDistance * Brand.Timing.rollTurns) / tie).rounded(.down))
            while Double(k) * tie < Double(rail.1) {
                let x = Double(k) * tie + shift
                ties.fill(Path(roundedRect: CGRect(x: x, y: 116, width: 14, height: 11), cornerRadius: 2), with: .foreground)
                k += 1
            }
        }
        let railPath = line([CGPoint(x: rail.0, y: 106), CGPoint(x: rail.1, y: 106)])
        context.stroke(railPath.trimmedPath(from: 0, to: railDrawn), with: .foreground,
                       style: StrokeStyle(lineWidth: 12, lineCap: .round))
    }

    /// An o-wheel with its left edge at `x`: rim, spoke, and hub (amber when lit).
    static func drawWheel(in context: inout GraphicsContext, x: CGFloat, start: Double, frame: BrandFrame, lit: Bool = true) {
        let centre = CGPoint(x: x + 50, y: 50)
        var wheel = context
        wheel.translateBy(x: centre.x, y: centre.y)
        wheel.rotate(by: .degrees(-360 * frame.roll))
        wheel.translateBy(x: -centre.x, y: -centre.y)
        wheel.stroke(ring(centre.x).trimmedPath(from: 0, to: frame.drawn(start)), with: .foreground,
                     style: StrokeStyle(lineWidth: 20, lineCap: .butt))
        var spoke = wheel
        spoke.opacity = frame.faded(start)
        spoke.stroke(line([centre, CGPoint(x: centre.x, y: 22)]), with: .foreground,
                     style: StrokeStyle(lineWidth: 12, lineCap: .round))
        let (scale, opacity) = frame.popped(start + Timing.hubAfter)
        var hub = context
        hub.opacity = opacity * (lit ? 1 : 0.22)
        let r = 10 * scale
        hub.fill(Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r)),
                 with: lit ? .color(amber) : .foreground)
    }
}

/// A CSS `cubic-bezier(x1, y1, x2, y2)` timing function.
struct CubicBezier {
    let x1, y1, x2, y2: Double

    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        (self.x1, self.y1, self.x2, self.y2) = (x1, y1, x2, y2)
    }

    func callAsFunction(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        // Solve bx(t) = x by Newton's method, falling back to bisection.
        var t = x
        for _ in 0..<8 {
            let error = sample(t, x1, x2) - x
            if abs(error) < 1e-6 { return sample(t, y1, y2) }
            let slope = derivative(t, x1, x2)
            if abs(slope) < 1e-6 { break }
            t -= error / slope
        }
        var (low, high) = (0.0, 1.0)
        t = x
        for _ in 0..<32 {
            let value = sample(t, x1, x2)
            if abs(value - x) < 1e-6 { break }
            if value < x { low = t } else { high = t }
            t = (low + high) / 2
        }
        return sample(t, y1, y2)
    }

    private func sample(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
    }

    private func derivative(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * p1 + 6 * u * t * (p2 - p1) + 3 * t * t * (1 - p2)
    }
}
