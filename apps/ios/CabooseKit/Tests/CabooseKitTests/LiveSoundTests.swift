import AVFoundation
import CoreVideo
import Foundation
import QuartzCore
import Testing
@testable import CabooseKit

/// The computer's sound against a real caboose-display whose page beeps once a second and
/// flashes the whole window with each beep (the compositor's `sound` test page):
///
///     CABOOSE_DISPLAY_URL=ws://box:14600/ CABOOSE_DISPLAY_TOKEN=… CABOOSE_SOUND_CHECK=1 \
///       swift test --filter LiveSound
///
/// Plays the sound through the app's own player and clock (so decode errors, gaps and
/// underruns are real), and measures each beep against its flash: on the server's clock (the
/// computer's own sync) and as this client would show them (sound after the playout delay,
/// window pictures on arrival).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CABOOSE_SOUND_CHECK"] != nil))
struct LiveSoundTests {
    final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var audio: [(pts: Int64, arrival: Int64, data: Data, channels: Int)] = []
        var frames: [(window: Int, pts: Int64, arrival: Int64, frame: EncodedFrame)] = []
        var windows: [Int: String] = [:]
        var ready = false
    }

    static func micros() -> Int64 { Int64(CACurrentMediaTime() * 1_000_000) }

    @Test func soundPlaysAndLinesUpWithThePicture() async throws {
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
                    token: environment["CABOOSE_DISPLAY_TOKEN"] ?? "", decoders: [.h264],
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
                    case .frame(let frame):
                        recorder.frames.append((frame.window, Int64(frame.ptsMicros), arrival, frame))
                        stream.send(DisplayFraming.encode(ClientMessage.ack(window: frame.window, ptsMicros: frame.ptsMicros, decodedMicros: 1000).frame))
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

        // Flash starts on the server clock, from the decoded window pictures (centre brightness).
        let page = recorder.windows.first { $0.value.lowercased().contains("sound") }?.key ?? 2
        let video = H264Decoder(codec: .h264)
        var flashes: [(pts: Int64, arrival: Int64)] = []
        var lit = false
        for entry in recorder.frames where entry.window == page && entry.frame.codec == .h264 {
            guard let picture = try? video.decode(entry.frame.data) else { continue }
            let bright = Self.brightness(picture) > 0.5
            if bright, !lit { flashes.append((entry.pts, entry.arrival)) }
            lit = bright
        }
        print("beeps at \(onsets.map { $0 / 1000 }) ms, flashes at \(flashes.map { $0.pts / 1000 }) ms (server clock)")

        // Pair each flash with the nearest beep: the computer's own sync, and what this client
        // shows (sound at its arrival + playout delay, the picture on arrival).
        let anchorArrival = audio.first.map { $0.arrival - $0.pts } ?? 0
        var source: [Int64] = [], shown: [Int64] = []
        for flash in flashes {
            guard let beep = onsets.min(by: { abs($0 - flash.pts) < abs($1 - flash.pts) }), abs(beep - flash.pts) < 500_000 else { continue }
            source.append(beep - flash.pts)
            shown.append((beep + anchorArrival + clock.delay) - flash.arrival)
        }
        print("sound after flash, server clock: \(source.map { $0 / 1000 }) ms")
        print("sound after flash, as shown here: \(shown.map { $0 / 1000 }) ms")
        #expect(!source.isEmpty)
    }

    /// Mean luma of the picture's centre, 0…1, from a BGRA or YUV buffer.
    static func brightness(_ picture: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(picture, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(picture, .readOnly) }
        let width = CVPixelBufferGetWidth(picture), height = CVPixelBufferGetHeight(picture)
        guard let base = CVPixelBufferGetBaseAddress(picture) else { return 0 }
        let row = CVPixelBufferGetBytesPerRow(picture)
        var total = 0.0, count = 0.0
        for y in stride(from: height / 3, to: 2 * height / 3, by: 8) {
            for x in stride(from: width / 3, to: 2 * width / 3, by: 8) {
                let pixel = base.advanced(by: y * row + x * 4).assumingMemoryBound(to: UInt8.self)
                total += (0.114 * Double(pixel[0]) + 0.587 * Double(pixel[1]) + 0.299 * Double(pixel[2])) / 255
                count += 1
            }
        }
        return count > 0 ? total / count : 0
    }
}
