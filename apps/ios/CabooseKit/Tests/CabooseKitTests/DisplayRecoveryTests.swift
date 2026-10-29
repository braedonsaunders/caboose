import CoreGraphics
import Foundation
import QuartzCore
import Testing
@testable import CabooseKit

@Suite struct ReconnectPolicyTests {
    @Test func aSeriesBacksOffThenStops() {
        var policy = ReconnectPolicy()
        var delays: [Double] = []
        while let delay = policy.next(after: .dropped, at: 0) { delays.append(delay) }
        #expect(delays == ReconnectPolicy.delays)
        #expect(policy.attempts == ReconnectPolicy.maxAttempts)
        #expect(policy.next(after: .wakeFailed, at: 0) == nil)
    }

    @Test func aStableConnectionStartsANewSeries() {
        var policy = ReconnectPolicy()
        for _ in 0 ..< 5 { _ = policy.next(after: .dropped, at: 0) }
        policy.connected(at: 100)
        #expect(policy.next(after: .stalled, at: 100 + ReconnectPolicy.stableAfter) == ReconnectPolicy.delays[0])
        #expect(policy.attempts == 1)
    }

    /// Connecting and dropping at once is one series, so a flapping link gives up.
    @Test func aFlappingConnectionKeepsCounting() {
        var policy = ReconnectPolicy()
        var now = 0.0
        var attempts = 0
        while policy.next(after: .dropped, at: now) != nil {
            attempts += 1
            now += 1
            policy.connected(at: now)
            now += 1
        }
        #expect(attempts == ReconnectPolicy.maxAttempts)
    }

    @Test func refusalIsRetriedOnceAndIncompatibilityNever() {
        var policy = ReconnectPolicy()
        #expect(policy.next(after: .refused, at: 0) != nil)
        #expect(policy.next(after: .refused, at: 0) == nil)
        var other = ReconnectPolicy()
        #expect(other.next(after: .incompatible, at: 0) == nil)
    }

    @Test func restartingClearsTheSeries() {
        var policy = ReconnectPolicy()
        while policy.next(after: .dropped, at: 0) != nil {}
        policy.restart()
        #expect(policy.next(after: .dropped, at: 0) == ReconnectPolicy.delays[0])
    }

    @Test func closeCausesMapToWhatTheAppDoes() {
        #expect(DisplayCloseCause.local.reconnect == nil)
        #expect(DisplayCloseCause.bye("replaced").reconnect == nil)
        #expect(DisplayCloseCause.transport(nil).reconnect == .dropped)
        #expect(DisplayCloseCause.stalled("x").reconnect == .stalled)
        #expect(DisplayCloseCause.bye("auth").reconnect == .refused)
        #expect(DisplayCloseCause.bye("version").reconnect == .incompatible)
        #expect(DisplayCloseCause.bye("protocol").reconnect == .incompatible)
        #expect(DisplayCloseCause.incompatible.reconnect == .incompatible)
        #expect(DisplayCloseCause.bye("shutdown").reconnect == .dropped)
        #expect(DisplayCloseCause.transport("x").keepsWindows && DisplayCloseCause.stalled("x").keepsWindows)
        #expect(DisplayCloseCause.bye("auth").keepsWindows)
        #expect(!DisplayCloseCause.bye("replaced").keepsWindows && !DisplayCloseCause.bye("shutdown").keepsWindows)
        #expect(!DisplayCloseCause.local.keepsWindows && !DisplayCloseCause.incompatible.keepsWindows)
    }
}

@Suite struct LinkWatchdogTests {
    @Test func aConnectionThatNeverAnswersStalls() {
        var dog = LinkWatchdog(openedAt: 10)
        #expect(dog.verdict(at: 10 + LinkWatchdog.openLimit, lastReceive: nil) == .live)
        #expect(dog.verdict(at: 10.1 + LinkWatchdog.openLimit, lastReceive: nil) != .live)
    }

