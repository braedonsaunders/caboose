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
    /// Optional test sink observes exact lifecycle writes without running a renderer.
    private let rateWriter: ((Float, CMTime, CMTime?) -> Void)?
    private let rateTrace = AudioRateProvenance()
    private var rateObserver: NSObjectProtocol?
    // The mapping requested from AVFoundation, protected by `lock`. Its rate property
    // changes synchronously, but its timebase does not: reading currentTime immediately
    // after setRate can still return the previous timeline and trigger another flush.
    private var anchor: (media: Int64, host: Int64)?

    public convenience init() {
        self.init(hostTime: { CMClockGetTime(CMClockGetHostTimeClock()) })
    }

    /// An injectable monotonic clock keeps scheduling policy tests independent of devices.
    init(hostTime: @escaping () -> CMTime, rateWriter: ((Float, CMTime, CMTime?) -> Void)? = nil) {
        self.hostTime = hostTime
        self.rateWriter = rateWriter
        // Live packets already have a bounded jitter buffer. Waiting for every video
        // renderer to preroll can hold sound indefinitely behind an idle video stream.
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        let observedSynchronizer = synchronizer
        let trace = rateTrace
        let generation = trace.generation
        rateObserver = NotificationCenter.default.addObserver(
            forName: AVSampleBufferRenderSynchronizer.rateDidChangeNotification,
            object: observedSynchronizer, queue: nil
        ) { [weak observedSynchronizer, trace] _ in
            guard AudioDiagnostics.enabled, let observedSynchronizer else { return }
            // A synchronous callback during setRate must not acquire MediaClock.lock.
            // This rate is a callback-time snapshot, not a guaranteed event payload.
            let rate = Double(observedSynchronizer.rate)
            let mono = ProcessInfo.processInfo.systemUptime
            let wall = Date().timeIntervalSince1970
            trace.update { $0.changed(generation: generation, rate: rate, monotonic: mono, wall: wall) }
        }
    }

    deinit {
        rateTrace.update { $0.invalidate() }
        if let rateObserver { NotificationCenter.default.removeObserver(rateObserver) }
    }

    var diagnosticGeneration: UInt64 { rateTrace.generation }

    var rateProvenanceSnapshot: AudioRateProvenanceState.Snapshot? {
        guard AudioDiagnostics.enabled else { return nil }
        return rateTrace.update { $0.snapshot }
    }

    func recordInterruption(began: Bool) {
        guard AudioDiagnostics.enabled else { return }
        let mono = ProcessInfo.processInfo.systemUptime
        let wall = Date().timeIntervalSince1970
        rateTrace.update { $0.interrupted(began: began, monotonic: mono, wall: wall) }
    }

    private func writeRate(_ requested: Float, reason: AudioRateProvenanceState.Reason,
                           stopCaller: AudioRateStopCaller? = nil, apply: () -> Void) {
        guard AudioDiagnostics.enabled else { apply(); return }
        let before = Double(synchronizer.rate)
        let begin = ProcessInfo.processInfo.systemUptime
        let wall = Date().timeIntervalSince1970
        let ticket = rateTrace.update {
            $0.begin(reason: reason, stopCaller: stopCaller, requested: Double(requested),
                     before: before, monotonic: begin, wall: wall)
        }
        apply() // No trace lock held: AVFoundation may synchronously notify here.
        let end = ProcessInfo.processInfo.systemUptime
        let after = Double(synchronizer.rate)
        if let ticket { rateTrace.update { $0.end(ticket, after: after, monotonic: end) } }
    }

    private func applyRate(_ rate: Float, time: CMTime, host: CMTime?) {
        if let rateWriter { rateWriter(rate, time, host) }
        else if let host { synchronizer.setRate(rate, time: time, atHostTime: host) }
        else { synchronizer.setRate(rate, time: time) }
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
        return anchor.media + ((host ?? Self.micros(hostTime())) - anchor.host)
    }

    private static func micros(_ time: CMTime) -> Int64 {
        CMTimeConvertScale(time, timescale: 1_000_000, method: .default).value
    }

    /// How far the sound plays behind the server, in microseconds.
    public var delay: Int64 { lock.lock(); defer { lock.unlock() }; return playout.delay }

    /// Running playback is always natural speed; only explicit lifecycle operations write rate.
    var rate: Double { 1 }

    /// Where a sound packet goes: the clock is to be started, started again, or left running.
    /// The caller enqueues the packet first and then calls `start(at:)`, so a renderer's slow
    /// first enqueue does not eat into the delay.
    func place(audio pts: Int64) -> PlayoutDelay.Placement { placement(audio: pts).decision }

    /// Returns the placement's already-sampled lead for opt-in metadata, without another
    /// host or renderer read. A stopped clock has no lead until its explicit start.
    func placement(audio pts: Int64) -> (decision: PlayoutDelay.Placement, leadMicros: Int64?) {
        lock.lock()
        defer { lock.unlock() }
        let host = hostTime()
        let micros = Self.micros(host)
        // Placement uses one host sample. Ordinary packets never change AVFoundation's
        // rate: a positive-to-positive write can temporarily stop the renderer.
        let now = projectedTime(at: micros)
        return (playout.place(pts: pts, now: now), now.map { pts - $0 })
    }

    /// Runs the clock from `time` (server microseconds) on.
    func start(at time: Int64) {
        lock.lock()
        defer { lock.unlock() }
        let host = hostTime()
        anchor = (media: time, host: Self.micros(host))
        writeRate(1, reason: .start) {
            applyRate(1, time: CMTime(value: time, timescale: 1_000_000), host: host)
        }
    }

    /// When a picture stamped `pts` should be shown, or nil to show it at once: the clock is
    /// stopped (no sound), or the picture is already late.
    func time(for pts: Int64) -> CMTime? {
        guard let now, pts >= now else { return nil }
        return CMTime(value: pts, timescale: 1_000_000)
    }

    /// The sound stopped (a failed renderer, a closed session): pictures go back to showing at once.
    func stop(reason: AudioRateStopCaller = .unspecified) {
        lock.lock()
        defer { lock.unlock() }
        playout.stop()
        anchor = nil
        writeRate(0, reason: .stop, stopCaller: reason) {
            applyRate(0, time: .invalid, host: nil)
        }
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
