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
    private func projectedTime() -> Int64? {
        guard let anchor else { return nil }
        return anchor.media + Self.micros(hostTime()) - anchor.host
    }

    private static func micros(_ time: CMTime) -> Int64 {
        CMTimeConvertScale(time, timescale: 1_000_000, method: .default).value
    }

    /// How far the sound plays behind the server, in microseconds.
    public var delay: Int64 { lock.lock(); defer { lock.unlock() }; return playout.delay }

    /// Where a sound packet goes: the clock is to be started, started again, or left running.
    /// The caller enqueues the packet first and then calls `start(at:)`, so a renderer's slow
    /// first enqueue does not eat into the delay.
    func place(audio pts: Int64) -> PlayoutDelay.Placement {
        lock.lock()
        defer { lock.unlock() }
        return playout.place(pts: pts, now: projectedTime())
    }

    /// Runs the clock from `time` (server microseconds) on.
    func start(at time: Int64) {
        lock.lock()
        defer { lock.unlock() }
        let host = hostTime()
        anchor = (media: time, host: Self.micros(host))
        synchronizer.setRate(1, time: CMTime(value: time, timescale: 1_000_000), atHostTime: host)
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
        anchor = nil
        synchronizer.setRate(0, time: .invalid)
    }
}

/// How far behind the server the sound plays. It starts 40 ms behind the first packet, which
/// absorbs a LAN's jitter while keeping a click's sound close to its picture; a packet that
/// arrives too late to play adds 20 ms (up to 200 ms), and a backlog that has built up beyond
/// the delay is dropped by starting again just behind the newest packet. Silence the server
/// does not send is a gap the clock simply runs through.
struct PlayoutDelay: Equatable {
    static let initial: Int64 = 40_000
    static let step: Int64 = 20_000
    static let maximum: Int64 = 200_000
    /// How far beyond the delay a packet may arrive ahead before the backlog is dropped.
    static let slack: Int64 = 120_000

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
