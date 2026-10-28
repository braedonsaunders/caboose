import SwiftUI

// The Caboose brand, drawn natively: "caboose" standing on a rail with its o's for
// wheels. Same geometry and timing as apps/web/src/brand/brand.ts, which renders the
// README, favicon and app icon; change the two together.
//
//   CabooseWordmark(motion: .intro)     draws in, rolls one wheel-turn, again every 12 s
//   CabooseWordmark(motion: .rolling)   wheels turning (waking)
//   CabooseWordmark(lit: false)         hubs unlit: the computer is parked
//   CabooseWheel()                      one wheel, a power button
//
// Ink is the environment's foreground style; lit hubs are amber. Motion stops under
// Reduce Motion.

enum BrandMotion: Equatable {
    case intro, rolling, still
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

/// One wheel of the wordmark: rim, spoke and amber hub. It reads as a power button,
/// which is what it stands for where it appears (the computer menu).
struct CabooseWheel: View {
    var lit = true

    var body: some View {
        BrandCanvas(box: Brand.wheelBox, motion: .still) { context, frame in
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
        TimelineView(.animation(paused: !moving)) { timeline in
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

    /// How far the train still has to roll, in wheel revolutions: 1 is a full turn
    /// behind its resting place, 0 is at rest. Ties sit `roll × ROLL` to the right and
    /// wheels `roll × 360°` anticlockwise of rest.
    var roll: Double {
        switch motion {
        case .still:
            return 0
        case .rolling:
            let period = 1.8
            return 1 - time.truncatingRemainder(dividingBy: period) / period
        case .intro:
            let (delay, duration, cycle) = (Brand.Timing.rollDelay, Brand.Timing.rollDuration, Brand.Timing.cycle)
            if time < delay { return 1 }
            if time < delay + duration { return 1 - Brand.Easing.roll((time - delay) / duration) }
            guard time >= delay + cycle else { return 0 }
            let phase = (time - delay - cycle).truncatingRemainder(dividingBy: cycle)
            return phase < duration ? 1 - Brand.Easing.cycle(phase / duration) : 0
        }
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

    static let wordmarkBox = CGRect(x: -22, y: -50, width: 836, height: 185)
    /// One wheel with a little room for its stroke's anti-aliasing.
    static let wheelBox = CGRect(x: -2, y: -2, width: 104, height: 104)

    enum Timing {
        static let draw = 0.55
        static let pop = 0.45
        static let hubAfter = 0.5
        static let rollDelay = 0.7
        static let rollDuration = 2.2
        static let cycle = 12.0
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

    /// Left edge of each letter of "caboose".
    private static let letterX: [CGFloat] = [0, 108, 222, 346, 460, 574, 680]

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
        var s = Path()
        s.addArc(center: .zero, radius: 1, startAngle: .degrees(-30), endAngle: .degrees(90), clockwise: true,
                 transform: CGAffineTransform(a: 32, b: 0, c: 0, d: 20, tx: 50, ty: 30))
        s.addArc(center: .zero, radius: 1, startAngle: .degrees(-90), endAngle: .degrees(150), clockwise: false,
                 transform: CGAffineTransform(a: 32, b: 0, c: 0, d: 20, tx: 50, ty: 70))
        var e = Path()
        e.addArc(center: CGPoint(x: 50, y: 50), radius: 40, startAngle: .zero, endAngle: .degrees(49.97), clockwise: true)
        return [
            "c": [c],
            "a": [ring(50), line([CGPoint(x: 90, y: 0), CGPoint(x: 90, y: 100)])],
            "b": [line([CGPoint(x: 10, y: -38), CGPoint(x: 10, y: 100)]), ring(60)],
            "s": [s],
            "e": [e, line([CGPoint(x: 10, y: 50), CGPoint(x: 100, y: 50)])],
        ]
    }()

    static func drawWordmark(in context: inout GraphicsContext, frame: BrandFrame, lit: Bool = true) {
        drawTrack(in: &context, frame: frame, rail: (-12, 792), clip: (-8, 788),
                  railDrawn: frame.drawn(0.05, duration: 0.7))
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

    /// Rail and ties. The ties slide left as the train rolls right.
    private static func drawTrack(in context: inout GraphicsContext, frame: BrandFrame,
                                  rail: (CGFloat, CGFloat), clip: (CGFloat, CGFloat), railDrawn: Double) {
        var ties = context
        ties.clip(to: Path(CGRect(x: clip.0, y: 100, width: clip.1 - clip.0, height: 40)))
        ties.opacity = 0.32
        let shift = frame.roll * rollDistance
        var k = Int(((Double(clip.0) - rollDistance) / tie).rounded(.down))
        while Double(k) * tie < Double(clip.1) {
            let x = Double(k) * tie + shift
            ties.fill(Path(roundedRect: CGRect(x: x, y: 116, width: 14, height: 11), cornerRadius: 2), with: .foreground)
            k += 1
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
