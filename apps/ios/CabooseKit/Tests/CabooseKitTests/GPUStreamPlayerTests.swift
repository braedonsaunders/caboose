#if canImport(CabooseGPUStream)
import Foundation
import QuartzCore
import Testing
@testable import CabooseKit

/// GPU stream replay (docs/gpu-stream.md): GFXReconstruct's replay through MoltenVK into a
/// layer that is on no screen. Runs where scripts/build-gpu-stream.sh has built the player.
/// `CABOOSE_GPU_CAPTURE=path.gfxr` replays a real capture (with
/// `CABOOSE_GPU_CAPTURE_FRAMES=N` to require its frame count).
@Suite(.serialized, .timeLimit(.minutes(2)))
struct GPUStreamPlayerTests {
    private struct Replay {
        var events: [GPUStreamPlayer.Event] = []
        var frames: UInt64
        var state: GPUStreamPlayer.State
    }

    /// Feeds `chunks` to a new player, ends the stream and collects every event up to the end.
    private func replay(_ chunks: [Data]) async -> Replay {
        let (events, continuation) = AsyncStream.makeStream(of: GPUStreamPlayer.Event.self)
        let player = GPUStreamPlayer(layer: CAMetalLayer(), queue: DispatchQueue(label: "gpu-stream-test")) { event in
            continuation.yield(event)
            if case .ended = event { continuation.finish() }
        }
        for chunk in chunks { player.feed(chunk) }
        player.finish()
        var replay = Replay(frames: 0, state: .running)
        for await event in events { replay.events.append(event) }
        replay.frames = player.framesRendered
        replay.state = player.state
        return replay
    }

    @Test func anEmptyStreamFails() async {
        let replay = await replay([])
        #expect(replay.state == .failed("The stream does not start with a GFXReconstruct file header"))
        #expect(replay.events == [.ended(replay.state)])
        #expect(replay.frames == 0)
    }

    @Test func bytesThatAreNotACaptureFail() async {
        let replay = await replay([Data(repeating: 0x5A, count: 4096)])
        guard case .failed(let reason) = replay.state else {
            Issue.record("replay ended \(replay.state)")
            return
        }
        #expect(!reason.isEmpty)
        #expect(replay.events.last == .ended(replay.state))
        #expect(replay.frames == 0)
    }

    @Test func aStoppedPlayerRefusesItsStream() async {
        let (events, continuation) = AsyncStream.makeStream(of: GPUStreamPlayer.Event.self)
        let player = GPUStreamPlayer(layer: CAMetalLayer(), queue: DispatchQueue(label: "gpu-stream-test")) { event in
            continuation.yield(event)
            if case .ended = event { continuation.finish() }
        }
        player.stop()
        player.feed(Data(repeating: 0, count: 1024))
        var ended: [GPUStreamPlayer.Event] = []
        for await event in events { ended.append(event) }
        #expect(ended == [.ended(.finished)])
        #expect(player.consumedBytes == 0)
    }

    @Test func aSecondPlayerWaitsForTheFirst() async {
        let first = GPUStreamPlayer(layer: CAMetalLayer())
        let second = GPUStreamPlayer(layer: CAMetalLayer())
        second.finish()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(second.state == .running)
        first.stop()
        #expect(await first.waitUntilEnded() == .finished)
        #expect(await second.waitUntilEnded() == .failed("The stream does not start with a GFXReconstruct file header"))
    }

    private func discardPending(_ player: GPUStreamPlayer) async -> UInt64? {
        await withCheckedContinuation { continuation in player.discardPending { continuation.resume(returning: $0) } }
    }

    /// A running replay that took nothing accepted offset 0; a stopped one cannot continue.
    @Test func discardingReportsWhatTheReplayAccepted() async {
        let player = GPUStreamPlayer(layer: CAMetalLayer(), queue: DispatchQueue(label: "gpu-stream-test"))
        #expect(await discardPending(player) == 0)
        player.stop()
        _ = await player.waitUntilEnded()
        #expect(await discardPending(player) == nil)
    }

    private static var capture: Data? {
        ProcessInfo.processInfo.environment["CABOOSE_GPU_CAPTURE"].flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
    }

    private static func chunks(of data: Data, size: Int = 64 * 1024) -> [Data] {
        stride(from: data.startIndex, to: data.endIndex, by: size).map { data.subdata(in: $0 ..< min($0 + size, data.endIndex)) }
    }

