#if os(iOS)
import AVFoundation

/// The phone's microphone for the computer: `AVAudioEngine`'s input with voice processing,
/// as 48 kHz mono Opus in 20 ms packets. While it runs the app records and plays at once;
/// the audio session the app had before comes back when it stops.
@MainActor
final class MicrophoneCapture {
    var output: DeviceOutput?

    private var engine: AVAudioEngine?
    private var device: String?
    private var failed: (@MainActor (String) -> Void)?
    private var lease: UUID?
    private var pipeline: MicrophonePipeline?
    private var observers: [NSObjectProtocol] = []
    private var interrupted = false
    private var rebuilding = false
    private var rebuildScheduled = false
    private var lastRebuild = Date.distantPast
    private var rapidRebuilds = 0
    private var attempt = 0

    func open(_ descriptor: DeviceDescriptor, failed: @escaping @MainActor (String) -> Void) {
        close()
        device = descriptor.id
        self.failed = failed
        attempt += 1
        let current = attempt
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            start()
        case .undetermined:
            Task { @MainActor in
                let granted = await AVAudioApplication.requestRecordPermission()
                guard self.attempt == current, self.device != nil else { return }
                if granted { self.start() } else { self.fail("Microphone access is off for Caboose in Settings.") }
            }
        default:
            fail("Microphone access is off for Caboose in Settings.")
        }
    }

    func close() {
        attempt += 1
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        interrupted = false
        rapidRebuilds = 0
        rebuildScheduled = false
        stopEngine()
        device = nil
        failed = nil
        restoreSession()
    }

    private func stopEngine() {
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        pipeline?.stop()
        pipeline = nil
    }

    private func fail(_ reason: String) {
        let failed = failed
        close()
        failed?(reason)
    }

    private func start() {
        guard let device, let output else { return }
        let audio = AVAudioSession.sharedInstance()
        do {
            if lease == nil {
                lease = try CabooseAudioSession.acquire(.init(.playAndRecord, mode: .voiceChat,
                    options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]))
            }
            guard let lease, CabooseAudioSession.owns(lease) else {
                return fail("Another audio activity is using the microphone session.")
            }
            try audio.setActive(true)
            let engine = AVAudioEngine()
            let input = engine.inputNode
            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { return fail("No microphone is available.") }
            guard let pipeline = MicrophonePipeline(input: format, device: device, output: output) else {
                return fail("The microphone's sound cannot be encoded on this iPhone.")
            }
            input.installTap(onBus: 0, bufferSize: 960, format: format) { buffer, time in pipeline.append(buffer, at: time) }
            self.engine = engine
            self.pipeline = pipeline
            engine.prepare()
            try engine.start()
            if observers.isEmpty { observe() }
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func observe() {
        let current = attempt
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereResetNotification, .AVAudioEngineConfigurationChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let notifiedEngine = note.object as? AVAudioEngine
                Task { @MainActor [weak self] in
                    guard let self, self.attempt == current, self.device != nil else { return }
                    if name == AVAudioSession.interruptionNotification {
                        if type == AVAudioSession.InterruptionType.began.rawValue {
                            self.interrupted = true
                            self.stopEngine()
                        } else if type == AVAudioSession.InterruptionType.ended.rawValue {
                            guard AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) else {
                                return self.fail("Microphone capture was interrupted. Reopen it to resume.")
                            }
                            self.interrupted = false
                            self.scheduleRebuild()
                        }
                    } else if name != .AVAudioEngineConfigurationChange || (notifiedEngine != nil && notifiedEngine === self.engine) {
                        if name == AVAudioSession.mediaServicesWereResetNotification, let lease = self.lease {
                            do { try CabooseAudioSession.reapply(lease) }
                            catch { return self.fail(error.localizedDescription) }
                        }
                        self.scheduleRebuild()
                    }
                }
            })
        }
    }

    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        let current = attempt
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.attempt == current else { return }
            self.rebuildScheduled = false
            self.rebuild()
        }
    }

    private func rebuild() {
        guard !interrupted, !rebuilding, device != nil else { return }
        let now = Date()
        rapidRebuilds = now.timeIntervalSince(lastRebuild) < 1 ? rapidRebuilds + 1 : 0
        lastRebuild = now
        guard rapidRebuilds < 3 else { return fail("The microphone audio route is unstable. Reopen it to retry.") }
        rebuilding = true
        defer { rebuilding = false }
        stopEngine()
        start()
    }

    private func restoreSession() {
        guard let lease else { return }
        self.lease = nil
        do { try CabooseAudioSession.release(lease) }
        catch { NSLog("Caboose microphone could not restore audio session: %@", error.localizedDescription) }
    }
}

/// From the input tap to the computer, off the audio thread: convert to 48 kHz mono, cut into
/// 20 ms frames, encode each to Opus and send it.
final class MicrophonePipeline: @unchecked Sendable {
    private let queue = DispatchQueue(label: "caboose.devices.microphone", qos: .userInteractive)
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    private let encoder: OpusEncoder
    private let device: String
    private let output: DeviceOutput
    private var framer = PCMFramer()
    private let admission = NSLock()
    private let sending = NSLock()
    private var pending = 0
    private var stopped = false

    func stop() {
        sending.withLock { admission.withLock { stopped = true } }
    }

    init?(input: AVAudioFormat, device: String, output: DeviceOutput) {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: PCMFramer.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: target), let encoder = try? OpusEncoder() else { return nil }
        self.target = target
        self.converter = converter
        self.encoder = encoder
        self.device = device
        self.output = output
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        let micros = time.isHostTimeValid ? UInt64(AVAudioTime.seconds(forHostTime: time.hostTime) * 1_000_000) : 0
        // Bound capture work even when encoding or the transport stalls.
        guard admission.withLock({
            guard !stopped, pending < 3 else { return false }
            pending += 1
            return true
        }) else { return }
        guard let copy = buffer.copy() as? AVAudioPCMBuffer else {
            admission.withLock { pending -= 1 }
            return
        }
        queue.async {
            defer { self.admission.withLock { self.pending -= 1 } }
            guard self.admission.withLock({ !self.stopped }) else { return }
            self.convert(copy, at: micros)
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer, at micros: UInt64) {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = converted.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
        for frame in framer.append(samples, at: micros) {
            guard let packet = (try? encoder.encode(frame.samples)) ?? nil else { continue }
            // Closing waits for any send already underway, and fences queued work.
            sending.withLock {
                guard admission.withLock({ !stopped }) else { return }
                output.send(.deviceAudio(device: device, micros: frame.micros, data: packet))
            }
        }
    }
}
#endif
