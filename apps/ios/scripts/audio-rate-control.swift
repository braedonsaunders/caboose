// Standalone opt-in macOS mechanism probe. Not part of CabooseKit's test target.
import AVFoundation
import CoreMedia
import Foundation

private let packetSeconds = 0.020
private let mediaStart = 10.0
private let hostClock = CMClockGetHostTimeClock()
private func host() -> Double { CMTimeGetSeconds(CMClockGetTime(hostClock)) }
private enum ProbeFailure: Error { case pcm, sample, invalidClock }
private struct Stimulus { let offset: Double; let rate: Float }
private let stimulus: [Stimulus] = [
    .init(offset: 1, rate: 1.029339439311),
    .init(offset: 6.015812042, rate: 1.010196839324),
    .init(offset: 11.040577458, rate: 0.998465495398),
    .init(offset: 16.046510500, rate: 0.995150375137),
    .init(offset: 21.056239250, rate: 0.999835333087),
]

private struct Event: Encodable {
    enum Kind: String, Encodable { case rateChanged, automaticFlush }
    let arm: Int
    let kind: Kind
    let hostSeconds: Double
    let observedRate: Float
    let flushSeconds: Double?
}
private struct Counts: Encodable {
    var rateChanges = 0
    var zeroObservations = 0
    var automaticFlushes = 0
    var firstZeroHost: Double?
    var latestZeroHost: Double?
}
private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var accepting: Int?
    private var counts = [Counts(), Counts()]
    private var recent: [Event] = []
    private var dropped = 0
    func begin(_ arm: Int) { lock.lock(); accepting = arm; lock.unlock() }
    func end(_ arm: Int) { lock.lock(); if accepting == arm { accepting = nil }; lock.unlock() }
    func record(_ event: Event) {
        lock.lock(); defer { lock.unlock() }
        guard accepting == event.arm, event.hostSeconds.isFinite, event.observedRate.isFinite else { return }
        switch event.kind {
        case .rateChanged:
            counts[event.arm].rateChanges += 1
            if event.observedRate == 0 {
                counts[event.arm].zeroObservations += 1
                if counts[event.arm].firstZeroHost == nil { counts[event.arm].firstZeroHost = event.hostSeconds }
                counts[event.arm].latestZeroHost = event.hostSeconds
            }
        case .automaticFlush: counts[event.arm].automaticFlushes += 1
        }
        recent.append(event)
        if recent.count > 128 { recent.removeFirst(); dropped += 1 }
    }
    func snapshot() -> (counts: [Counts], events: [Event], dropped: Int) {
        lock.lock(); defer { lock.unlock() }
        return (counts, recent, dropped)
    }
}
private struct Write: Encodable {
    let targetOffset: Double
    let beginOffset: Double
    let endOffset: Double
    let requestedRate: Float
    let beforeRate: Float
    let afterRate: Float
}
private struct Observation: Encodable {
    let targetOffset: Double
    let hostBeforeOffset: Double
    let hostAfterOffset: Double
    let mediaSeconds: Double?
    let observedRate: Float
    let rendererStatus: Int
    let expectedLower: Double
    let expectedUpper: Double
}
private struct Result: Encodable {
    let arm: Int
    let hostStartSeconds: Double
    let hostEndSeconds: Double
    let packets: Int
    let maximumEnqueueLatenessSeconds: Double
    let maximumEnqueueDurationSeconds: Double
    let minimumExpectedSupplyMarginSeconds: Double
    let observations: [Observation]
    let writes: [Write]
    let invalidClockSamples: Int
    let failedRendererSamples: Int
    let baselineOffset: Double?
    let residualProgressLowerSeconds: Double?
    let residualProgressUpperSeconds: Double?
}

