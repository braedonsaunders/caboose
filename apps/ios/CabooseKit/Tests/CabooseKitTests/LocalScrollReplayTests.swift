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

extension LocalScrollReplayTests {
    /// The first gesture in a window the phone has not yet seen scroll: until the first
    /// picture that moved is measured the app's own picture shows, then the phone takes
    /// over without a jump and catches up with the finger.
    @Test(arguments: [0.04, 0.08, 0.15])
    func firstGestureInAWindow(_ latency: Double) {
        var app = ScrollReplay.App()
        app.inputDelay = latency * 0.4
        app.outputDelay = latency * 0.6 - 0.5 / app.fps
        for (name, gestures) in [("fast flick", Self.fastFlick), ("medium flick", Self.mediumFlick)] {
            let report = Self.run("L=\(Int(latency * 1000))ms \(name)", app, gestures, warm: false)
            #expect(report.misplacement <= 1)
            #expect(report.finalError <= 1)
        }
    }
}

struct LocalScrollReplayTrace {
    @Test func trace() {
        guard ProcessInfo.processInfo.environment["CABOOSE_SCROLL_TRACE"] == "1" else { return }
        var app = ScrollReplay.App()
        app.inputDelay = 0.032; app.outputDelay = 0.048 - 0.5 / app.fps
        app.hitch = (every: 1.6, duration: 0.55)
        let (report, _) = ScrollReplay(app: app, gestures: LocalScrollReplayTests.warm(LocalScrollReplayTests.fastFlick + [ScrollReplay.Gesture.flick(at: 3.5, peak: 2500, duration: 0.12)]), duration: 9).run(name: "trace", measureFrom: 1.45, trace: true)
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

/// Apps that are not the reference: other gains, stalls, short pages, fixed footers and
/// sidebars. The phone must stay native through all of them.
struct LocalScrollRobustnessTests {
    typealias T = LocalScrollReplayTests
    static func app(latency: Double = 0.08) -> ScrollReplay.App {
        var app = ScrollReplay.App()
        app.inputDelay = latency * 0.4
        app.outputDelay = latency * 0.6 - 0.5 / app.fps
        return app
    }

    @Test(arguments: [0.5, 2.0])
    func otherToolkitGains(_ gain: Double) {
        var app = Self.app()
        app.gain = gain
        // The second flick runs at the gain learned from the first.
        let gestures = [ScrollReplay.Gesture.flick(at: 0.2, peak: 1500, duration: 0.13),
                        ScrollReplay.Gesture.flick(at: 4.5, peak: 2500, duration: 0.12)]
        let report = T.run("gain \(gain)", app, gestures, duration: 12)
        #expect(abs(report.learnedGain - gain) / gain < 0.05)
        #expect(report.misplacement <= 1)
        #expect(report.finalError <= 1)
        #expect(report.handoffJump <= 2)
    }

    @Test(arguments: [0.2, 0.55])
    func appStalls(_ stall: Double) {
        var app = Self.app()
        // A stall during the warm-up, one during the fast flick's first frames and others later.
        app.hitch = (every: 1.6, duration: stall)
        let report = T.run("stall \(Int(stall * 1000))ms", app, T.fastFlick + [ScrollReplay.Gesture.flick(at: 3.5, peak: 2500, duration: 0.12)], duration: 12)
        // A stall is not the end of the content.
        #expect(!report.edgeFound)
        #expect(report.misplacement <= 1)
        #expect(report.finalError <= 1)
        #expect(report.handoffJump <= 2)
        // Nothing new exists during a stall: the shown position resists at the reveal limit.
        #expect((report.blank.max() ?? 0) <= LocalScroll.Configuration().revealLimit + 0.12)
    }

    @Test func endOfContentBouncesBack() {
        var app = Self.app()
        app.pageLines = 7000 // the start is 4000: a hard flick runs off the end
        let report = T.run("end of page", app, T.fastFlick, duration: 8)
        #expect(report.edgeFound)
        #expect(report.bounced)
        #expect(report.finalError <= 1)
        #expect(report.misplacement <= 1)
    }

    @Test func fixedFooterAndSidebar() {
        var app = Self.app()
        app.footer = 160
        app.sidebar = 240
        let report = T.run("footer + sidebar", app, T.mediumFlick + [ScrollReplay.Gesture.flick(at: 4, peak: 3000, duration: 0.11)], duration: 10)
        #expect(report.misplacement <= 1)
        #expect(report.finalError <= 1)
        #expect(report.handoffJump <= 2)
    }
}

/// Cost of one measurement at phone resolution (`CABOOSE_SCROLL_BENCH=1`, run with
/// `swift test -c release -Xswiftc -enable-testing --filter LocalScrollEstimatorBenchmark`).
struct LocalScrollEstimatorBenchmark {
    @Test func measurementCost() {
        guard ProcessInfo.processInfo.environment["CABOOSE_SCROLL_BENCH"] == "1" else { return }
        let replay = ScrollReplay(app: ScrollReplay.App(), gestures: [])
        let a = replay.signature(offset: 4000, seed: 1), b = replay.signature(offset: 4300, seed: 2)
        let estimator = ScrollMotionEstimator()
        for (name, range) in [("typical ±300", -64...700), ("wide ±1300", -1300...1300), ("full", -2540...2540)] {
            let start = Date()
            var result: ScrollMeasurement = .still
            for _ in 0..<20 { result = estimator.measure(from: a, to: b, expected: range, center: 300) }
            print(String(format: "bench %@: %.2f ms per measurement", name, Date().timeIntervalSince(start) / 20 * 1000), result == .unexplained ? "unexplained" : "ok")
        }
    }
}
