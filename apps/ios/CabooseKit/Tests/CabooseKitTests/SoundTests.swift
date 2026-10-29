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
        #expect(playout.place(pts: 100_000, now: 105_000) == .restart(100_000 - PlayoutDelay.initial - PlayoutDelay.step))
        #expect(playout.delay == PlayoutDelay.initial + PlayoutDelay.step)
        for _ in 0 ..< 20 { _ = playout.place(pts: 0, now: 1) }
        #expect(playout.delay == PlayoutDelay.maximum)
    }

    @Test func aBacklogIsDroppedAndGapsRunThrough() {
        var playout = PlayoutDelay()
        _ = playout.place(pts: 0, now: nil)
        // Five seconds of silence the server did not send: the clock ran on with it.
        #expect(playout.place(pts: 5_000_000, now: 4_970_000) == .play)
        // Packets far ahead of the clock (a burst after a stall): start again just behind them.
        #expect(playout.place(pts: 6_000_000, now: 5_400_000) == .restart(6_000_000 - PlayoutDelay.initial))
    }

    @Test func aStoppedClockIsStartedAgain() {
        var playout = PlayoutDelay()
        _ = playout.place(pts: 0, now: nil)
        playout.stop()
        #expect(playout.place(pts: 40_000, now: 10) == .start(40_000 - PlayoutDelay.initial))
    }
}

/// Scheduling policy only: no renderer is attached and no sound is decoded or played.
@Suite struct MediaClockSchedulingTests {
    @Test func packetsUseTheRequestedAnchorBeforeTheRenderTimebaseCatchesUp() {
        var host: Int64 = 10_000_000
        let clock = MediaClock(hostTime: { CMTime(value: host, timescale: 1_000_000) })
        let first: Int64 = 90_000_000_000
        #expect(!clock.synchronizer.delaysRateChangeUntilHasSufficientMediaData)
        #expect(clock.now == nil)
        #expect(clock.place(audio: first) == .start(first - PlayoutDelay.initial))
        clock.start(at: first - PlayoutDelay.initial)
        // Do not wait for AVFoundation's asynchronous timebase update. A real-time stream
        // must not flush on each packet just because its rate is set before its time is.
        for index in 0 ..< 100 {
            host = 10_000_000 + Int64(index) * 20_000
            let pts = first + Int64(index) * 20_000
            #expect(clock.now == pts - PlayoutDelay.initial)
            #expect(clock.place(audio: pts) == .play)
            #expect(clock.time(for: pts) == CMTime(value: pts, timescale: 1_000_000))
            #expect(clock.time(for: pts - PlayoutDelay.initial - 1) == nil)
        }
        #expect(clock.delay == PlayoutDelay.initial)
        clock.stop()
    }

    @Test func aLatePacketReanchorsOnceAndFollowingPacketsKeepPlaying() {
        var host: Int64 = 10_000_000
        let clock = MediaClock(hostTime: { CMTime(value: host, timescale: 1_000_000) })
        _ = clock.place(audio: 1_000_000)
        clock.start(at: 1_000_000 - PlayoutDelay.initial)
        host += 200_000
        #expect(clock.place(audio: 1_020_000) == .restart(1_020_000 - PlayoutDelay.initial - PlayoutDelay.step))
        clock.start(at: 1_020_000 - PlayoutDelay.initial - PlayoutDelay.step)
        // This anchor moves backwards from the old projected time. Neither that old
        // time nor AVFoundation's delayed application can cause a second restart.
        for index in 1 ... 10 {
            host = 10_200_000 + Int64(index) * 20_000
            #expect(clock.place(audio: 1_020_000 + Int64(index) * 20_000) == .play)
        }
        #expect(clock.delay == PlayoutDelay.initial + PlayoutDelay.step)
        clock.stop()
    }

    @Test func backlogRecoverySilenceAndStopUseTheSameTimeline() {
        var host: Int64 = 10_000_000
        let clock = MediaClock(hostTime: { CMTime(value: host, timescale: 1_000_000) })
        _ = clock.place(audio: 1_000_000)
        clock.start(at: 1_000_000 - PlayoutDelay.initial)
        host += 20_000
        #expect(clock.place(audio: 1_500_000) == .restart(1_500_000 - PlayoutDelay.initial))
        clock.start(at: 1_500_000 - PlayoutDelay.initial)
        host += 20_000
        #expect(clock.place(audio: 1_520_000) == .play)
        host += 5_000_000
        #expect(clock.place(audio: 6_520_000) == .play)
        #expect(clock.delay == PlayoutDelay.initial)
        clock.stop()
        #expect(clock.now == nil)
        #expect(clock.time(for: 6_520_000) == nil)
        #expect(clock.place(audio: 6_540_000) == .start(6_540_000 - PlayoutDelay.initial))
    }

