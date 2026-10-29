import AVFoundation
import CoreMedia
import Foundation

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
    private let queue = DispatchQueue(label: "caboose.display.sound", qos: .userInteractive)
    // On `queue`:
    private var decoder: OpusDecoder?
    private var format: CMAudioFormatDescription?
    private var sessionActive = false
    private var interrupted = false
    private var interruptionObserver: NSObjectProtocol?
    private(set) var played = 0
    private(set) var failed = 0

    init(clock: MediaClock, activate: @escaping () throws -> Void = {
        #if os(iOS)
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
    }) {
        self.clock = clock
        self.activate = activate
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
        clock.remove(renderer)
    }

    private func setInterrupted(_ value: Bool) {
        queue.async { [self] in
            interrupted = value
            sessionActive = false
            renderer.flush()
            clock.stop()
        }
    }

    func play(_ packet: AudioPacket) {
        queue.async { [self] in
            guard packet.codec == "opus", !interrupted else { return }
            do {
                if decoder?.channels != packet.channels {
                    decoder = try OpusDecoder(channels: packet.channels)
                    format = nil
                }
                guard let decoder else { return }
                let pcm = try decoder.decode(packet.data)
                guard pcm.frameLength > 0 else { return }
                try activateSession()
                if renderer.status == .failed {
                    renderer.flush()
                    clock.stop()
                }
                let placement = clock.place(audio: Int64(packet.ptsMicros))
                if case .restart = placement { renderer.flush() }
                renderer.enqueue(try sample(pcm, decoder: decoder, pts: Int64(packet.ptsMicros)))
                switch placement {
                case .play: break
                case .start(let time), .restart(let time): clock.start(at: time)
                }
                played += 1
            } catch {
                failed += 1
            }
        }
    }

    func stop() {
        queue.async { [self] in
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