/// Shared nonzero immutable PCM, with distinct timestamps in each sample buffer.
private func samples() throws -> [CMSampleBuffer] {
    var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
        mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
        layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
        extensions: nil, formatDescriptionOut: &format) == noErr, let format else { throw ProbeFailure.pcm }
    var values = [Float](repeating: 0, count: 960 * 2)
    for frame in 0..<960 {
        let value = Float(0.1 * sin(2 * Double.pi * 1000 * Double(frame) / 48_000))
        values[2 * frame] = value; values[2 * frame + 1] = value
    }
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
        blockLength: values.count * 4, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
        offsetToData: 0, dataLength: values.count * 4, flags: kCMBlockBufferAssureMemoryNowFlag,
        blockBufferOut: &block) == noErr, let block else { throw ProbeFailure.pcm }
    let status = values.withUnsafeBytes {
        CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                      offsetIntoDestination: 0, dataLength: $0.count)
    }
    guard status == noErr else { throw ProbeFailure.pcm }
    return try (0..<1350).map { index in
        var sample: CMSampleBuffer?
        let result = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
            dataBuffer: block, formatDescription: format, sampleCount: 960,
            presentationTimeStamp: CMTime(value: 10_000_000 + Int64(index) * 20_000, timescale: 1_000_000),
            packetDescriptions: nil, sampleBufferOut: &sample)
        guard result == noErr, let sample else { throw ProbeFailure.sample }
        return sample
    }
}

/// Every transition can take effect anywhere between its measured begin and end.
/// Bound each signed rate delta independently; all-begin/all-end models alone do
/// not bound a mixed increasing/decreasing sequence.
private func expectedBounds(_ offset: Double, writes: [Write]) -> (lower: Double, upper: Double) {
    var lower = mediaStart + offset, upper = lower, previousRate = 1.0
    for write in writes {
        let delta = Double(write.requestedRate) - previousRate
        let atBegin = delta * max(0, offset - write.beginOffset)
        let atEnd = delta * max(0, offset - write.endOffset)
        lower += min(atBegin, atEnd)
        upper += max(atBegin, atEnd)
        previousRate = Double(write.requestedRate)
    }
    return (lower, upper)
}