    @Test func silenceAfterTheHelloStalls() {
        var dog = LinkWatchdog(openedAt: 0)
        dog.ready(at: 1)
        #expect(dog.verdict(at: 1 + LinkWatchdog.silenceLimit, lastReceive: nil) == .live)
        #expect(dog.verdict(at: 20, lastReceive: 6) == .live)
        #expect(dog.verdict(at: 21.5, lastReceive: 6) != .live)
    }

    @Test func aProbeNeedsAnAnswer() {
        var dog = LinkWatchdog(openedAt: 0)
        dog.ready(at: 1)
        dog.probe(at: 10)
        #expect(dog.verdict(at: 10 + LinkWatchdog.probeLimit, lastReceive: 9.5) == .live)
        #expect(dog.verdict(at: 10.1 + LinkWatchdog.probeLimit, lastReceive: 9.5) != .live)

        var answered = LinkWatchdog(openedAt: 0)
        answered.ready(at: 1)
        answered.probe(at: 10)
        #expect(answered.verdict(at: 11, lastReceive: 10.5) == .live)
        // Answered once, the probe is over: only the ordinary silence limit applies.
        #expect(answered.verdict(at: 20, lastReceive: 10.5) == .live)
    }
}

@Suite struct ConnectionMetricsTests {
    @Test func nothingMeasuredIsNil() {
        let health = ConnectionMetrics().snapshot(at: 5)
        #expect(health == .empty)
        #expect(health.roundTrip == nil && health.receiveRate == nil && health.sinceLastReceive == nil)
    }

    @Test func roundTripsKeepLastMedianAndWorst() {
        let metrics = ConnectionMetrics()
        for ms in [40.0, 10, 30, 20] { metrics.roundTrip(ms: ms) }
        let rtt = metrics.snapshot(at: 0).roundTrip
        #expect(rtt == DisplayLinkHealth.Samples(last: 20, median: 30, worst: 40, count: 4))
        for _ in 0 ..< 30 { metrics.roundTrip(ms: 5) }
        #expect(metrics.snapshot(at: 0).roundTrip == DisplayLinkHealth.Samples(last: 5, median: 5, worst: 5, count: 20))
    }

    @Test func ratesNeedASecondAndCoverTheLastFew() {
        let metrics = ConnectionMetrics()
        metrics.receive(bytes: 1000, at: 100)
        #expect(metrics.snapshot(at: 100.5).receiveRate == nil)
        #expect(metrics.snapshot(at: 100.5).sinceLastReceive == 0.5)
        metrics.receive(bytes: 1000, at: 101)
        // 2000 bytes over the one second since the first.
        #expect(metrics.snapshot(at: 101).receiveRate == 16000)
        metrics.receive(bytes: 500, at: 110)
        // Only the last five seconds count.
        #expect(metrics.snapshot(at: 110).receiveRate == 500 * 8 / ConnectionMetrics.rateWindow)
    }

    @Test func picturesRecordWaitDecodeFailuresAndAge() {
        let metrics = ConnectionMetrics()
        metrics.picture(window: 7, waited: 0.002, took: 0.004, failed: false, at: 50)
        metrics.picture(window: 7, waited: 0.010, took: 0, failed: true, at: 51)
        let health = metrics.snapshot(at: 52)
        #expect(health.decode?.count == 1 && health.decode?.last == 4)
        #expect(health.decodeWait?.count == 2 && health.decodeWait?.worst == 10)
        #expect(health.decodeFailures == 1)
        #expect(metrics.pictureAge(window: 7, at: 52) == 2)
        #expect(metrics.pictureAge(window: 8, at: 52) == nil)
    }
}

