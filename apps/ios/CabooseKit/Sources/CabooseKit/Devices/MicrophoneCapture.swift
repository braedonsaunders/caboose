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
    private var previous: (category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions)?
    private var pipeline: MicrophonePipeline?
    private var interruption: NSObjectProtocol?
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
        if let interruption { NotificationCenter.default.removeObserver(interruption) }
        interruption = nil
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        pipeline = nil
        device = nil
        failed = nil
        restoreSession()
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
            if previous == nil { previous = (audio.category, audio.mode, audio.categoryOptions) }
            try audio.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP])
            try audio.setActive(true)
            let engine = AVAudioEngine()
            let input = engine.inputNode
            try input.setVoiceProcessingEnabled(true)
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { return fail("No microphone is available.") }
            guard let pipeline = MicrophonePipeline(input: format, device: device, output: output) else {
                return fail("The microphone's sound cannot be encoded on this iPhone.")
            }
            input.installTap(onBus: 0, bufferSize: 960, format: format) { buffer, time in pipeline.append(buffer, at: time) }
            engine.prepare()
            try engine.start()
            self.engine = engine
            self.pipeline = pipeline
            interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
                MainActor.assumeIsolated {
                    guard let self, let engine = self.engine, type == .ended else { return }
                    // A call or Siri took the microphone; it comes back when they end.
                    try? AVAudioSession.sharedInstance().setActive(true)
                    if !engine.isRunning { try? engine.start() }
                }
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func restoreSession() {
        guard let previous else { return }
        self.previous = nil
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(previous.category, mode: previous.mode, options: previous.options)
        try? audio.setActive(true)
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
        guard let copy = buffer.copy() as? AVAudioPCMBuffer else { return }
        queue.async { self.convert(copy, at: micros) }
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
            output.send(.deviceAudio(device: device, micros: frame.micros, data: packet))
        }
    }
}
#endif
