import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import CabooseKit

/// Video streams inside windows (docs/display.md "Video streams"): the messages, real pictures
/// decoded and shown through AVSampleBufferDisplayLayer, and the session keeping each window's
/// streams.
@Suite struct VideoMessageTests {
    static func server(_ type: DisplayProtocol.ServerType, _ body: CBOR) -> ServerMessage {
        ServerMessage(DisplayFrame(type: type.rawValue, body: body))
    }

    @Test func createUpdateFramePresentDestroy() {
        guard case .videoCreate(let create) = Self.server(.videoCreate, [
            "id": 3, "window": 7, "rect": [10, 20, 1280, 720], "clip": [10, 20, 1280, 600], "z": 1, "codec": "hevc",
            "source": "passthrough", "color": ["primaries": 9, "transfer": 16, "matrix": 9, "full_range": false],
        ]) else { Issue.record("create"); return }
        #expect(create.id == 3 && create.window == 7 && create.codec == .hevc && create.source == .passthrough && create.z == 1)
        #expect(create.rect == CGRect(x: 10, y: 20, width: 1280, height: 720) && create.clip == CGRect(x: 10, y: 20, width: 1280, height: 600))
        #expect(create.color?.isHDR == true)

        guard case .malformed = Self.server(.videoCreate, ["id": 3, "rect": [0, 0, 1, 1], "codec": "hevc"]) else {
            Issue.record("a stream without a window"); return
        }
        guard case .malformed = Self.server(.videoCreate, ["id": 3, "window": 7, "rect": [0, 0, 1, 1], "codec": "vp9"]) else {
            Issue.record("a codec the client did not offer"); return
        }
        guard case .videoUpdate(let update) = Self.server(.videoUpdate, ["id": 3, "z": -1]) else { Issue.record("update"); return }
        #expect(update.z == -1 && update.rect == nil)
        guard case .videoFrame(let live) = Self.server(.videoFrame, ["id": 2, "seq": 41, "pts_us": 40000, "keyframe": false, "data": .bytes(Data([1]))]) else {
            Issue.record("frame"); return
        }
        #expect(live.video == 2 && live.seq == 41 && live.ptsMicros == 40000 && !live.keyframe)
        guard case .videoFrame(let app) = Self.server(.videoFrame, ["id": 1, "seq": 0, "keyframe": true, "data": .bytes(Data([1]))]) else {
            Issue.record("passthrough frame"); return
        }
        #expect(app.ptsMicros == nil && app.seq == 0)
        guard case .videoPresent(1, 17, 1_234_633_333) = Self.server(.videoPresent, ["id": 1, "seq": 17, "pts_us": 1_234_633_333]) else {
            Issue.record("present"); return
        }
        guard case .videoDestroy(3) = Self.server(.videoDestroy, ["id": 3]) else { Issue.record("destroy"); return }
    }

    @Test func clientMessages() {
        #expect(ClientMessage.videoAck(video: 2, seq: 41).frame == DisplayFrame(type: 0x88, body: ["id": 2, "seq": 41]))
        #expect(ClientMessage.videoKeyframe(video: 3).frame == DisplayFrame(type: 0x89, body: ["id": 3]))
        #expect(ClientMessage.hello(token: "t", decoders: [.hevc], displays: []).frame.body["video_decoders"] == nil)
    }
}

@Suite(.serialized) struct VideoPlaybackTests {
    final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [ClientMessage] = []
        func append(_ message: ClientMessage) { lock.lock(); messages.append(message); lock.unlock() }
        var acks: [Int] { lock.lock(); defer { lock.unlock() }; return messages.compactMap { if case .videoAck(_, let seq) = $0 { seq } else { nil } } }
        var keyframeRequests: Int {
            lock.lock(); defer { lock.unlock() }
            return messages.filter { if case .videoKeyframe = $0 { true } else { false } }.count
        }
    }

    private func keyframe() throws -> Data {
        var parser = DisplayFrameParser()
        guard case .frame(let frame)? = try parser.append(try DisplayVectorTests.vector("frame-h264-keyframe").wire).first.map(ServerMessage.init) else {
            throw CancellationError()
        }
        return frame.data
    }

    private func video(source: String, codec: String = "h264", sent: Sent) throws -> RemoteVideo {
        guard case .videoCreate(let fields) = VideoMessageTests.server(.videoCreate, [
            "id": 3, "window": 7, "rect": [0, 0, 64, 64], "codec": CBOR(codec), "source": CBOR(source),
        ]) else { throw CancellationError() }
        return try #require(RemoteVideo(fields, send: { sent.append($0) }))
    }

    private func settle(_ video: RemoteVideo) async throws {
        video.flush()
        try await Task.sleep(for: .milliseconds(150))
    }

    @Test func anAppsFrameIsDecodedAtOnceAndShownWhenTheAppPresentsIt() async throws {
        let sent = Sent()
        let video = try video(source: "passthrough", sent: sent)
        video.frame(VideoFrame(video: 3, seq: 0, keyframe: true, data: try keyframe()))
        try await settle(video)
        #expect(sent.acks == [0]) // decoded and queued
        #expect(!video.layer.isReadyForDisplay) // not shown before the app shows it
        video.present(seq: 0)
        try await settle(video)
        #expect(video.layer.sampleBufferRenderer.status == .rendering, "\(String(describing: video.layer.sampleBufferRenderer.error))")
        #expect(video.layer.isReadyForDisplay)
        video.close()
    }

    @Test func aLiveFrameIsShownOnArrival() async throws {
        let sent = Sent()
        let video = try video(source: "surface", sent: sent)
        video.frame(VideoFrame(video: 3, seq: 41, keyframe: true, ptsMicros: 1, data: try keyframe()))
        try await settle(video)
        #expect(sent.acks == [41])
        #expect(video.layer.sampleBufferRenderer.status == .rendering)
        #expect(video.layer.isReadyForDisplay)
    }

    @Test func anUndecodableStreamAsksForAKeyframeAndWaitsForIt() async throws {
        let sent = Sent()
        let video = try video(source: "passthrough", codec: "av1", sent: sent)
        video.frame(VideoFrame(video: 3, seq: 0, keyframe: true, data: Data([0xFF, 0xFF]))) // not OBUs
        video.frame(VideoFrame(video: 3, seq: 1, keyframe: false, data: Data([0x12, 0x00])))
        try await settle(video)
        #expect(sent.acks.isEmpty)
        #expect(sent.keyframeRequests == 1)
    }

    @Test func presentingAFrameNobodyKeptShowsNothing() async throws {
        let sent = Sent()
        let video = try video(source: "passthrough", sent: sent)
        video.present(seq: 5)
        try await settle(video)
        #expect(!video.layer.isReadyForDisplay)
    }
}

