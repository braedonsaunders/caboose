import Foundation
import Testing
@testable import CabooseKit

/// The quantitative replay of real-speed flicks against simulated remote apps. Each line of
/// the printed report is one scenario; the assertions are the bar the phone must hold.
struct LocalScrollReplayTests {
    typealias Gesture = ScrollReplay.Gesture

    static let fastFlick = [Gesture.flick(at: 0.2, peak: 3500, duration: 0.11)]
    static let mediumFlick = [Gesture.flick(at: 0.2, peak: 1500, duration: 0.13)]
    static let slowDrag = [Gesture.drag(at: 0.2, speed: 400, duration: 0.6)]
    static let repeated = [Gesture.flick(at: 0.2, peak: 3000, duration: 0.1),
                           Gesture.flick(at: 0.55, peak: 3500, duration: 0.1),
                           Gesture.flick(at: 0.9, peak: 4000, duration: 0.1)]

    /// The window was scrolled once before: a short drag that settles, then the gestures
    /// under test from 1.5 s.
    static func warm(_ gestures: [Gesture]) -> [Gesture] {
        [Gesture.drag(at: 0.2, speed: 300, duration: 0.25, hold: 0.1)] + gestures.map {
            var moved = $0
            moved.samples = $0.samples.map { ($0.time + 1.3, $0.position) }
            moved.start += 1.3
            return moved
        }
    }

    static func run(_ name: String, _ app: ScrollReplay.App, _ gestures: [Gesture], warm: Bool = true, duration: TimeInterval = 9) -> ScrollReplay.Report {
        let replay = ScrollReplay(app: app, gestures: warm ? Self.warm(gestures) : gestures, duration: duration)
        let (report, _) = replay.run(name: (warm ? "" : "cold ") + name, measureFrom: warm ? 1.45 : -1)
        print(report.line)
        return report
    }

    @Test(arguments: [0.04, 0.08, 0.15])
    func flicksAtLatency(_ latency: Double) {
        var app = ScrollReplay.App()
        app.inputDelay = latency * 0.4
        app.outputDelay = latency * 0.6 - 0.5 / app.fps
        for (name, gestures) in [("fast flick", Self.fastFlick), ("medium flick", Self.mediumFlick),
                                 ("slow drag", Self.slowDrag), ("repeated flicks", Self.repeated)] {
            let report = Self.run("L=\(Int(latency * 1000))ms \(name)", app, gestures)
            #expect(report.responseRefreshes <= 1)
            #expect(report.misplacement <= 1)
            #expect(report.finalError <= 1)
            #expect(report.handoffJump <= 2)
            #expect(report.percentile(report.trackingError, 0.95) <= 1)
            #expect(report.settleTime < 4)
        }
    }
}

struct LocalScrollReplayTrace {
    @Test func trace() {
        guard ProcessInfo.processInfo.environment["CABOOSE_SCROLL_TRACE"] == "1" else { return }
        var app = ScrollReplay.App()
        app.inputDelay = 0.032; app.outputDelay = 0.048 - 0.5 / app.fps
        let (report, _) = ScrollReplay(app: app, gestures: LocalScrollReplayTests.warm(LocalScrollReplayTests.mediumFlick), duration: 3.5).run(name: "trace", measureFrom: 1.45, trace: true)
        print(report.line)
    }
}

struct LocalScrollEstimatorProbe {
    @Test func probe() {
        guard ProcessInfo.processInfo.environment["CABOOSE_SCROLL_TRACE"] == "1" else { return }
        let replay = ScrollReplay(app: ScrollReplay.App(), gestures: [])
        let a = replay.signature(offset: 4000 + 2310, seed: 14), b = replay.signature(offset: 4000 + 2486, seed: 15)
        for range in [(-615)...205, (-200)...600, 0...400] {
            print("probe", range, ScrollMotionEstimator().measure(from: a, to: b, expected: range, center: 0))
        }
        for shift in [1000, 1558, 1800, 1996, 2100] {
            let d = replay.signature(offset: 4000 + 2310 + shift, seed: 99)
            print("probe large", shift, ScrollMotionEstimator().measure(from: a, to: d, expected: 0...2540, center: shift))
        }
        let c = replay.signature(offset: 4000 + 2651, seed: 16)
        print("probe 16", ScrollMotionEstimator().measure(from: b, to: c, expected: -300...600, center: 40))
    }
}
