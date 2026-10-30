import AVFoundation
import CoreMedia
import Foundation

/// A session's one playback clock: an `AVSampleBufferRenderSynchronizer` whose timeline is the
/// server's `CLOCK_MONOTONIC` in microseconds, the clock every `audio.pts_us`, `frame.pts_us`
/// and `video.present.pts_us` is on. The computer's sound starts it, a little behind the
/// first packet so network jitter does not starve the speaker; video layers on the same
/// synchronizer then show each picture at its own time, in step with the sound. With no
/// sound playing the clock is stopped and pictures are shown as they come.
public final class MediaClock: @unchecked Sendable {
    public let synchronizer = AVSampleBufferRenderSynchronizer()
    private let lock = NSLock()
    private var playout = PlayoutDelay()
    private var recovery = AudioClockRecovery()
    private var playbackRate: Double = 1
    private let hostTime: () -> CMTime
    // The mapping requested from AVFoundation, protected by `lock`. Its rate property
    // changes synchronously, but its timebase does not: reading currentTime immediately
    // after setRate can still return the previous timeline and trigger another flush.
    private var anchor: (media: Int64, host: Int64)?

    public convenience init() {
        self.init(hostTime: { CMClockGetTime(CMClockGetHostTimeClock()) })
    }

    /// An injectable monotonic clock keeps scheduling policy tests independent of devices.
    init(hostTime: @escaping () -> CMTime) {
        self.hostTime = hostTime
        // Live packets already have a bounded jitter buffer. Waiting for every video
        // renderer to preroll can hold sound indefinitely behind an idle video stream.
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
    }

    /// Puts a renderer (the sound, or a video layer's) on this clock.
    public func add(_ renderer: some AVQueuedSampleBufferRendering) {
        synchronizer.addRenderer(renderer)
    }

    public func remove(_ renderer: some AVQueuedSampleBufferRendering) {
        synchronizer.removeRenderer(renderer, at: .invalid)
    }

    /// The clock's time in server microseconds, nil while it is stopped.
    public var now: Int64? {
        lock.lock()
        defer { lock.unlock() }
        return projectedTime()
    }

    /// Called with `lock` held; this is the same host/media mapping supplied to the renderer.
    private func projectedTime(at host: Int64? = nil) -> Int64? {
        guard let anchor else { return nil }
        return anchor.media + Int64(Double((host ?? Self.micros(hostTime())) - anchor.host) * playbackRate)
    }

    private static func micros(_ time: CMTime) -> Int64 {
        CMTimeConvertScale(time, timescale: 1_000_000, method: .default).value
    }

    /// How far the sound plays behind the server, in microseconds.
    public var delay: Int64 { lock.lock(); defer { lock.unlock() }; return playout.delay }

    var rate: Double { lock.lock(); defer { lock.unlock() }; return playbackRate }

    /// Where a sound packet goes: the clock is to be started, started again, or left running.
    /// The caller enqueues the packet first and then calls `start(at:)`, so a renderer's slow
    /// first enqueue does not eat into the delay.
    func place(audio pts: Int64) -> PlayoutDelay.Placement {
        lock.lock()
        defer { lock.unlock() }
        let host = hostTime()
        let micros = Self.micros(host)
        // Sample once: a rate correction must pair the media position with the exact
        // host instant used to compute it. A second read after a scheduling delay
        // would anchor the later media position to the earlier host time, counting
        // that delay twice and permanently advancing the projected clock.
        let now = projectedTime(at: micros)
        if let now, let rate = recovery.observe(pts: pts, host: micros, ahead: pts - now, target: playout.delay),
           abs(rate - playbackRate) >= 0.001 {
            // Change speed continuously, keeping the current media position. Flushing to
            // chase clock drift loses real sound on every correction.
            anchor = (media: now, host: micros)
            playbackRate = rate
            // A rate correction must not seek the timebase. Repeated explicit time/host
            // anchors make the audio renderer restart its processing, producing a gap
            // at every adjustment even though no buffer was flushed.
            synchronizer.setRate(Float(rate), time: .invalid)
        } else if now == nil {
            _ = recovery.observe(pts: pts, host: micros, ahead: playout.delay, target: playout.delay)
        }
        return playout.place(pts: pts, now: now)
    }