@MainActor @Suite(.serialized) struct VideoSessionTests {
    @Test func windowsKeepTheirStreamsInOrder() async throws {
        let base = CabooseDisplaySessionTests()
        let session = try await base.ready()
        base.stream.server([(.windowCreate, base.window(7, geometry: [0, 0, 1920, 1080]))])
        try await base.until("window") { session.windows[7] != nil }
        let window = try #require(session.windows[7])
        let layout = window.videoLayout
        base.stream.server([
            (.videoCreate, ["id": 1, "window": 7, "rect": [0, 0, 1920, 1080], "codec": "hevc", "source": "passthrough", "z": 2]),
            (.videoCreate, ["id": 2, "window": 7, "rect": [100, 100, 320, 180], "codec": "h264", "source": "surface", "z": 1]),
            (.videoCreate, ["id": 9, "window": 99, "rect": [0, 0, 1, 1], "codec": "h264", "source": "surface"]), // no such window
        ])
        try await base.until("videos") { window.videos.count == 2 }
        #expect(window.videos.map(\.id) == [2, 1])
        #expect(window.videoLayout != layout)
        base.stream.server([(.videoUpdate, ["id": 2, "z": 3, "clip": [100, 100, 320, 90]])])
        try await base.until("reordered") { window.videos.map(\.id) == [1, 2] }
        #expect(window.videos.last?.clip == CGRect(x: 100, y: 100, width: 320, height: 90))
        base.stream.server([(.videoDestroy, ["id": 1])])
        try await base.until("destroyed") { window.videos.map(\.id) == [2] }
        base.stream.server([(.windowDestroy, ["id": 7])])
        try await base.until("window gone") { session.windows[7] == nil }
        #expect(window.videos.isEmpty)
    }

    /// A motion stream ends with a window picture that repaints its region, then video.destroy:
    /// the video stays until that picture is applied (and a view has shown it), never before.
    @Test func anEndedVideoWaitsForTheRepaint() async throws {
        let base = CabooseDisplaySessionTests()
        let session = try await base.ready()
        base.stream.server([(.windowCreate, base.window(7, geometry: [0, 0, 64, 64]))])
        try await base.until("window") { session.windows[7] != nil }
        let window = try #require(session.windows[7])
        base.stream.server([(.videoCreate, ["id": 4, "window": 7, "rect": [8, 8, 32, 32], "codec": "h264", "source": "motion"])])
        try await base.until("video") { window.videos.count == 1 }
        let container = ObjectIdentifier(try #require(window.videos.first).container)
        base.stream.server([(.frame, base.frame(7, pts: 1000, keyframe: true)), (.videoDestroy, ["id": 4])])
        try await base.until("retired") { window.videos.isEmpty }
        let repaint = try #require(window.retiringVideos[container])
        #expect(repaint > 0 && repaint == window.surface.generation, "the generation that includes the repaint")
        // No view showed it: after a second the session lets it go anyway.
        try await base.until("pruned") { window.retiringVideos.isEmpty }
    }

    @Test func helloOffersTheSameDecodersForVideo() async throws {
        let base = CabooseDisplaySessionTests()
        let session = base.makeSession()
        session.connect()
        base.stream.deliver(.opened)
        try await base.until("hello") { session.state == .authenticating }
        #expect(base.stream.take().first?.body["video_decoders"] == ["hevc", "h264"])
    }
}