    @Test func repeatedRealUnderrunsKeepTheDelayBounded() {
        var host: Int64 = 10_000_000
        var pts: Int64 = 1_000_000
        let clock = MediaClock(hostTime: { CMTime(value: host, timescale: 1_000_000) })
        _ = clock.place(audio: pts)
        clock.start(at: pts - PlayoutDelay.initial)
        for _ in 0 ..< 20 {
            host += 300_000
            pts += 20_000
            let placement = clock.place(audio: pts)
            #expect(placement == .restart(pts - clock.delay))
            #expect(clock.delay <= PlayoutDelay.maximum)
            clock.start(at: pts - clock.delay)
        }
        #expect(clock.delay == PlayoutDelay.maximum)
        host += 20_000
        #expect(clock.place(audio: pts + 20_000) == .play)
        clock.stop()
    }
}

@Suite struct AudioPacketTimelineTests {
    @Test func burstyCaptureTimestampsProduceContiguousSamples() {
        var timeline = AudioPacketTimeline()
        let first: Int64 = 90_000_000_000
        // Captured pipe reads can cluster, then stall for two packet durations.
        let jitter: [Int64] = [0, 20_000, 141, 22_075, 0, -10_000, 10_000]
        for index in 0 ..< 300 {
            let expected = first + Int64(index) * 20_000
            #expect(timeline.place(server: expected + jitter[index % jitter.count], frames: 960) == expected)
        }
    }

    @Test func durationComesFromDecodedSamples() {
        var timeline = AudioPacketTimeline()
        #expect(timeline.place(server: 1_000_000, frames: 480) == 1_000_000)
        #expect(timeline.place(server: 1_015_000, frames: 2880) == 1_010_000)
        #expect(timeline.place(server: 1_065_000, frames: 960) == 1_070_000)
    }

    @Test func silenceDiscontinuitiesAndResetKeepTheServerTimeline() {
        var timeline = AudioPacketTimeline()
        #expect(timeline.place(server: 1_000_000, frames: 960) == 1_000_000)
        #expect(timeline.place(server: 6_000_000, frames: 960) == 6_000_000)
        #expect(timeline.place(server: 2_000_000, frames: 960) == 2_000_000)
        timeline.reset()
        #expect(timeline.place(server: 2_050_000, frames: 960) == 2_050_000)
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
        guard case .audio(let packet)? = try parser.append(try DisplayVectorTests.vector("audio-opus").wire).first.map(ServerMessage.init) else {
            Issue.record("no audio packet"); return
        }
        let decoder = try OpusDecoder(channels: 1) // the vector's packet is mono
        let pcm = try decoder.decode(packet.data)
        #expect(pcm.frameLength > 0 && pcm.frameLength <= 960)
        let samples = UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength))
        #expect(samples.allSatisfy { abs($0) < 0.001 })
    }

    /// A real 20 ms stereo packet from the server's libopus encoder, through the system decoder.
    @Test(.enabled(if: DisplayVectorTests.names.contains("audio-opus-stereo")))
    func theServersStereoPacketDecodes() throws {
        var parser = DisplayFrameParser()
        guard case .audio(let packet)? = try parser.append(try DisplayVectorTests.vector("audio-opus-stereo").wire).first.map(ServerMessage.init) else {
            Issue.record("no audio packet"); return
        }
        #expect(packet.channels == 2)
        let pcm = try OpusDecoder(channels: packet.channels).decode(packet.data)
        #expect(pcm.frameLength > 0 && pcm.frameLength <= 960)
        let samples = UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength) * 2)
        #expect(samples.contains { abs($0) > 0.01 }, "a tone, not silence")
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
        var crossings = 0
        for (before, after) in zip(steady, steady.dropFirst()) {
            if (before < 0 && after >= 0) || (before >= 0 && after < 0) {
                crossings += 1
            }
        }
        let perMillisecond = Double(crossings) / (Double(steady.count) / 48)
        #expect(abs(perMillisecond - 2) < 0.1, "\(perMillisecond) crossings/ms")
    }
}