    /// Runs the clock from `time` (server microseconds) on.
    func start(at time: Int64) {
        lock.lock()
        defer { lock.unlock() }
        let host = hostTime()
        anchor = (media: time, host: Self.micros(host))
        synchronizer.setRate(Float(playbackRate), time: CMTime(value: time, timescale: 1_000_000), atHostTime: host)
    }

    /// When a picture stamped `pts` should be shown, or nil to show it at once: the clock is
    /// stopped (no sound), or the picture is already late.
    func time(for pts: Int64) -> CMTime? {
        guard let now, pts >= now else { return nil }
        return CMTime(value: pts, timescale: 1_000_000)
    }

    /// The sound stopped (a failed renderer, a closed session): pictures go back to showing at once.
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        playout.stop()
        recovery = AudioClockRecovery()
        playbackRate = 1
        anchor = nil
        synchronizer.setRate(0, time: .invalid)
    }
}

/// How far behind the server the sound plays. It starts 120 ms behind the first packet, which
/// absorbs a LAN's jitter while keeping a click's sound close to its picture; a packet that
/// arrives too late to play adds 20 ms (up to 240 ms), and a backlog that has built up beyond
/// the delay is dropped by starting again just behind the newest packet. Silence the server
/// does not send is a gap the clock simply runs through.
struct PlayoutDelay: Equatable {
    static let initial: Int64 = 120_000
    static let step: Int64 = 20_000
    static let maximum: Int64 = 240_000
    /// How far beyond the delay a packet may arrive ahead before the backlog is dropped.
    static let slack: Int64 = 300_000

    enum Placement: Equatable {
        case play
        /// Start the clock at this time.
        case start(Int64)
        /// Drop what is queued and start the clock again at this time.
        case restart(Int64)
    }

    private(set) var delay = initial
    private(set) var running = false

    /// `now` is the clock's time, nil while it is stopped.
    mutating func place(pts: Int64, now: Int64?) -> Placement {
        guard running, let now else {
            running = true
            return .start(pts - delay)
        }
        let ahead = pts - now
        if ahead < 0 {
            delay = min(delay + Self.step, Self.maximum)
            return .restart(pts - delay)
        }
        if ahead > delay + Self.slack { return .restart(pts - delay) }
        return .play
    }

    mutating func stop() { running = false }
}


/// Estimate the sender's sample clock against local monotonic arrival time. Regression
/// over several seconds rejects packet batching; a small phase correction drains excess
/// buffered audio without dropping it. Silence/discontinuities restart measurement only.
struct AudioClockRecovery {
    private struct Point { let media: Int64; let host: Int64 }
    private var points: [Point] = []
    private var previous: Point?
    private var updatedAt: Int64?
    private(set) var frequency: Double = 1

    mutating func observe(pts: Int64, host: Int64, ahead: Int64, target: Int64) -> Double? {
        let current = Point(media: pts, host: host)
        defer { previous = current }
        if let previous, pts <= previous.media || host < previous.host ||
            pts - previous.media > 500_000 || host - previous.host > 500_000 {
            points.removeAll(keepingCapacity: true)
            updatedAt = nil
        }
        guard points.last.map({ host - $0.host >= 100_000 }) ?? true else { return nil }
        points.append(current)
        if points.count > 64 { points.removeFirst(points.count - 64) }
        guard let first = points.first, host - first.host >= 2_000_000,
              updatedAt.map({ host - $0 >= 250_000 }) ?? true else { return nil }
        updatedAt = host
        let n = Double(points.count)
        let xs = points.map { Double($0.host - first.host) / 1_000_000 }
        let ys = points.map { Double($0.media - first.media) / 1_000_000 }
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let variance = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        guard variance > 0 else { return nil }
        let slope = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / variance
        guard (0.75...1.25).contains(slope) else { return nil }
        frequency = frequency * 0.5 + slope * 0.5
        let phase = min(0.03, max(-0.03, Double(ahead - target) / 4_000_000))
        return min(1.25, max(0.75, frequency + phase))
    }
}
