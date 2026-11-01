import AVFoundation
import Foundation
import QuartzCore
import Testing
@testable import CabooseKit

/// The computer's sound against a real caboose-display whose page beeps once a second (the
/// compositor's `sound` test page):
///
///     CABOOSE_DISPLAY_URL=ws://box:14600/ CABOOSE_DISPLAY_TOKEN=… CABOOSE_SOUND_CHECK=1 \
///       swift test --filter LiveSound
///
/// Plays the sound through the app's own player and clock (so decode errors, gaps and
/// underruns are real), and finds each beep on the server's clock.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CABOOSE_SOUND_CHECK"] != nil))
struct LiveSoundTests {
    final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var audio: [(pts: Int64, arrival: Int64, data: Data, channels: Int)] = []
        var windows: [Int: String] = [:]
        var ready = false
    }

    static func micros() -> Int64 { Int64(CACurrentMediaTime() * 1_000_000) }

    @Test func soundPlaysOnTheServerClock() async throws {
        let environment = ProcessInfo.processInfo.environment
        let url = try #require(environment["CABOOSE_DISPLAY_URL"].flatMap(URL.init(string:)))
        let seconds = Double(environment["CABOOSE_VIDEO_SECONDS"] ?? "") ?? 8
        let recorder = Recorder()
        let clock = MediaClock()
        let player = SoundPlayer(clock: clock)
        player.renderer.isMuted = true // timing is measured on the renderer, not by ear
        let stream = WebSocketStream(url: url, token: "")
        var parser = DisplayFrameParser()
        stream.open { event in
            switch event {
            case .opened:
                stream.send(DisplayFraming.encode(ClientMessage.hello(
                    token: environment["CABOOSE_DISPLAY_TOKEN"] ?? "",
                    displays: [DisplayInfo(id: 0, width: 2560, height: 1600, scale: 2, refreshHz: 120)],
                    audioDecoders: ["opus"]).frame))
            case .data(let data):
                let arrival = Self.micros()
                for message in ((try? parser.append(data)) ?? []).map(ServerMessage.init) {
                    recorder.lock.lock()
                    switch message {
                    case .hello: recorder.ready = true
                    case .windowCreate(let fields): recorder.windows[fields.id] = fields.title ?? ""
                    case .audio(let packet):
                        recorder.audio.append((Int64(packet.ptsMicros), arrival, packet.data, packet.channels))
                        player.play(packet)
                    default: break
                    }
                    recorder.lock.unlock()
                }
            case .closed: break
            }
        }
        let end = Date().addingTimeInterval(seconds + 3)
        while Date() < end {
            stream.send(DisplayFraming.encode(ClientMessage.vsync(display: 0, micros: UInt64(Self.micros())).frame))
            try await Task.sleep(for: .milliseconds(8))
        }
        stream.close()
        player.flush()

        recorder.lock.lock(); defer { recorder.lock.unlock() }
        #expect(recorder.ready)
        print("windows \(recorder.windows)")

        // Sound: packets, gaps in the server's timestamps, decode errors and underruns.
        let audio = recorder.audio
        let gaps = zip(audio, audio.dropFirst()).filter { $1.pts - $0.pts > 25_000 }.count
        let jitter = zip(audio, audio.dropFirst()).map { ($1.arrival - $0.arrival) - ($1.pts - $0.pts) }
        print("sound: \(audio.count) packets, \(gaps) gaps, played \(player.played), failed \(player.failed), " +
              "playout delay \(clock.delay / 1000) ms, arrival jitter max \((jitter.map(abs).max() ?? 0) / 1000) ms, " +
              "renderer \(player.renderer.status.rawValue)")
        #expect(audio.count > 40 && player.failed == 0)

        // Beep onsets on the server clock, from the decoded sound.
        let decoder = try OpusDecoder(channels: audio.first?.channels ?? 2)
        var onsets: [Int64] = []
        var lastLoud: Int64?
        for packet in audio {
            let pcm = try decoder.decode(packet.data)
            let samples = UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength) * decoder.channels)
            for frame in 0 ..< Int(pcm.frameLength) where abs(samples[frame * decoder.channels]) > 0.05 {
                let time = packet.pts + Int64(frame) * 1_000_000 / 48000
                if lastLoud.map({ time - $0 > 300_000 }) ?? true { onsets.append(time) }
                lastLoud = time
            }
        }
        print("beeps at \(onsets.map { $0 / 1000 }) ms (server clock)")
        #expect(!onsets.isEmpty)
    }
}
