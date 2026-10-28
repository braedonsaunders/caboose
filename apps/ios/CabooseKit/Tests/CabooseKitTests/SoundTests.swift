import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import CabooseKit

/// The computer's sound on Caboose Display: the playout delay, Opus through the system decoder,
/// the audio renderer on the session's clock, and video pictures timed on the same clock.
@Suite struct PlayoutDelayTests {
    @Test func theFirstPacketStartsTheClockJustBehindIt() {
        var playout = PlayoutDelay()
        #expect(playout.place(pts: 1_000_000, now: nil) == .start(1_000_000 - PlayoutDelay.initial))
        #expect(playout.place(pts: 1_020_000, now: 990_000) == .play)
    }

    @Test func aLatePacketStartsAgainFurtherBehind() {
        var playout = PlayoutDelay()
        _ = playout.place(pts: 0, now: nil)
        #expect(playout.place(pts: 100_000, now: 105_000) == .restart(100_000 - 60_000))
        #expect(playout.delay == 60_000)
        for _ in 0 ..< 20 { _ = playout.place(pts: 0, now: 1) }
        #expect(playout.delay == PlayoutDelay.maximum)
    }

    @Test func aBacklogIsDroppedAndGapsRunThrough() {
        var playout = PlayoutDelay()
        _ = playout.place(pts: 0, now: nil)
        // Five seconds of silence the server did not send: the clock ran on with it.
        #expect(playout.place(pts: 5_000_000, now: 4_970_000) == .play)
        // Packets far ahead of the clock (a burst after a stall): start again just behind them.
        #expect(playout.place(pts: 6_000_000, now: 5_800_000) == .restart(6_000_000 - PlayoutDelay.initial))
    }

    @Test func aStoppedClockIsStartedAgain() {
        var playout = PlayoutDelay()
        _ = playout.place(pts: 0, now: nil)
        playout.stop()
        #expect(playout.place(pts: 40_000, now: 10) == .start(40_000 - PlayoutDelay.initial))
    }
}

/// Opus packets of a 1 kHz tone, made with the system's encoder.
enum Tone {
    static func packets(_ count: Int, channels: Int = 2, frequency: Double = 1000) throws -> [Data] {
        let pcm = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: AVAudioChannelCount(channels), interleaved: false))
        var description = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 960,
            mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        let opus = try #require(AVAudioFormat(streamDescription: &description))
        let encoder = try #require(AVAudioConverter(from: pcm, to: opus))
        var packets: [Data] = []
        var sample = 0
        while packets.count < count {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 960))
            buffer.frameLength = 960
            for i in 0 ..< 960 {
                let value = Float(sin(2 * Double.pi * frequency * Double(sample + i) / 48000)) * 0.5
                for channel in 0 ..< channels { buffer.floatChannelData![channel][i] = value }
            }
            sample += 960
            let out = AVAudioCompressedBuffer(format: opus, packetCapacity: 1, maximumPacketSize: max(1, encoder.maximumOutputPacketSize))
            var supplied = false
            var error: NSError?
            _ = encoder.convert(to: out, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true
                state.pointee = .haveData
                return buffer
            }
            if out.packetCount > 0 { packets.append(Data(bytes: out.data, count: Int(out.byteLength))) }
        }
        return packets
    }
}

@Suite struct OpusDecoderTests {
    @Test func theServersSilencePacketDecodesToSilence() throws {
        var parser = DisplayFrameParser()
        guard case .audio(let packet) = try parser.append(try DisplayVectorTests.vector("audio-opus").wire).first.map(ServerMessage.init) else {
            Issue.record("no audio packet"); return
        }
        let decoder = try OpusDecoder(channels: 1) // the vector's packet is mono
        let pcm = try decoder.decode(packet.data)
        #expect(pcm.frameLength > 0 && pcm.frameLength <= 960)
        let samples = UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength))
        #expect(samples.allSatisfy { abs($0) < 0.001 })
    }

    @Test func aToneComesBackAsTheTone() throws {
        let decoder = try OpusDecoder(channels: 2)
        var left: [Float] = []
        for packet in try Tone.packets(12) {
            let pcm = try decoder.decode(packet)
            let interleaved = UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength) * 2)
            left += stride(from: 0, to: interleaved.count, by: 2).map { interleaved[$0] }
        }
        let steady = Array(left.dropFirst(4800)) // past the codec's start-up
        #expect(steady.count > 4800)
        let peak = steady.map(abs).max() ?? 0
        #expect(peak > 0.4 && peak < 0.6, "peak \(peak)")
        // 1 kHz: two zero crossings a millisecond.
        let crossings = zip(steady, steady.dropFirst()).filter { $0 < 0 && $1 >= 0 || $0 >= 0 && $1 < 0 }.count
        let perMillisecond = Double(crossings) / (Double(steady.count) / 48)
        #expect(abs(perMillisecond - 2) < 0.1, "\(perMillisecond) crossings/ms")
    }
}