@Suite(.serialized) struct SoundPlaybackTests {
    @Test func packetsPlayOnTheClockBehindTheServer() async throws {
        let clock = MediaClock()
        let player = SoundPlayer(clock: clock)
        player.renderer.isMuted = true // the renderer still plays the timeline; the Mac stays quiet
        let start: Int64 = 50_000_000
        // This test enqueues a burst: stay within the 300 ms backlog allowance. Longer
        // bursts intentionally reanchor; real-time delivery is exercised separately.
        let packets = try Tone.packets(7)
        let before = Date()
        for (index, packet) in packets.enumerated() {
            player.play(AudioPacket(ptsMicros: UInt64(start + Int64(index) * 20_000), data: packet))
        }
        player.flush()
        #expect(player.played == 7 && player.failed == 0)
        // The clock started 120 ms behind the first packet and has run in real time since, never restarted.
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

    @Test func failedSessionActivationIsRetriedBeforePlaying() throws {
        enum ActivationError: Error { case unavailable }
        var attempts = 0
        let clock = MediaClock()
        let player = SoundPlayer(clock: clock, activate: {
            attempts += 1
            if attempts == 1 { throw ActivationError.unavailable }
        })
        player.renderer.isMuted = true
        let packets = try Tone.packets(3)
        player.play(AudioPacket(ptsMicros: 10_000_000, data: packets[0]))
        player.flush()
        #expect(attempts == 1 && player.failed == 1 && player.played == 0)
        #expect(clock.now == nil)
        player.play(AudioPacket(ptsMicros: 10_020_000, data: packets[1]))
        player.play(AudioPacket(ptsMicros: 10_040_000, data: packets[2]))
        player.flush()
        #expect(attempts == 2 && player.failed == 1 && player.played == 2)
        #expect(clock.now != nil)
        player.stop()
        player.flush()
    }

    @Test func packetsArrivingInRealTimeNeverRestartTheClock() async throws {
        let clock = MediaClock()
        let player = SoundPlayer(clock: clock)
        player.renderer.isMuted = true // the renderer still plays the timeline; the Mac stays quiet
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
        guard case .frame(let keyframe)? = try parser.append(try DisplayVectorTests.vector("frame-h264-keyframe").wire).first.map(ServerMessage.init) else {
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
        player.renderer.isMuted = true
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


/// No renderer or sound: replay independent sample/host clocks and TCP delivery batches.
@Suite struct AudioClockRecoveryTests {
    @Test func aFastVirtualGuestDoesNotKeepFlushingItsSound() {
        replay(rate: 1.083, batch: 140_000)
    }

    @Test func slowAndMatchedClocksStayBounded() {
        replay(rate: 0.94, batch: 100_000)
        replay(rate: 1, batch: 140_000)
    }

    private func replay(rate: Double, batch: Int64) {
        var host: Int64 = 0
        let clock = MediaClock(hostTime: { CMTime(value: host, timescale: 1_000_000) })
        var restarts = 0, lateRestarts = 0
        var largestAhead: Int64 = 0
        for index in 0..<3000 {
            let media = Int64(index) * 20_000
            let ideal = Int64(Double(media) / rate)
            host = ((ideal + batch - 1) / batch) * batch
            let pts = 1_000_000_000 + media
            let placement = clock.place(audio: pts)
            switch placement {
            case .start(let anchor): clock.start(at: anchor)
            case .restart(let anchor):
                restarts += 1
                if index > 1000 { lateRestarts += 1 }
                clock.start(at: anchor)
            case .play: break
            }
            if let now = clock.now { largestAhead = max(largestAhead, pts - now) }
        }
        #expect(restarts <= 4, "\(rate): \(restarts) resets")
        #expect(lateRestarts == 0)
        #expect(abs(clock.rate - rate) < 0.04)
        #expect(largestAhead < 500_000)
        clock.stop()
        #expect(clock.rate == 1)
    }

    @Test func gapsAndImplausibleRatesDoNotPoisonTheEstimate() {
        var recovery = AudioClockRecovery()
        for i in 0..<80 { _ = recovery.observe(pts: Int64(i) * 108_300, host: Int64(i) * 100_000, ahead: 120_000, target: 120_000) }
        #expect(abs(recovery.frequency - 1.083) < 0.002)
        #expect(recovery.observe(pts: 50_000_000, host: 50_000_000, ahead: 120_000, target: 120_000) == nil)
        for i in 1..<50 { _ = recovery.observe(pts: 50_000_000 + Int64(i) * 300_000, host: 50_000_000 + Int64(i) * 100_000, ahead: 120_000, target: 120_000) }
        #expect(abs(recovery.frequency - 1.083) < 0.002)
    }
}
