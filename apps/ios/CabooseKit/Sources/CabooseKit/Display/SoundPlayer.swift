import AVFoundation
import CoreMedia
import Foundation
import OSLog

/// Decodes Opus with the system's own decoder (AudioToolbox) into interleaved 32-bit float
/// PCM at 48 kHz, the rate Opus always decodes at.
public final class OpusDecoder {
    public static let sampleRate: Double = 48000
    public let channels: Int
    public let pcmFormat: AVAudioFormat
    private let opusFormat: AVAudioFormat
    private let converter: AVAudioConverter

    public enum Failure: Error { case unsupported, decode(String) }

    public init(channels: Int) throws {
        guard (1 ... 2).contains(channels),
              let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                                      channels: AVAudioChannelCount(channels), interleaved: true)
        else { throw Failure.unsupported }
        var description = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 960, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        guard let opus = AVAudioFormat(streamDescription: &description), let converter = AVAudioConverter(from: opus, to: pcm) else {
            throw Failure.unsupported
        }
        self.channels = channels
        pcmFormat = pcm
        opusFormat = opus
        self.converter = converter
    }

    /// One packet to PCM; Opus packets hold at most 120 ms.
    public func decode(_ packet: Data) throws -> AVAudioPCMBuffer {
        guard !packet.isEmpty else { throw Failure.decode("empty packet") }
        let input = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { input.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        input.byteLength = UInt32(packet.count)
        input.packetCount = 1
        input.packetDescriptions?[0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                    mDataByteSize: UInt32(packet.count))
        guard let output = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 5760) else { throw Failure.unsupported }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        if status == .error { throw Failure.decode(error?.localizedDescription ?? "Opus decode failed") }
        return output
    }
}

/// The computer's sound on Caboose Display: each 20 ms Opus packet decoded and handed to an
/// `AVSampleBufferAudioRenderer` on the session's `MediaClock`, at its own time, so the
/// system routes it like any app's sound (speaker, AirPods, AirPlay) and the video layers on
/// the same clock stay in step with it.
final class SoundPlayer: @unchecked Sendable {
    let renderer = AVSampleBufferAudioRenderer()
    private let clock: MediaClock
    private let activate: () throws -> Void
    private let now: @Sendable () -> TimeInterval
    let timing = AudioTimingMetrics()
    private let queue = DispatchQueue(label: "caboose.display.sound", qos: .userInteractive)
    // On `queue`:
    private var decoder: OpusDecoder?
    private var format: CMAudioFormatDescription?
    private var sessionActive = false
    private var interrupted = false
    private var timeline = AudioPacketTimeline()
    private let log = Logger(subsystem: "com.braedonsaunders.caboose", category: "display-audio")
    private var reportsAt: TimeInterval = 0
    private var errorsAt: TimeInterval = 0
    private var restarts = 0
    private var frameMin = Int.max
    private var frameMax = 0
    private var arrivalAt: TimeInterval?
    private var arrivalMax: TimeInterval = 0
    private var lastServerPTS: Int64?
    private var timestampRegressions = 0
    private let automaticFlush = AudioAutomaticFlushLatch()
    // Observer registration/lifetime and recovery run on the existing playback queue.
    private var automaticFlushObserver: NSObjectProtocol?
    private var automaticFlushGeneration: UInt64?
    private var interruptionObserver: NSObjectProtocol?
    private(set) var played = 0
    private(set) var failed = 0

