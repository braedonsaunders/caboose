import AVFoundation
import Foundation

/// Cuts a stream of mono samples into 20 ms Opus frames (960 samples at 48 kHz), keeping
/// the time of each frame's first sample.
public struct PCMFramer: Sendable {
    public static let frameSamples = 960
    public static let sampleRate = 48_000.0

    private var pending: [Float] = []
    /// The time of `pending`'s first sample, in microseconds.
    private var pendingStart: UInt64?

    public init() {}

    /// Appends samples whose first was captured at `micros`; returns the whole frames now ready.
    public mutating func append(_ samples: [Float], at micros: UInt64) -> [(micros: UInt64, samples: [Float])] {
        if pending.isEmpty { pendingStart = micros }
        pending += samples
        var frames: [(micros: UInt64, samples: [Float])] = []
        while pending.count >= Self.frameSamples, let start = pendingStart {
            frames.append((start, Array(pending.prefix(Self.frameSamples))))
            pending.removeFirst(Self.frameSamples)
            pendingStart = start + UInt64(Double(Self.frameSamples) / Self.sampleRate * 1_000_000)
        }
        return frames
    }

    public mutating func reset() {
        pending.removeAll()
        pendingStart = nil
    }
}

/// Encodes 20 ms frames of 48 kHz mono float PCM to Opus with the system's own encoder
/// (AudioToolbox), the counterpart of `OpusDecoder`.
public final class OpusEncoder {
    public enum Failure: Error { case unsupported, encode(String) }

    private let pcmFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let opusFormat: AVAudioFormat

    public init(bitRate: Int = 32_000) throws {
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: PCMFramer.sampleRate, channels: 1, interleaved: true)
        else { throw Failure.unsupported }
        var description = AudioStreamBasicDescription(
            mSampleRate: PCMFramer.sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(PCMFramer.frameSamples), mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        guard let opus = AVAudioFormat(streamDescription: &description), let converter = AVAudioConverter(from: pcm, to: opus) else {
            throw Failure.unsupported
        }
        converter.bitRate = bitRate
        pcmFormat = pcm
        opusFormat = opus
        self.converter = converter
    }

    /// One 960-sample frame to its Opus packet; nil while the encoder is still taking in its
    /// first samples and has none to give.
    public func encode(_ samples: [Float]) throws -> Data? {
        guard samples.count == PCMFramer.frameSamples,
              let input = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw Failure.encode("a frame is \(PCMFramer.frameSamples) samples") }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let output = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 1, maximumPacketSize: converter.maximumOutputPacketSize)
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        if status == .error { throw Failure.encode(error?.localizedDescription ?? "Opus encode failed") }
        guard output.packetCount >= 1, output.byteLength > 0 else { return nil }
        let size = output.packetDescriptions.map { Int($0[0].mDataByteSize) } ?? Int(output.byteLength)
        return Data(bytes: output.data, count: min(size, Int(output.byteLength)))
    }
}

/// A depth picture as the computer reads it: little-endian u16 millimetres, 0 for no reading.
public enum DepthPicture {
    public static func millimetres(fromMetres metres: [Float]) -> Data {
        var out = Data(capacity: metres.count * 2)
        for value in metres {
            let mm: UInt16
            if value.isFinite, value > 0 {
                mm = UInt16(min(Float(UInt16.max), (value * 1000).rounded()))
            } else {
                mm = 0
            }
            out.append(UInt8(mm & 0xFF))
            out.append(UInt8(mm >> 8))
        }
        return out
    }
}