@Suite(.serialized) struct SoundPlaybackTests {
    @Test func packetsPlayOnTheClockBehindTheServer() async throws {
        let clock = MediaClock()
        let player = SoundPlayer(clock: clock)
        let start: Int64 = 50_000_000
        let packets = try Tone.packets(15)
        let before = Date()
        for (index, packet) in packets.enumerated() {
            player.play(AudioPacket(ptsMicros: UInt64(start + Int64(index) * 20_000), data: packet))
        }
        player.flush()
        #expect(player.played == 15 && player.failed == 0)
        // The clock started 40 ms behind the first packet and has run in real time since, never restarted.
        let now = try #require(clock.now)
        let elapsed = Int64(Date().timeIntervalSince(before) * 1_000_000)
        #expect(now > start - PlayoutDelay.initial && now <= start - PlayoutDelay.initial + elapsed + 10_000,
                "clock at \(now), \(elapsed) µs after the first packet")
        #expect(clock.delay == PlayoutDelay.initial)
        #expect(player.renderer.status != .failed, "\(String(describing: player.renderer.error))")
        try await Task.sleep(for: .milliseconds(200))
        #expect(player.renderer.status == .rendering)
        player.stop()
        player.flush()
        #expect(clock.now == nil)
    }

    @Test func packetsArrivingInRealTimeNeverRestartTheClock() async throws {
        let clock = MediaClock()
        let player = SoundPlayer(clock: clock)
        let packets = try Tone.packets(25)
        for (index, packet) in packets.enumerated() {
            player.play(AudioPacket(ptsMicros: UInt64(80_000_000 + index * 20_000), data: packet))
            try await Task.sleep(for: .milliseconds(20))
        }
        player.flush()
        #expect(player.played == 25 && player.failed == 0)
        #expect(clock.delay == PlayoutDelay.initial)
        #expect(player.renderer.status == .rendering, "\(String(describing: player.renderer.error))")
        player.stop()
    }

    @Test func picturesAreTimedOnTheClockWhileSoundPlays() async throws {
        let clock = MediaClock()
        #expect(clock.time(for: 1) == nil) // stopped: pictures show at once
        if case .start(let time) = clock.place(audio: 10_000_000) { clock.start(at: time) }
        let now = try #require(clock.now)
        #expect(clock.time(for: now + 50_000) == CMTime(value: now + 50_000, timescale: 1_000_000))
        #expect(clock.time(for: now - 50_000) == nil) // late: at once

        // A live video stream on the running clock still reaches the screen.
        guard case .videoCreate(let fields) = VideoMessageTests.server(.videoCreate, [
            "id": 3, "window": 7, "rect": [0, 0, 64, 64], "codec": "h264", "source": "surface",
        ]) else { Issue.record("create"); return }
        let video = try #require(RemoteVideo(fields, clock: clock, send: { _ in }))
        var parser = DisplayFrameParser()
        guard case .frame(let keyframe) = try parser.append(try DisplayVectorTests.vector("frame-h264-keyframe").wire).first.map(ServerMessage.init) else {
            Issue.record("keyframe"); return
        }
        let pts = UInt64((clock.now ?? 0) + 60_000)
        video.frame(VideoFrame(video: 3, seq: 0, keyframe: true, ptsMicros: pts, data: keyframe.data))
        video.flush()
        try await Task.sleep(for: .milliseconds(300))
        #expect(video.layer.sampleBufferRenderer.status == .rendering, "\(String(describing: video.layer.sampleBufferRenderer.error))")
        #expect(video.layer.isReadyForDisplay)
        video.close()
        clock.stop()
    }
}

@MainActor @Suite(.serialized) struct SoundSessionTests {
    @Test func helloAsksForSoundOnlyWhenTheSessionPlaysIt() async throws {
        let base = CabooseDisplaySessionTests()
        let session = base.makeSession()
        session.connect()
        base.stream.deliver(.opened)
        try await base.until("hello") { session.state == .authenticating }
        #expect(base.stream.take().first?.body["audio_decoders"] == ["opus"])

        let silent = CabooseDisplaySessionTests()
        let seat = silent.makeSession()
        seat.playsAudio = false
        seat.connect()
        silent.stream.deliver(.opened)
        try await silent.until("hello") { seat.state == .authenticating }
        #expect(silent.stream.take().first?.body["audio_decoders"] == nil)
        #expect(seat.sound == nil)
    }

    @Test func soundPacketsReachThePlayerAndStopWithTheSession() async throws {
        let base = CabooseDisplaySessionTests()
        let session = try await base.ready(features: ["vsync", "ack", "audio"])
        let player = try #require(session.sound)
        for (index, packet) in try Tone.packets(5).enumerated() {
            base.stream.server([(.audio, ["codec": "opus", "pts_us": CBOR(UInt64(9_000_000 + index * 20_000)), "channels": 2, "data": .bytes(packet)])])
        }
        player.flush()
        #expect(player.played == 5 && player.failed == 0)
        session.disconnect()
        player.flush()
        #expect(session.sound == nil)
    }
}