/// A session reconnecting over a fresh mock stream each time.
@MainActor @Suite(.serialized) struct DisplayResumeTests {
    final class Streams: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [MockStream] = []
        func make() -> ByteStream {
            let stream = MockStream()
            lock.withLock { made.append(stream) }
            return stream
        }
        var all: [MockStream] { lock.withLock { made } }
        var last: MockStream { all.last! }
    }

    let streams = Streams()
    let decoder = FakeDecoder()
    let display = DisplayInfo(id: 0, width: 2000, height: 2000, scale: 2, refreshHz: 120)
    let helpers = CabooseDisplaySessionTests()

    func makeSession() -> CabooseDisplaySession {
        let streams = streams, decoder = decoder
        return CabooseDisplaySession(stream: { streams.make() }, token: "wake-token", displays: [display], decoders: [.hevc, .h264],
                                     makeDecoder: { _ in decoder })
    }

    func hello(epoch: CBOR?) -> CBOR {
        var pairs: [(CBOR, CBOR)] = [("version", 0), ("displays", [0]), ("encoders", ["hevc"]), ("features", ["vsync", "ack"])]
        if let epoch { pairs.append(("epoch", epoch)) }
        return .map(pairs)
    }

    /// Opens the newest stream and answers its hello; returns the marker ping the client sent.
    @discardableResult
    func handshake(_ session: CabooseDisplaySession, epoch: CBOR?, windows: [Int] = []) async throws -> UInt64? {
        let stream = streams.last
        stream.deliver(.opened)
        try await helpers.until("hello") { session.state == .authenticating }
        _ = stream.take()
        var messages: [(DisplayProtocol.ServerType, CBOR)] = [(.hello, hello(epoch: epoch))]
        for id in windows { messages.append((.windowCreate, helpers.window(id, geometry: [0, 0, 8, 8]))) }
        stream.server(messages)
        try await helpers.until("ready") { session.state == .ready && windows.allSatisfy { session.windows[$0] != nil } }
        return stream.take().first { $0.type == DisplayProtocol.ClientType.ping.rawValue }?.body["t_us"]?.uint64
    }

    func closed(_ session: CabooseDisplaySession) -> Bool {
        if case .closed = session.state { true } else { false }
    }

    func dropAndResume(_ session: CabooseDisplaySession) async throws {
        streams.last.deliver(.closed(URLError(.networkConnectionLost)))
        try await helpers.until("closed") { closed(session) }
        if case .transport = session.closeCause {} else { Issue.record("not a transport close") }
        session.resume(stream: { self.streams.make() }, password: "new-token", displays: [display])
    }

    @Test func theSameEpochKeepsTheWindowAndItsPicture() async throws {
        let session = makeSession()
        session.connect()
        try await handshake(session, epoch: "e1", windows: [7, 8])
        let seven = try #require(session.windows[7])
        try await dropAndResume(session)
        // Lost but kept: the window and its picture stay on screen.
        #expect(session.windows[7] === seven)

        let marker = try await handshake(session, epoch: "e1", windows: [7])
        #expect(session.windows[7] === seven)
        #expect(session.windows[8] != nil) // until the burst is over
        let marked = try #require(marker)
        streams.last.server([(.pong, ["t_us": CBOR(marked)])])
        try await helpers.until("window 8 gone") { session.windows[8] == nil }
        #expect(session.windows[7] === seven)
        #expect(session.state == .ready)
    }

    /// The hello and its windows can arrive in separate reads: while ready, a kept window
    /// never disappears before the announcement boundary, so nothing reads it as closed.
    @Test func keptWindowsStayThroughDelayedAnnouncements() async throws {
        let session = makeSession()
        session.connect()
        try await handshake(session, epoch: "e1", windows: [7, 8])
        let seven = try #require(session.windows[7]), eight = try #require(session.windows[8])
        try await dropAndResume(session)
        let markerSent = try await handshake(session, epoch: "e1")

        let marker = try #require(markerSent)
        #expect(session.state == .ready)
        #expect(session.windows[7] === seven && session.windows[8] === eight)
        streams.last.server([(.windowCreate, helpers.window(8, geometry: [0, 0, 8, 8]))])
        try await Task.sleep(for: .milliseconds(20))
        streams.last.server([(.windowCreate, helpers.window(7, geometry: [0, 0, 8, 8]))])
        try await Task.sleep(for: .milliseconds(20))
        #expect(session.windows[7] === seven && session.windows[8] === eight)
        #expect(session.windowsAnnounced == 0) // no marker answered yet
        streams.last.server([(.pong, ["t_us": CBOR(marker)])])
        try await helpers.until("announced") { session.windowsAnnounced == 1 }
        #expect(session.windows[7] === seven && session.windows[8] === eight)
        #expect(session.epoch == "e1" && session.connections == 2)
    }

    @Test func theResumedHelloCarriesTheNewToken() async throws {
        let session = makeSession()
        session.connect()
        try await handshake(session, epoch: "e1", windows: [7])
        try await dropAndResume(session)
        let stream = streams.last
        stream.deliver(.opened)
        try await helpers.until("hello") { session.state == .authenticating }
        #expect(stream.take().first?.body["token"]?.string == "new-token")
    }

    @Test func anotherEpochStartsOver() async throws {
        let session = makeSession()
        session.connect()
        try await handshake(session, epoch: "e1", windows: [7])
        let seven = try #require(session.windows[7])
        try await dropAndResume(session)
        try await handshake(session, epoch: "e2", windows: [7])
        // Window 7 of the new server is another window: a new object, a new surface.
        let fresh = try #require(session.windows[7])
        #expect(fresh !== seven)
        #expect(fresh.surface !== seven.surface)
    }

    /// A server without an epoch (an older guest) cannot prove its ids: nothing is kept.
    @Test func noOrInvalidEpochKeepsNothing() async throws {
        for epoch: CBOR? in [nil, "", .unsigned(3)] {
            let session = makeSession()
            session.connect()
            try await handshake(session, epoch: epoch, windows: [7])
            streams.last.deliver(.closed(nil))
            try await helpers.until("closed") { closed(session) }
            #expect(session.windows.isEmpty)
        }
    }

    @Test func aMissingEpochAfterOneDropsTheKeptWindows() async throws {
        let session = makeSession()
        session.connect()
        try await handshake(session, epoch: "e1", windows: [7])
        let seven = try #require(session.windows[7])
        try await dropAndResume(session)
        try await handshake(session, epoch: nil, windows: [7])
        #expect(session.windows[7] !== seven)
    }

    /// Whatever the lost connection still delivers reaches nothing.
    @Test func theOldStreamCannotTouchTheResumedSession() async throws {
        let session = makeSession()
        session.connect()
        try await handshake(session, epoch: "e1", windows: [7])
        let old = streams.last
        try await dropAndResume(session)
        try await handshake(session, epoch: "e1", windows: [7])
        old.server([(.windowDestroy, ["id": 7]), (.windowCreate, helpers.window(9, geometry: [0, 0, 8, 8])),
                    (.bye, ["reason": "replaced"])])
        old.deliver(.closed(nil))
        try await Task.sleep(for: .milliseconds(50))
        #expect(session.state == .ready)
        #expect(session.windows[7] != nil && session.windows[9] == nil)
        #expect(!session.isReplaced)
    }

    /// A picture still queued for the closed pipeline is dropped; the successor paints.
    @Test func aClosedPipelineDropsWhatWasQueued() async throws {
        let decoder = FakeDecoder()
        let closed = FramePipeline(windowID: 7, width: 8, height: 8, makeDecoder: { _ in decoder }, send: { _ in })
        closed.close()
        let frame = EncodedFrame(window: 7, codec: .hevc, keyframe: true, ptsMicros: 1, rect: CGRect(x: 0, y: 0, width: 8, height: 8),
                                 crop: CGRect(x: 0, y: 0, width: 8, height: 8), data: Data([0, 0, 1]))
        closed.frame(frame)
        closed.flush()
        #expect(decoder.decoded == 0)
        let next = FramePipeline(succeeding: closed, width: 8, height: 8, metrics: nil, makeDecoder: { _ in decoder }, send: { _ in })
        #expect(next.surface === closed.surface)
        next.frame(frame)
        next.flush()
        #expect(decoder.decoded == 1)
    }

    @Test func silenceGivesTheConnectionUpAndKeepsTheWindows() async throws {
        let session = makeSession()
        session.connect()
        try await handshake(session, epoch: "e1", windows: [7])
        session.checkLiveness(at: CACurrentMediaTime() + LinkWatchdog.silenceLimit + 1)
        #expect(closed(session))
        guard case .stalled = session.closeCause else { Issue.record("not stalled: \(String(describing: session.closeCause))"); return }
        #expect(session.windows[7] != nil)
        #expect(streams.last.closed)
    }

    @Test func aProbeThatGoesUnansweredStalls() async throws {
        let session = makeSession()
        session.connect()
        try await handshake(session, epoch: "e1", windows: [7])
        session.probeLiveness()
        #expect(streams.last.take().contains { $0.type == DisplayProtocol.ClientType.ping.rawValue })
        session.checkLiveness(at: CACurrentMediaTime() + LinkWatchdog.probeLimit + 0.5)
        guard case .stalled = session.closeCause else { Issue.record("not stalled"); return }
    }

    @Test func pingsGoOutWhileConnected() async throws {
        let session = makeSession()
        session.connect()
        try await handshake(session, epoch: "e1")
        session.checkLiveness(at: CACurrentMediaTime() + LinkWatchdog.pingInterval)
        #expect(streams.last.take().contains { $0.type == DisplayProtocol.ClientType.ping.rawValue })
        #expect(session.state == .ready)
    }

    @Test func replacedAndDisconnectKeepNothing() async throws {
        let session = makeSession()
        session.connect()
        try await handshake(session, epoch: "e1", windows: [7])
        streams.last.server([(.bye, ["reason": "replaced"])])
        try await helpers.until("closed") { closed(session) }
        #expect(session.windows.isEmpty && session.isReplaced)
        #expect(session.closeCause?.reconnect == nil)

        let other = makeSession()
        other.connect()
        try await handshake(other, epoch: "e1", windows: [7])
        streams.last.deliver(.closed(nil))
        try await helpers.until("closed") { closed(other) }
        #expect(other.windows[7] != nil)
        other.disconnect()
        #expect(other.windows.isEmpty && other.closeCause == .local)
    }

    @Test func windowsAnnouncedFollowsTheMarkerOnlyWithAnEpoch() async throws {
        let session = makeSession()
        session.connect()
        let markerSent = try await handshake(session, epoch: "e1", windows: [7])

        let marker = try #require(markerSent)
        #expect(session.windowsAnnounced == 0)
        streams.last.server([(.pong, ["t_us": CBOR(marker + 1)])])
        try await Task.sleep(for: .milliseconds(20))
        #expect(session.windowsAnnounced == 0) // not the marker
        streams.last.server([(.pong, ["t_us": CBOR(marker)])])
        try await helpers.until("announced") { session.windowsAnnounced == 1 }

        let old = makeSession()
        old.connect()
        let oldMarkerSent = try await handshake(old, epoch: nil, windows: [7])

        let oldMarker = try #require(oldMarkerSent)
        streams.last.server([(.pong, ["t_us": CBOR(oldMarker)])])
        try await helpers.until("rtt") { old.health.roundTrip != nil }
        #expect(old.windowsAnnounced == 0)
    }

    @Test func roundTripsAndBytesAreMeasured() async throws {
        let session = makeSession()
        session.connect()
        let markerSent = try await handshake(session, epoch: "e1")

        let marker = try #require(markerSent)
        streams.last.server([(.pong, ["t_us": CBOR(marker)])])
        try await helpers.until("rtt") { session.health.roundTrip != nil }
        #expect(session.health.roundTrip?.count == 1)
        #expect((session.health.sinceLastReceive ?? 99) < 5)
    }

    @Test func aModifierAloneWaitsForNoPicture() async throws {
        let session = makeSession()
        session.connect()
        try await handshake(session, epoch: "e1", windows: [7])
        let window = try #require(session.windows[7])
        session.key(KeyStroke(name: "Shift_L", keyval: 0xFFE1), pressed: true, in: window)
        #expect(session.health.keyAwaitingPicture == nil)
        session.key(KeyStroke(name: "a", keyval: 0x61), pressed: true, in: window)
        #expect(session.health.keyAwaitingPicture != nil)
    }
}
