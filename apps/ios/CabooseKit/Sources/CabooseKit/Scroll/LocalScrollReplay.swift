import Foundation

/// One scripted finger gesture: positions along the scroll in view points, content
/// direction, sampled at 120 Hz as UIKit delivers a ProMotion pan, then a lift.
public struct LocalScrollGesture: Sendable {
    public var label: String
    /// Seconds from the gesture's start, and the finger's distance travelled.
    public var samples: [(time: TimeInterval, position: Double)]

    /// UIKit's release velocity: the slope of the last samples.
    public var releaseVelocity: Double {
        let n = samples.count
        guard n >= 3 else { return 0 }
        let a = samples[max(0, n - 4)], b = samples[n - 1]
        return (b.position - a.position) / max(0.001, b.time - a.time)
    }

    /// A flick: the finger accelerates to `peak` points per second over `duration` and lifts
    /// while still moving. Negative peaks flick the other way.
    public static func flick(_ label: String, peak: Double, duration: TimeInterval) -> LocalScrollGesture {
        var samples: [(TimeInterval, Double)] = []
        var position = 0.0, t = 0.0
        let dt = 1.0 / 120
        while t < duration - 0.0001 {
            t += dt
            position += peak * sin(min(1, t / duration) * .pi / 2) * dt
            samples.append((t, position))
        }
        return LocalScrollGesture(label: label, samples: samples)
    }

    /// A drag at constant speed that holds still for `hold` before lifting: no momentum.
    public static func drag(_ label: String, speed: Double, duration: TimeInterval, hold: TimeInterval = 0.2) -> LocalScrollGesture {
        var samples: [(TimeInterval, Double)] = []
        var position = 0.0, t = 0.0
        let dt = 1.0 / 120
        while t < duration + hold - 0.0001 {
            t += dt
            if t <= duration { position += speed * dt }
            samples.append((t, position))
        }
        return LocalScrollGesture(label: label, samples: samples)
    }

    /// The standard script: real finger speeds, from a slow read to a hard flick, both ways.
    public static let script: [(start: TimeInterval, gesture: LocalScrollGesture)] = {
        var steps: [(TimeInterval, LocalScrollGesture)] = []
        var t: TimeInterval = 0
        func add(_ gesture: LocalScrollGesture, then rest: TimeInterval) {
            steps.append((t, gesture))
            t += (gesture.samples.last?.time ?? 0) + rest
        }
        for round in 1...2 {
            for i in 1...5 { add(.drag("r\(round) slow drag \(i)", speed: 400, duration: 0.6), then: 2) }
            for i in 1...5 { add(.flick("r\(round) fast flick \(i)", peak: 3500, duration: 0.11), then: 4) }
            // Hard flicks back, the last past the top of the page.
            for i in 1...4 { add(.flick("r\(round) flick to top \(i)", peak: -6000, duration: 0.12), then: 0.35) }
            t += 4
            for i in 1...3 { add(.drag("r\(round) drag hold release \(i)", speed: 600, duration: 0.4, hold: 0.6), then: 2) }
        }
        return steps
    }()
}

/// Plays `LocalScrollGesture.script` against the display clock, for on-device measurement
/// with `CABOOSE_SCROLL_AUTOPAN=1`: 5 slow drags, 5 fast flicks, hard flicks back past the
/// top and 3 drag-hold-release sequences, twice. It starts `CABOOSE_SCROLL_AUTOPAN_DELAY`
/// seconds (20 by default) after the first window that scrolls locally is on screen.
public struct LocalScrollReplay {
    public static let enabled = ProcessInfo.processInfo.environment["CABOOSE_SCROLL_AUTOPAN"] == "1"
    public static let delay = ProcessInfo.processInfo.environment["CABOOSE_SCROLL_AUTOPAN_DELAY"].flatMap(TimeInterval.init) ?? 20

    public enum Event: Equatable {
        case begin(label: String, at: TimeInterval, delta: CGPoint)
        case move(at: TimeInterval, delta: CGPoint)
        case release(at: TimeInterval, velocity: CGPoint)
    }

    private let start: TimeInterval
    private var gesture = 0
    private var sample = 0

    public init(start: TimeInterval) { self.start = start }

    public var isFinished: Bool { gesture >= LocalScrollGesture.script.count }

    /// Events due by `time`, in order.
    public mutating func events(until time: TimeInterval) -> [Event] {
        var events: [Event] = []
        while gesture < LocalScrollGesture.script.count {
            let (offset, script) = LocalScrollGesture.script[gesture]
            let base = start + offset
            let samples = script.samples
            while sample < samples.count, base + samples[sample].time <= time {
                let previous = sample == 0 ? 0 : samples[sample - 1].position
                let delta = CGPoint(x: 0, y: samples[sample].position - previous)
                let at = base + samples[sample].time
                events.append(sample == 0 ? .begin(label: script.label, at: at, delta: delta) : .move(at: at, delta: delta))
                sample += 1
            }
            guard sample >= samples.count else { break }
            events.append(.release(at: base + samples[samples.count - 1].time, velocity: CGPoint(x: 0, y: script.releaseVelocity)))
            gesture += 1
            sample = 0
        }
        return events
    }
}