    init(clock: MediaClock, now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, activate: @escaping () throws -> Void = {
        #if os(iOS)
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
    }) {
        self.clock = clock
        self.activate = activate
        self.now = now
        renderer.audioTimePitchAlgorithm = .spectral
        clock.add(renderer)
        #if os(iOS)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            self?.setInterrupted(type == .began)
        }
        #endif
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let automaticFlushObserver { NotificationCenter.default.removeObserver(automaticFlushObserver) }
        automaticFlush.update { $0.cancel() }
        clock.remove(renderer)
    }

    private func observeAutomaticFlush() {
        guard automaticFlushObserver == nil else { return }
        let generation = automaticFlush.update { $0.begin() }
        automaticFlushGeneration = generation
        automaticFlushObserver = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: renderer, queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            let time = (notification.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue)?.timeValue
            let micros = time.flatMap { $0.isNumeric ? CMTimeConvertScale($0, timescale: 1_000_000, method: .default).value : nil }
            let monotonic = self.now()
            let wall = Date().timeIntervalSince1970
            let schedule = self.automaticFlush.update {
                $0.notify(generation: generation, monotonic: monotonic, wall: wall, flushMicros: micros)
            }
            if schedule { self.scheduleAutomaticFlush(generation: generation) }
        }
    }

    private func cancelAutomaticFlushObservation() {
        automaticFlush.update { $0.cancel() }
        automaticFlushGeneration = nil
        if let automaticFlushObserver { NotificationCenter.default.removeObserver(automaticFlushObserver) }
        automaticFlushObserver = nil
    }

    private func scheduleAutomaticFlush(generation: UInt64) {
        queue.async { [weak self] in
            guard let self else { return }
            self.recoverAutomaticFlush(generation: generation)
            let again = self.automaticFlush.update { $0.finish(generation: generation) }
            if again { self.scheduleAutomaticFlush(generation: generation) }
        }
    }

    private func recoverAutomaticFlush(generation: UInt64) {
        let flush = automaticFlush.update { $0.take(generation: generation) }
        // Apple recommends this serialized flush to discard buffers surviving a concurrent
        // automatic flush. Explicit flush does not post the automatic-flush notification.
        // Keep the running clock/rate: resetting them can provoke another automatic flush.
        if flush { renderer.flush() }
    }

    private func setInterrupted(_ value: Bool) {
        queue.async { [self] in
            cancelAutomaticFlushObservation()
            interrupted = value
            sessionActive = false
            timeline.reset()
            timing.update { $0.reset() }
            arrivalAt = nil
            renderer.flush()
            clock.stop()
        }
    }

    func play(_ packet: AudioPacket, receivedAt: TimeInterval? = nil) {
        let dispatchedAt = now()
        let receivedAt = receivedAt ?? dispatchedAt
        queue.async { [self] in
            let enteredAt = now()
            guard packet.codec == "opus", !interrupted else { return }
            observeAutomaticFlush()
            var decodedAt: TimeInterval?
            var enqueueStartedAt: TimeInterval?
            var enqueuedAt: TimeInterval?
            var restartNotice: String?
            var restartRecord: AudioDiagnosticRecord?
            defer {
                let finishedAt = now()
                timing.update {
                    $0.packet(received: receivedAt, dispatched: dispatchedAt, entered: enteredAt,
                              decoded: decodedAt, enqueueStarted: enqueueStartedAt, enqueued: enqueuedAt,
                              finished: finishedAt)
                }
                if let restartNotice {
                    let enqueueMS = enqueueStartedAt.flatMap { start in enqueuedAt.map { milliseconds($0, since: start) } } ?? -1
                    let preparationMS = decodedAt.flatMap { decoded in enqueueStartedAt.map { milliseconds($0, since: decoded) } } ?? -1
                    let totalMS = milliseconds(finishedAt, since: receivedAt)
                    log.notice("display audio restart \(restartNotice, privacy: .public) prepare_ms=\(preparationMS) enqueue_ms=\(enqueueMS) finished_s=\(finishedAt) total_ms=\(totalMS)")
                    if var record = restartRecord {
                        record.preparationMS = preparationMS >= 0 ? preparationMS : nil
                        record.enqueueMS = enqueueMS >= 0 ? enqueueMS : nil
                        record.totalMS = totalMS
                        record.finishedMonotonicSeconds = finishedAt
                        AudioDiagnostics.record(record)
                    }
                }
                report(at: finishedAt)
            }
            do {
                if decoder?.channels != packet.channels {
                    decoder = try OpusDecoder(channels: packet.channels)
                    format = nil
                }
                guard let decoder else { return }
                let pcm = try decoder.decode(packet.data)
                let arrived = now()
                decodedAt = arrived
                guard pcm.frameLength > 0 else { return }
                if let arrivalAt { arrivalMax = max(arrivalMax, arrived - arrivalAt) }
                arrivalAt = arrived
                frameMin = min(frameMin, Int(pcm.frameLength))
                frameMax = max(frameMax, Int(pcm.frameLength))
                try activateSession()
                if renderer.status == .failed {
                    renderer.flush()
                    clock.stop()
                }
                let rawPTS = Int64(packet.ptsMicros)
                if let lastServerPTS, rawPTS <= lastServerPTS { timestampRegressions += 1 }
                lastServerPTS = rawPTS
                let pts = timeline.place(server: rawPTS, frames: Int(pcm.frameLength))
                let placement = clock.place(audio: pts)
                if case .restart = placement {
                    restarts += 1
                    if restarts <= 10 || restarts % 50 == 0 {
                        let rendered = observedRendererMicros()
                        let observedAt = now()
                        let requestedRate = clock.rate
                        let observedRate = clock.synchronizer.rate
                        let projected = clock.now ?? -1
                        let delay = clock.delay
                        let dispatchMS = milliseconds(dispatchedAt, since: receivedAt)
                        let queueMS = milliseconds(enteredAt, since: dispatchedAt)
                        let decodeMS = milliseconds(arrived, since: enteredAt)
                        let stage = "mono_s=\(observedAt) rx_dispatch_ms=\(dispatchMS) queue_ms=\(queueMS) decode_ms=\(decodeMS) requested_rate=\(requestedRate) observed_rate=\(observedRate)"
                        // Snapshot before flush; emit once enqueue finishes so its cost is
                        // included. The observed renderer time may lag AVFoundation updates.
                        restartNotice = "n=\(restarts) raw=\(rawPTS) pts=\(pts) projected=\(projected) rendered=\(rendered) delay=\(delay) regressions=\(timestampRegressions) \(stage)"
                        if AudioDiagnostics.enabled {
                            restartRecord = AudioDiagnosticRecord(
                                kind: .restart, monotonicSeconds: observedAt, wallUnixSeconds: Date().timeIntervalSince1970,
                                packets: played, failures: failed, restarts: restarts, delayMicros: delay,
                                requestedRate: requestedRate, observedRate: Double(observedRate),
                                projectedMicros: projected, renderedMicros: rendered, timestampRegressions: timestampRegressions,
                                rawPTSMicros: rawPTS, placedPTSMicros: pts,
                                receiptToDispatchMS: dispatchMS, queueMS: queueMS, decodeMS: decodeMS)
                        }
                    }
                    renderer.flush()
                }
                let buffer = try sample(pcm, decoder: decoder, pts: pts)
                // A rate change during placement may itself post a flush notification.
                // Check again after preparation, immediately before the next enqueue.
                if let generation = automaticFlushGeneration { recoverAutomaticFlush(generation: generation) }
                enqueueStartedAt = now()
                renderer.enqueue(buffer)
                enqueuedAt = now()
                switch placement {
                case .play: break
                case .start(let time), .restart(let time): clock.start(at: time)
                }
                played += 1
            } catch {
                failed += 1
                if now() - errorsAt >= 5 {
                    log.error("display audio failure count=\(self.failed) error=\(String(describing: error), privacy: .public)")
                    errorsAt = now()
                }
            }
        }
    }

    private func milliseconds(_ end: TimeInterval, since start: TimeInterval) -> Int {
        Int(AudioTimingAccumulator.elapsed(end, since: start) * 1000)
    }

    /// Diagnostic snapshot only. AVFoundation may apply timebase changes asynchronously;
    /// this value never drives placement or recovery.
    private func observedRendererMicros() -> Int64 {
        let time = clock.synchronizer.currentTime()
        return time.isNumeric ? CMTimeConvertScale(time, timescale: 1_000_000, method: .default).value : -1
    }

    private func report(at time: TimeInterval) {
        guard time - reportsAt >= 5 else { return }
        let interval = timing.takeInterval()
        let stages = interval.logFields
        let rendered = observedRendererMicros()
        let observedRate = clock.synchronizer.rate
        let delay = clock.delay
        let status = renderer.status.rawValue
        let rate = clock.rate
        let projected = clock.now ?? -1
        let minimum = frameMax == 0 ? 0 : frameMin
        log.notice("display audio packets=\(self.played) failures=\(self.failed) restarts=\(self.restarts) delay_us=\(delay) frames=\(minimum)...\(self.frameMax) max_arrival_ms=\(Int(self.arrivalMax * 1000)) renderer=\(status) rate=\(rate) observed_rate=\(observedRate) projected=\(projected) rendered=\(rendered) regressions=\(self.timestampRegressions) mono_s=\(time) \(stages, privacy: .public)")
        AudioDiagnostics.record(AudioDiagnosticRecord(
            kind: .interval, monotonicSeconds: time, wallUnixSeconds: Date().timeIntervalSince1970,
            packets: played, failures: failed, restarts: restarts, delayMicros: delay,
            requestedRate: rate, observedRate: Double(observedRate), projectedMicros: projected,
            renderedMicros: rendered, timestampRegressions: timestampRegressions, rendererStatus: status,
            frameMin: minimum, frameMax: frameMax, arrivalMaxSeconds: arrivalMax, interval: interval,
            automaticFlush: automaticFlush.update { $0.summary }))
        reportsAt = time
        frameMin = Int.max; frameMax = 0; arrivalMax = 0
    }

    func stop() {
        queue.async { [self] in
            cancelAutomaticFlushObservation()
            timeline.reset()
            timing.update { $0.reset() }
            arrivalAt = nil
            renderer.flush()
            clock.stop()
        }
    }

    /// Waits for everything queued so far; for tests.
    func flush() { queue.sync {} }

    private func sample(_ pcm: AVAudioPCMBuffer, decoder: OpusDecoder, pts: Int64) throws -> CMSampleBuffer {
        if format == nil {
            var description: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: decoder.pcmFormat.streamDescription, layoutSize: 0,
                                           layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                           formatDescriptionOut: &description)
            format = description
        }
        guard let format else { throw OpusDecoder.Failure.unsupported }
        let bytes = Int(pcm.frameLength) * decoder.channels * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block, let samples = pcm.audioBufferList.pointee.mBuffers.mData else {
            throw OpusDecoder.Failure.decode("no memory for \(bytes) bytes")
        }
        status = CMBlockBufferReplaceDataBytes(with: samples, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        guard status == noErr else { throw OpusDecoder.Failure.decode("copy failed (\(status))") }
        var sample: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: CMItemCount(pcm.frameLength),
            presentationTimeStamp: CMTime(value: pts, timescale: 1_000_000), packetDescriptions: nil, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw OpusDecoder.Failure.decode("sample buffer failed (\(status))") }
        return sample
    }

    /// Sound plays through the app's audio session (`.playback`, mixed with others, set at
    /// launch); it is made active when the first packet arrives.
    private func activateSession() throws {
        guard !sessionActive else { return }
        try activate()
        sessionActive = true
    }
}

/// PCM is contiguous even when an older server timestamps each pipe read rather than
/// each sample. Small capture-time jitter must not create audible holes or overlaps.
/// A real silence gap or discontinuity reanchors to the server instead of filling it.
struct AudioPacketTimeline {
    private var next: Int64?
    static let maximumJitter: Int64 = 200_000

    mutating func place(server: Int64, frames: Int) -> Int64 {
        let pts: Int64
        if let next, server >= next - Self.maximumJitter, server <= next + Self.maximumJitter {
            pts = next
        } else {
            pts = server
        }
        next = pts + Int64(frames) * 1_000_000 / 48_000
        return pts
    }

    mutating func reset() { next = nil }
}