    /// Plays `player` to its end, checking every frame of the capture replays.
    private func expectEveryFrame(_ player: GPUStreamPlayer, _ events: AsyncStream<GPUStreamPlayer.Event>) async {
        var last: GPUStreamPlayer.Event?
        for await event in events { last = event }
        #expect(last == .ended(.finished))
        #expect(player.state == .finished)
        if let expected = ProcessInfo.processInfo.environment["CABOOSE_GPU_CAPTURE_FRAMES"].flatMap(UInt64.init) {
            #expect(player.framesRendered == expected)
        }
    }

    /// The resume path: bytes handed over but not taken are dropped, and feeding the stream again
    /// from the offset the replay accepted replays every frame.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CABOOSE_GPU_CAPTURE"] != nil))
    func aReplayContinuesFromWhatItAccepted() async throws {
        let capture = try #require(Self.capture)
        let (events, continuation) = AsyncStream.makeStream(of: GPUStreamPlayer.Event.self)
        let player = GPUStreamPlayer(layer: CAMetalLayer(), queue: DispatchQueue(label: "gpu-stream-test")) { event in
            continuation.yield(event)
            if case .ended = event { continuation.finish() }
        }
        for chunk in Self.chunks(of: capture.prefix(capture.count / 2)) { player.feed(chunk) }
        let accepted = try #require(await discardPending(player))
        #expect(accepted <= UInt64(capture.count / 2))
        for chunk in Self.chunks(of: capture.dropFirst(Int(accepted))) { player.feed(chunk) }
        player.finish()
        await expectEveryFrame(player, events)
    }

    /// The device's copy: the start of the stream from a file, at the replay's pace, then the
    /// rest as from the connection.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CABOOSE_GPU_CAPTURE"] != nil))
    func aReplayTakesTheStreamsStartFromAFile() async throws {
        let capture = try #require(Self.capture)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("gpu-stream-\(UUID().uuidString)")
        try capture.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let (events, continuation) = AsyncStream.makeStream(of: GPUStreamPlayer.Event.self)
        let player = GPUStreamPlayer(layer: CAMetalLayer(), queue: DispatchQueue(label: "gpu-stream-test")) { event in
            continuation.yield(event)
            if case .ended = event { continuation.finish() }
        }
        let half = UInt64(capture.count / 2)
        let accepted = await withCheckedContinuation { done in
            player.feed(contentsOf: file, length: half) { done.resume(returning: $0) }
        }
        #expect(accepted == half)
        for chunk in Self.chunks(of: capture.dropFirst(Int(half))) { player.feed(chunk) }
        player.finish()
        await expectEveryFrame(player, events)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CABOOSE_GPU_CAPTURE"] != nil))
    func aCaptureReplaysEveryFrame() async throws {
        let environment = ProcessInfo.processInfo.environment
        let capture = try Data(contentsOf: URL(fileURLWithPath: environment["CABOOSE_GPU_CAPTURE"]!))
        let chunk = 64 * 1024
        let chunks = stride(from: 0, to: capture.count, by: chunk).map {
            capture.subdata(in: $0 ..< min($0 + chunk, capture.count))
        }
        let started = ContinuousClock.now
        let replay = await replay(chunks)
        let elapsed = ContinuousClock.now - started

        #expect(replay.state == .finished)
        #expect(replay.frames > 0)
        if let expected = environment["CABOOSE_GPU_CAPTURE_FRAMES"].flatMap(UInt64.init) {
            #expect(replay.frames == expected)
        }
        let frameEvents = replay.events.compactMap { event -> UInt64? in
            if case .frame(let frame) = event { frame } else { nil }
        }
        #expect(frameEvents == Array(stride(from: 1, through: replay.frames, by: 1)))
        let consumed = replay.events.compactMap { event -> UInt64? in
            if case .consumed(let bytes) = event { bytes } else { nil }
        }
        #expect(consumed.last == UInt64(capture.count))
        #expect(replay.events.last == .ended(.finished))
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("GPU stream: \(replay.frames) frames from \(capture.count) bytes in \(String(format: "%.2f", seconds)) s"
            + " (\(String(format: "%.0f", Double(replay.frames) / seconds)) frames/s)")
    }
}
#endif
