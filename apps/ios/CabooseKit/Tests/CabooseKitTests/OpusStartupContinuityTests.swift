import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import CabooseKit

/// Generated PCM only: retain both codec states across the server's suppressed silence.
/// No renderer, session activation, network, recording or real-time sleep.
@Suite struct OpusStartupContinuityTests {
    @Test func initialToneIsNumericallyCleanIncludingTheFirstHundredMilliseconds() throws {
        let stream = try GeneratedStream()
        let samples = try stream.segment(packets: 25, amplitude: 0.25)
        checkTone(samples, label: "initial")
    }

    @Test func longSuppressedSilenceResumesWithTheRetainedEncoderAndDecoder() throws {
        let stream = try GeneratedStream()
        checkTone(try stream.segment(packets: 25, amplitude: 0.25), label: "initial")
        // encode_loop sends fifty silent blocks, then skips encode entirely. Neither
        // codec sees the following twenty seconds; only the packet timeline advances.
        let silence = try stream.segment(packets: 50, amplitude: 0)
        #expect(silence.suffix(4800).allSatisfy { abs($0) < 0.001 })
        var timeline = AudioPacketTimeline()
        let before = timeline.place(server: 1_000_000, frames: 960)
        let resumed = timeline.place(server: 21_020_000, frames: 960)
        #expect(before == 1_000_000 && resumed == 21_020_000)
        // No reset/new codec or supplied synthetic silence during the skipped interval.
        checkTone(try stream.segment(packets: 25, amplitude: 0.25), label: "resume")
    }

    private func checkTone(_ stereo: [Float], label: String) {
        #expect(stereo.count >= 2 * 4800)
        #expect(stereo.allSatisfy { $0.isFinite })
        let left = stride(from: 0, to: stereo.count, by: 2).map { Double(stereo[$0]) }
        let right = stride(from: 1, to: stereo.count, by: 2).map { Double(stereo[$0]) }
        #expect(zip(left, right).allSatisfy { abs($0 - $1) < 0.001 })
        // Include sample zero. The first window allows codec priming/transient energy;
        // no startup samples are discarded to make the signal appear clean.
        for begin in stride(from: 0, through: left.count - 4800, by: 4800) {
            let window = Array(left[begin..<(begin + 4800)])
            let count = Double(window.count)
            let rms = sqrt(window.reduce(0) { $0 + $1 * $1 } / count)
            let peak = window.map(abs).max() ?? 0
            // Phase-independent fit of the known 1 kHz signal, including startup.
            let sinPart = zip(window.indices, window).reduce(0.0) {
                $0 + $1.1 * sin(2 * .pi * 1000 * Double($1.0) / 48000)
            } * 2 / count
            let cosPart = zip(window.indices, window).reduce(0.0) {
                $0 + $1.1 * cos(2 * .pi * 1000 * Double($1.0) / 48000)
            } * 2 / count
            let residual = sqrt(zip(window.indices, window).reduce(0.0) {
                let phase = 2 * Double.pi * 1000 * Double($1.0) / 48000
                let error = $1.1 - sinPart * sin(phase) - cosPart * cos(phase)
                return $0 + error * error
            } / count)
            #expect(rms > 0.12 && rms < 0.23, "\(label) window\(begin): RMS \(rms)")
            #expect(peak < 0.4, "\(label) window\(begin): peak \(peak)")
            #expect(residual < 0.08, "\(label) window\(begin): residual \(residual)")
        }
        let largestStep = zip(left, left.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        #expect(largestStep < 0.12, "\(label): sample/buffer-boundary step \(largestStep)")
    }

    private final class GeneratedStream {
        let pcm: AVAudioFormat
        let encoder: AVAudioConverter
        let opus: AVAudioFormat
        let decoder: OpusDecoder
        var sourceFrame = 0

        init() throws {
            pcm = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
                                             channels: 2, interleaved: false))
            var description = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatOpus,
                mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 960, mBytesPerFrame: 0,
                mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
            opus = try #require(AVAudioFormat(streamDescription: &description))
            encoder = try #require(AVAudioConverter(from: pcm, to: opus))
            decoder = try OpusDecoder(channels: 2)
        }

        func segment(packets: Int, amplitude: Float) throws -> [Float] {
            var output: [Float] = []
            for _ in 0..<packets {
                let input = try #require(AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 960))
                input.frameLength = 960
                for i in 0..<960 {
                    let value = amplitude * Float(sin(2 * Double.pi * 1000 * Double(sourceFrame + i) / 48000))
                    input.floatChannelData![0][i] = value
                    input.floatChannelData![1][i] = value
                }
                sourceFrame += 960
                let encoded = AVAudioCompressedBuffer(format: opus, packetCapacity: 1,
                                                       maximumPacketSize: max(1, encoder.maximumOutputPacketSize))
                var supplied = false
                var error: NSError?
                let status = encoder.convert(to: encoded, error: &error) { _, state in
                    if supplied { state.pointee = .noDataNow; return nil }
                    supplied = true; state.pointee = .haveData; return input
                }
                #expect(status != .error)
                if encoded.packetCount > 0 {
                    let decoded = try decoder.decode(Data(bytes: encoded.data, count: Int(encoded.byteLength)))
                    #expect(decoded.format.isInterleaved && decoded.format.channelCount == 2)
                    #expect(decoded.format.sampleRate == 48000)
                    #expect(decoded.audioBufferList.pointee.mBuffers.mDataByteSize == decoded.frameLength * 8)
                    output.append(contentsOf: UnsafeBufferPointer(start: decoded.floatChannelData![0],
                                                                   count: Int(decoded.frameLength) * 2))
                }
            }
            return output
        }
    }
}