private func run(arm: Int, samples: [CMSampleBuffer], events: Events) throws -> Result {
    let renderer = AVSampleBufferAudioRenderer()
    renderer.isMuted = true
    renderer.audioTimePitchAlgorithm = .spectral
    let sync = AVSampleBufferRenderSynchronizer()
    sync.delaysRateChangeUntilHasSufficientMediaData = false
    sync.addRenderer(renderer)
    events.begin(arm)
    let rateObserver = NotificationCenter.default.addObserver(
        forName: AVSampleBufferRenderSynchronizer.rateDidChangeNotification, object: sync, queue: nil
    ) { [weak sync] _ in
        guard let sync else { return }
        events.record(Event(arm: arm, kind: .rateChanged, hostSeconds: host(),
                            observedRate: sync.rate, flushSeconds: nil))
    }
    let flushObserver = NotificationCenter.default.addObserver(
        forName: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: renderer, queue: nil
    ) { [weak sync] notification in
        guard let sync else { return }
        let time = (notification.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue)?.timeValue
        let seconds = time.flatMap { $0.isNumeric ? CMTimeGetSeconds($0) : nil }
        events.record(Event(arm: arm, kind: .automaticFlush, hostSeconds: host(), observedRate: sync.rate,
                            flushSeconds: seconds.flatMap { $0.isFinite ? $0 : nil }))
    }
    defer {
        // Invalidate callbacks already in flight before intentionally setting rate zero.
        events.end(arm)
        NotificationCenter.default.removeObserver(rateObserver)
        NotificationCenter.default.removeObserver(flushObserver)
        sync.setRate(0, time: .invalid)
        renderer.flush()
        let removed = DispatchSemaphore(value: 0)
        sync.removeRenderer(renderer, at: .invalid) { _ in removed.signal() }
        if removed.wait(timeout: .now() + 2) == .timedOut {
            fputs("Audio rate control renderer teardown timed out; no next arm started.\n", stderr)
            exit(3)
        }
    }
    for sample in samples.prefix(50) { renderer.enqueue(sample) }
    let startTime = CMClockGetTime(hostClock)
    let start = CMTimeGetSeconds(startTime)
    guard start.isFinite else { throw ProbeFailure.invalidClock }
    sync.setRate(1, time: CMTime(value: 10, timescale: 1), atHostTime: startTime)
    var packet = 0, observation = 0, change = 0
    var writes: [Write] = [], observations: [Observation] = []
    var lateness = 0.0, enqueueDuration = 0.0, minimumMargin = 1.0
    var invalid = 0, failed = 0
    func supplyMargin(at offset: Double) -> Double {
        mediaStart + Double(50 + packet) * packetSeconds - expectedBounds(offset, writes: writes).upper
    }
    while observation <= 104 || packet < 1300 {
        let packetTarget = packet < 1300 ? Double(packet) * packetSeconds : Double.infinity
        let observeTarget = observation <= 104 ? Double(observation) * 0.25 : Double.infinity
        let changeTarget = arm == 1 && change < stimulus.count ? stimulus[change].offset : Double.infinity
        let target = min(packetTarget, min(observeTarget, changeTarget))
        let wait = start + target - host()
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        var elapsed = host() - start
        if changeTarget <= elapsed {
            let item = stimulus[change]
            let before = sync.rate
            let begin = host() - start
            sync.setRate(item.rate, time: .invalid)
            let end = host() - start
            let after = sync.rate
            writes.append(Write(targetOffset: item.offset, beginOffset: begin, endOffset: end,
                                requestedRate: item.rate, beforeRate: before, afterRate: after))
            change += 1
            elapsed = host() - start
        }
        if packetTarget <= elapsed {
            let begin = host() - start
            minimumMargin = min(minimumMargin, supplyMargin(at: begin))
            lateness = max(lateness, begin - packetTarget)
            renderer.enqueue(samples[50 + packet])
            let end = host() - start
            // The next packet is not counted as supplied until enqueue returns.
            minimumMargin = min(minimumMargin, supplyMargin(at: end))
            enqueueDuration = max(enqueueDuration, end - begin)
            packet += 1
            elapsed = host() - start
        }
        if observeTarget <= elapsed {
            let before = host() - start
            let time = sync.currentTime()
            let after = host() - start
            let seconds = time.isNumeric ? CMTimeGetSeconds(time) : .nan
            let status = renderer.status
            if !seconds.isFinite { invalid += 1 }
            if status == .failed { failed += 1 }
            minimumMargin = min(minimumMargin, supplyMargin(at: after))
            observations.append(Observation(targetOffset: observeTarget, hostBeforeOffset: before,
                hostAfterOffset: after, mediaSeconds: seconds.isFinite ? seconds : nil,
                observedRate: sync.rate, rendererStatus: status.rawValue,
                expectedLower: expectedBounds(before, writes: writes).lower,
                expectedUpper: expectedBounds(after, writes: writes).upper))
            observation += 1
        }
    }
    let end = host()
    // Exclude the initial asynchronous start from progress comparison; retain every
    // raw observation so a still-unsettled baseline is visible and can invalidate it.
    let baseline = observations.first { $0.targetOffset >= 0.75 && $0.mediaSeconds != nil }
    let final = observations.last
    var lower: Double?, upper: Double?
    if let baseline, let firstMedia = baseline.mediaSeconds, let final, let lastMedia = final.mediaSeconds {
        let actual = lastMedia - firstMedia
        lower = final.expectedLower - baseline.expectedUpper - actual
        upper = final.expectedUpper - baseline.expectedLower - actual
    }
    return Result(arm: arm, hostStartSeconds: start, hostEndSeconds: end, packets: 50 + packet,
        maximumEnqueueLatenessSeconds: lateness, maximumEnqueueDurationSeconds: enqueueDuration,
        minimumExpectedSupplyMarginSeconds: minimumMargin, observations: observations, writes: writes,
        invalidClockSamples: invalid, failedRendererSamples: failed,
        baselineOffset: baseline?.hostAfterOffset, residualProgressLowerSeconds: lower,
        residualProgressUpperSeconds: upper)
}

private struct Report: Encodable {
    let version = 1
    let stimulusIsPartial = true
    let arms: [Result]
    let eventCounts: [Counts]
    let recentEvents: [Event]
    let droppedEvents: Int
}

guard ProcessInfo.processInfo.environment["CABOOSE_AUDIO_RATE_CONTROL"] == "1" else {
    fputs("Opt-in required: use run-audio-rate-control.py after compiling this standalone source.\n", stderr)
    exit(2)
}
do {
    let pcm = try samples()
    let events = Events()
    let control = try run(arm: 0, samples: pcm, events: events)
    let variable = try run(arm: 1, samples: pcm, events: events)
    let metadata = events.snapshot()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(Report(arms: [control, variable], eventCounts: metadata.counts,
                                         recentEvents: metadata.events, droppedEvents: metadata.dropped))
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
} catch {
    // Fixed message only: no device names, paths or platform error descriptions.
    fputs("Audio rate control failed to prepare or measure valid data.\n", stderr)
    exit(1)
}
