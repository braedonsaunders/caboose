import Foundation
import ImageIO
import Testing
@testable import CabooseKit

/// The target-acquisition benchmark (guest/touch-targets/README.md) on recorded windows:
/// each fixture holds a test app's controls as its toolkit laid them out (the truth) and
/// as the computer read them from the accessibility tree (what the phone receives).
/// Simulated fingers aim at each control and land with a Gaussian error; a tap hits when
/// the press lands on the control it aimed at.
///
/// `TOUCH_BENCH_CLICKS=<file>` also writes a set of taps for `bench-guest.py --clicks` to
/// replay through the seat's real pointer.
@Suite struct TouchTargetingBenchmarkTests {
    struct Truth: Decodable {
        var name: String
        var kind: String
        var rect: [Double]
        var cgRect: CGRect { CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]) }
    }

    struct Fixture: Decodable {
        var app: String
        var window: [Double]
        var truth: [Truth]
        var provided: [[Double]]
    }

    /// SplitMix64: the same taps on every run.
    struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func gaussian() -> Double {
            let u = max(uniform(), 1e-12), v = uniform()
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
    }

    enum Method: String, CaseIterable { case finger, nearest, aim, magnify, picture }

    /// A fixture's picture as RGBA rows, for aiming without an accessibility tree.
    struct Picture {
        var bytes: [UInt8]
        var width: Int, height: Int
        func targets(around point: CGPoint, radius: Int) -> [TouchTarget] {
            bytes.withUnsafeBytes {
                PictureTargets.find(in: $0, width: width, height: height, bytesPerRow: width * 4, around: point, radius: radius)
            }
        }
    }

    static func picture(_ app: String) -> Picture? {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/touch-targets/\(app).png")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let (w, h) = (image.width, image.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? Picture(bytes: bytes, width: w, height: h) : nil
    }

    /// How much an ambiguous tap's second look magnifies.
    static let magnification = 3.0

    /// iPhone points per millimetre (460 ppi at 3x).
    static let pointsPerMM = 460.0 / 3 / 25.4

    static func fixtures() -> [Fixture] {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/touch-targets")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.compactMap {
            try? JSONDecoder().decode(Fixture.self, from: Data(contentsOf: $0))
        }
    }

    /// The common alternative: a touch on a control stays; otherwise the nearest control
    /// within two spreads.
    static func nearest(_ touch: CGPoint, spread: CGFloat, among targets: [TouchTarget]) -> CGPoint {
        if targets.contains(where: { $0.rect.contains(touch) }) { return touch }
        var best: (CGFloat, CGRect)?
        for target in targets where target.enabled {
            let r = target.rect
            let dx = max(r.minX - touch.x, 0, touch.x - r.maxX), dy = max(r.minY - touch.y, 0, touch.y - r.maxY)
            let d = hypot(dx, dy)
            if d <= 2 * spread, d < (best?.0 ?? .infinity) { best = (d, r) }
        }
        guard let rect = best?.1 else { return touch }
        return TouchAim.pressPoint(touch, in: rect, spread: spread)
    }

    static func press(_ method: Method, _ touch: CGPoint, spread: CGFloat, _ targets: [TouchTarget],
                      background: CGFloat = TouchAim.backgroundSpan) -> CGPoint {
        switch method {
        case .finger: return touch
        case .nearest: return nearest(touch, spread: spread, among: targets)
        case .aim, .magnify, .picture: return TouchAim.choose(touch, spread: spread, among: targets, backgroundSpan: background)?.point ?? touch
        }
    }

    struct Score { var hits = 0, taps = 0, error = 0.0, second = 0
        var rate: Double { taps == 0 ? 0 : Double(hits) / Double(taps) }
    }

    /// Taps aimed at each control: the aim point is near the control's middle (people aim
    /// at the middle of a small control), the landing error Gaussian with `fingerMM`.
    static func run(_ fixture: Fixture, method: Method, pointsPerPixel: Double, fingerMM: Double,
                    modelMM: Double = 1.2, background: CGFloat = TouchAim.backgroundSpan, confidence: Double = 0.75, taps: Int = 60,
                    picture: Picture? = nil,
                    record: ((Truth, CGPoint) -> Void)? = nil) -> Score {
        let targets = fixture.provided.compactMap(TouchTarget.init(wire:))
        let sigma = fingerMM * pointsPerMM / pointsPerPixel
        let spread = CGFloat(modelMM * pointsPerMM / pointsPerPixel)
        var random = Random(state: 0xCAB0_05E)
        var score = Score()
        for truth in fixture.truth {
            let rect = truth.cgRect
            for _ in 0..<taps {
                let aim = CGPoint(x: rect.midX + random.gaussian() * rect.width * 0.12,
                                  y: rect.midY + random.gaussian() * rect.height * 0.12)
                let touch = CGPoint(x: aim.x + random.gaussian() * sigma, y: aim.y + random.gaussian() * sigma)
                var pressed = press(method, touch, spread: spread, targets, background: background)
                if method == .picture {
                    let seen = picture?.targets(around: touch, radius: Int(3 * spread) + 4) ?? []
                    pressed = TouchAim.choose(touch, spread: spread, among: seen, backgroundSpan: background)?.point ?? touch
                }
                if method == .magnify,
                   TouchAim.read(touch, spread: spread, among: targets, backgroundSpan: background).isAmbiguous(below: confidence) {
                    // The region shows magnified and the finger taps again, the same finger
                    // over a picture `magnification` times larger.
                    score.second += 1
                    let zoom = Self.magnification
                    let again = CGPoint(x: rect.midX + random.gaussian() * (rect.width * 0.12 + sigma / zoom),
                                        y: rect.midY + random.gaussian() * (rect.height * 0.12 + sigma / zoom))
                    pressed = press(.aim, again, spread: spread / zoom, targets, background: background)
                }
                record?(truth, pressed)
                score.taps += 1
                if rect.contains(pressed) { score.hits += 1 }
                score.error += hypot(pressed.x - rect.midX, pressed.y - rect.midY) * pointsPerPixel / pointsPerMM
            }
        }
        return score
    }

    /// Taps meant for nothing: near a control (within three spreads) but on none.
    static func background(_ fixture: Fixture, pointsPerPixel: Double, fingerMM: Double,
                           background: CGFloat = TouchAim.backgroundSpan, taps: Int = 3000) -> Double {
        let targets = fixture.provided.compactMap(TouchTarget.init(wire:))
        let truths = fixture.truth.map(\.cgRect)
        let spread = CGFloat(1.2 * pointsPerMM / pointsPerPixel)
        let (w, h) = (fixture.window[2], fixture.window[3])
        var random = Random(state: 0xBAC6)
        var kept = 0, tried = 0
        while tried < taps {
            let touch = CGPoint(x: random.uniform() * w, y: random.uniform() * h)
            guard !truths.contains(where: { $0.contains(touch) }), !targets.contains(where: { $0.rect.contains(touch) }),
                  targets.contains(where: { $0.rect.insetBy(dx: -3 * spread, dy: -3 * spread).contains(touch) }) else { continue }
            tried += 1
            let pressed = press(.aim, touch, spread: spread, targets, background: background)
            if !truths.contains(where: { $0.contains(pressed) }) { kept += 1 }
        }
        return Double(kept) / Double(tried)
    }

    @Test func aimingHitsMoreSmallControlsThanTheBareFinger() async throws {
        let fixtures = Self.fixtures()
        try #require(!fixtures.isEmpty)
        var lines = ["app               pt/px finger  " + Method.allCases.map { $0.rawValue.padding(toLength: 17, withPad: " ", startingAt: 0) }.joined()]
        for fixture in fixtures {
            for scale in [0.5, 0.75, 1.0] {
                for finger in [1.0, 1.5, 2.0] {
                    let picture = Self.picture(fixture.app)
                    // The pixel benchmark is CPU-bound. Keep it off Swift's cooperative executor so
                    // async tests and their timeout tasks can make progress even on a single worker.
                    let scores = await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .utility).async {
                            continuation.resume(returning: Method.allCases.map { Self.run(fixture, method: $0, pointsPerPixel: scale, fingerMM: finger, picture: picture) })
                        }
                    }
                    let cells = scores.map { String(format: "%5.1f%% %4.2fmm   ", $0.rate * 100, $0.error / Double($0.taps)) }
                        + [String(format: "(%.0f%% twice)", Double(scores[3].second) / Double(scores[3].taps) * 100)]
                    lines.append(fixture.app.padding(toLength: 18, withPad: " ", startingAt: 0)
                        + String(format: "%4.2f  %3.1fmm  ", scale, finger) + cells.joined())
                    if finger == 1.5, scale == 0.75 {
                        #expect(scores[2].rate > scores[0].rate + 0.08, "\(fixture.app)")
                        #expect(scores[2].rate >= scores[1].rate, "\(fixture.app)")
                    }
                }
            }
            lines.append(String(format: "%@ background taps kept at 0.75 pt/px: %.1f%%", fixture.app,
                                Self.background(fixture, pointsPerPixel: 0.75, fingerMM: 1.5) * 100))
        }
        print(lines.joined(separator: "\n"))
        if let path = ProcessInfo.processInfo.environment["TOUCH_BENCH_CLICKS"] {
            try Self.writeClicks(fixtures, to: URL(fileURLWithPath: path))
        }
    }

    @Test func backgroundSpanSweep() throws {
        guard ProcessInfo.processInfo.environment["TOUCH_BENCH_SWEEP"] != nil else { return }
        for fixture in Self.fixtures() {
            for span: CGFloat in [6, 10, 14, 20, 30, 45] {
                let hit = Self.run(fixture, method: .aim, pointsPerPixel: 0.75, fingerMM: 1.5, background: span).rate
                let kept = Self.background(fixture, pointsPerPixel: 0.75, fingerMM: 1.5, background: span)
                print(String(format: "%@ span %2.0f: hit %.1f%% background kept %.1f%%", fixture.app, span, hit * 100, kept * 100))
            }
            for confidence in [0.4, 0.5, 0.6, 0.75] {
                for scale in [0.75, 1.0] {
                    let score = Self.run(fixture, method: .magnify, pointsPerPixel: scale, fingerMM: 1.5, confidence: confidence)
                    print(String(format: "%@ %.2f pt/px confidence %.2f: hit %.1f%% twice %.0f%%", fixture.app, scale, confidence,
                                 score.rate * 100, Double(score.second) / Double(score.taps) * 100))
                }
            }
            for model in [0.8, 1.0, 1.2, 1.5, 2.0] {
                let hit = Self.run(fixture, method: .aim, pointsPerPixel: 0.75, fingerMM: 1.5, modelMM: model).rate
                print(String(format: "%@ model %.1fmm: hit %.1f%%", fixture.app, model, hit * 100))
            }
        }
    }

    /// Ten taps per control at 0.75 pt/px and a 1.5 mm finger, by each method.
    static func writeClicks(_ fixtures: [Fixture], to url: URL) throws {
        var all: [String: [[String: Any]]] = [:]
        for fixture in fixtures {
            var clicks: [[String: Any]] = []
            for method in [Method.finger, .aim] {
                _ = run(fixture, method: method, pointsPerPixel: 0.75, fingerMM: 1.5, taps: 10) { truth, point in
                    clicks.append(["at": [Double(point.x), Double(point.y)], "want": truth.name, "tag": method.rawValue])
                }
            }
            all[fixture.app] = clicks
        }
        try JSONSerialization.data(withJSONObject: all).write(to: url)
    }
}
