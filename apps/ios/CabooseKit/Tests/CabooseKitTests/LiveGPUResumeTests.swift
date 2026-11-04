import Foundation
import XCTest
@testable import CabooseKit

final class LiveGPUResumeTests: XCTestCase {
    private let executor = Data((1...16).map(UInt8.init))
    private let generation: UInt64 = 7
    private let credential = String(repeating: "A", count: 42) + "w"

    private func envelope(_ kind: LiveGPUEnvelope.Kind, sequence: UInt64, process: UInt64 = 0, stream: UInt64 = 0,
                          payload: Data = Data()) throws -> Data {
        try LiveGPUEnvelope(kind: kind, executor: executor, generation: generation, process: process,
                            stream: stream, sequence: sequence, payload: payload).encoded()
    }
    private func data(_ sequence: UInt64, _ byte: UInt8 = 1) throws -> Data {
        try envelope(.data, sequence: sequence, process: 1, stream: 1, payload: Data([byte]))
    }
    private func ack(_ value: UInt64) -> Data {
        LiveGPUResumeWire.ack(executor: executor, generation: generation, received: value)
    }

    /// Opens a transport over scripted sockets and negotiates resumption.
    private func resumable(policy: LiveGPUResumableTransport.Policy = .init()) throws -> (LiveGPUResumableTransport, SocketFactory, Inbox) {
        let factory = SocketFactory(credential: credential)
        let transport = LiveGPUResumableTransport(policy: policy) { factory.make($0) }
        let inbox = Inbox()
        transport.open { inbox.append($0) }
        let first = factory.sockets[0]
        first.emit(.opened)
        first.emit(.bytes(ack(0)))
        first.emit(.bytes(try envelope(.session, sequence: 1, payload: LiveGPUEnvelope.hello)))
        XCTAssertEqual(transport.negotiatedMode, .resumable)
        return (transport, factory, inbox)
    }

    func testWithoutCredentialOrLeadingAckEveryByteIsPassedThrough() throws {
        for (credential, leading) in [(nil, true), (credential, false)] as [(String?, Bool)] {
            let factory = SocketFactory(credential: credential)
            let transport = LiveGPUResumableTransport { factory.make($0) }
            let inbox = Inbox()
            transport.open { inbox.append($0) }
            let socket = factory.sockets[0]
            socket.emit(.opened)
            let session = try envelope(.session, sequence: 1, payload: LiveGPUEnvelope.hello)
            if leading { socket.emit(.bytes(ack(0))) }
            socket.emit(.bytes(session))
            XCTAssertEqual(transport.negotiatedMode, .plain)
            XCTAssertEqual(inbox.bytes, leading ? [ack(0), session] : [session])
            XCTAssertTrue(transport.send(Data([9])))
            XCTAssertEqual(socket.sent, [Data([9])])
            socket.emit(.closed(LiveGPUError.closed))
            XCTAssertEqual(inbox.closes, 1)
            XCTAssertEqual(factory.sockets.count, 1)
        }
    }

    func testLeadingAckIsConsumedAndRepliesAreAcknowledgedCumulatively() throws {
        var policy = LiveGPUResumableTransport.Policy()
        policy.ackBytes = 150
        let (transport, factory, inbox) = try resumable(policy: policy)
        defer { withExtendedLifetime(transport) {} }
        let socket = factory.sockets[0]
        XCTAssertEqual(inbox.events.first, "opened")
        XCTAssertEqual(inbox.bytes, [try envelope(.session, sequence: 1, payload: LiveGPUEnvelope.hello)])
        // 112 + 65 bytes received passes 150: one acknowledgement covers both.
        socket.emit(.bytes(try data(2)))
        XCTAssertEqual(socket.sent, [ack(2)])
        let timed = expectation(description: "paced acknowledgement")
        socket.emit(.bytes(try data(3)))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { timed.fulfill() }
        wait(for: [timed], timeout: 2)
        XCTAssertEqual(socket.sent, [ack(2), ack(3)])
    }

    func testLostSocketResumesAndEachSideRetransmitsWhatTheOtherMissed() throws {
        let (transport, factory, inbox) = try resumable()
        let first = factory.sockets[0]
        XCTAssertTrue(transport.send(try envelope(.sessionReady, sequence: 1, payload: LiveGPUEnvelope.hello)))
        XCTAssertTrue(transport.send(try data(2, 0xA)))
        XCTAssertTrue(transport.send(try data(3, 0xB)))
        first.emit(.bytes(ack(1)))
        first.emit(.bytes(try data(2)))
        first.emit(.closed(LiveGPUError.closed))
        XCTAssertEqual(inbox.closes, 0)
        // The next socket names the credential and opens with RESUME for what arrived.
        XCTAssertEqual(factory.credentials, [nil, credential])
        let second = factory.sockets[1]
        // Sent while the splice is pending: retained only, sent after the broker's RESUME.
        XCTAssertTrue(transport.send(try data(4, 0xC)))
        second.emit(.opened)
        guard let resume = second.sent.first, let header = LiveGPUResumeWire.header(resume) else {
            return XCTFail("no RESUME")
        }
        XCTAssertEqual(second.sent.count, 1)
        XCTAssertEqual(header.kind, LiveGPUResumeWire.resume)
        XCTAssertEqual(header.sequence, 0)
        let payload = LiveGPUResumeWire.payload(resume)
        XCTAssertEqual(LiveGPUResumeWire.value(payload), 2)
        let nonce = payload.suffix(16)
        // Bytes the relay queued before the splice are ignored, as is a RESUME with another nonce.
        second.emit(.bytes(try data(2)))
        second.emit(.bytes(Data([1, 2, 3])))
        second.emit(.bytes(LiveGPUResumeWire.resume(executor: executor, generation: generation, received: 1,
                                                    nonce: LiveGPUResumeWire.nonce())))
        XCTAssertEqual(second.sent.count, 1)
        second.emit(.bytes(LiveGPUResumeWire.resume(executor: executor, generation: generation, received: 2, nonce: nonce)))
        // Envelopes 3 and 4 are replayed together; 2 was acknowledged by the broker's RESUME.
        XCTAssertEqual(second.sent.dropFirst().first, try data(3, 0xB) + data(4, 0xC))
        XCTAssertEqual(transport.resumes, 1)
        second.emit(.bytes(try data(3)))
        XCTAssertEqual(inbox.bytes.suffix(2), [try data(2), try data(3)])
        XCTAssertTrue(transport.send(try data(5, 0xD)))
        XCTAssertEqual(second.sent.last, try data(5, 0xD))
        XCTAssertEqual(inbox.closes, 0)
    }

    func testUnansweredResumeTriesTheNextSocket() throws {
        var policy = LiveGPUResumableTransport.Policy()
        policy.resumeAnswer = 0.05
        let (transport, factory, inbox) = try resumable(policy: policy)
        defer { withExtendedLifetime(transport) {} }
        factory.sockets[0].emit(.closed(LiveGPUError.closed))
        // A computer that took the socket as a new executor sends ACK(0) and SESSION, never RESUME.
        factory.sockets[1].emit(.opened)
        factory.sockets[1].emit(.bytes(ack(0)))
        let deadline = Date().addingTimeInterval(2)
        while factory.sockets.count < 3 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(factory.sockets[1].abnormalCloses, 1)
        XCTAssertEqual(factory.sockets.count, 3)
        XCTAssertEqual(inbox.closes, 0)
    }

    func testGapAfterResumeAndOutOfRangeAcknowledgementEndTheSession() throws {
        let (transport, factory, inbox) = try resumable()
        factory.sockets[0].emit(.bytes(try data(3)))
        XCTAssertEqual(inbox.closes, 1)
        XCTAssertFalse(transport.send(try envelope(.sessionReady, sequence: 1, payload: LiveGPUEnvelope.hello)))
        let (other, otherFactory, otherInbox) = try resumable()
        otherFactory.sockets[0].emit(.bytes(ack(1)))
        XCTAssertEqual(otherInbox.closes, 1)
        withExtendedLifetime(other) {}
    }

    func testFullWindowBlocksTheSenderUntilAcknowledged() throws {
        var policy = LiveGPUResumableTransport.Policy()
        policy.retainedCount = 2
        let (transport, factory, _) = try resumable(policy: policy)
        XCTAssertTrue(transport.send(try envelope(.sessionReady, sequence: 1, payload: LiveGPUEnvelope.hello)))
        XCTAssertTrue(transport.send(try data(2)))
        let sent = DispatchSemaphore(value: 0)
        let third = try data(3)
        DispatchQueue.global().async {
            XCTAssertTrue(transport.send(third)); sent.signal()
        }
        XCTAssertEqual(sent.wait(timeout: .now() + 0.2), .timedOut)
        factory.sockets[0].emit(.bytes(ack(1)))
        XCTAssertEqual(sent.wait(timeout: .now() + 2), .success)
        // Closing wakes a sender still waiting, which then refuses.
        let refused = expectation(description: "blocked sender released by close")
        let fourth = try data(4)
        DispatchQueue.global().async {
            XCTAssertFalse(transport.send(fourth)); refused.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.05)
        transport.close()
        wait(for: [refused], timeout: 2)
    }

    func testRefusedCredentialAndExpiredHoldEndTheExecutor() throws {
        let (transport, factory, inbox) = try resumable()
        factory.sockets[0].emit(.closed(LiveGPUError.closed))
        factory.sockets[1].emit(.closed(LiveGPUError.resumeRefused))
        withExtendedLifetime(transport) {}
        XCTAssertEqual(inbox.closes, 1)
        XCTAssertEqual(factory.sockets.count, 2)

        var policy = LiveGPUResumableTransport.Policy()
        policy.holdWindow = 0.2; policy.retryInterval = 0.02
        let (expiringTransport, expiring, expiringInbox) = try resumable(policy: policy)
        defer { withExtendedLifetime(expiringTransport) {} }
        expiring.failNewSockets = true
        expiring.sockets[0].emit(.closed(LiveGPUError.closed))
        let deadline = Date().addingTimeInterval(2)
        while expiringInbox.closes == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(expiringInbox.closes, 1)
        XCTAssertGreaterThan(expiring.sockets.count, 3)
    }

    func testSuspendedTransportClosesWith4001AndResumesOnRequest() throws {
        let (transport, factory, inbox) = try resumable()
        transport.suspendTransport()
        XCTAssertEqual(factory.sockets[0].suspendedCloses, 1)
        factory.sockets[0].emit(.closed(nil))
        XCTAssertEqual(factory.sockets.count, 1)
        XCTAssertEqual(inbox.closes, 0)
        transport.resumeTransport()
        XCTAssertEqual(factory.credentials, [nil, credential])
        factory.sockets[1].emit(.opened)
        XCTAssertEqual(LiveGPUResumeWire.header(factory.sockets[1].sent[0])?.kind, LiveGPUResumeWire.resume)
    }

    func testCredentialFormatAndResumeRequest() throws {
        XCTAssertTrue(LiveGPUConnection.validCredential(credential))
        XCTAssertFalse(LiveGPUConnection.validCredential(credential + "A"))
        XCTAssertFalse(LiveGPUConnection.validCredential(String(repeating: "+", count: 43)))
        XCTAssertNotNil(URLSessionWebSocketTask.CloseCode(rawValue: 4001))
        let request = try LiveGPUConnection.makeRequest(hostURL: URL(string: "https://example.com")!, phoneToken: "phone")
        XCTAssertTrue(request.value(forHTTPHeaderField: "X-Caboose-GPU-Features")!.hasSuffix(",executor-resume,zstd-stream,upload-cache,guest-buffer-views,batched-descriptor-sets-inline,guest-set-ids,completion-payloads,wait-serial,silent-success,one-way-start"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Caboose-GPU-Resume"))
    }
}

private final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [LiveGPUTransportEvent] = []
    func append(_ event: LiveGPUTransportEvent) { lock.withLock { recorded.append(event) } }
    var events: [String] {
        lock.withLock {
            recorded.map {
                switch $0 { case .opened: "opened"; case .bytes: "bytes"; case .closed: "closed" }
            }
        }
    }
    var bytes: [Data] {
        lock.withLock { recorded.compactMap { if case .bytes(let data) = $0 { data } else { nil } } }
    }
    var closes: Int { events.filter { $0 == "closed" }.count }
}

private final class SocketFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let credential: String?
    private var made: [ScriptedSocket] = []
    private var named: [String?] = []
    var failNewSockets = false
    init(credential: String?) { self.credential = credential }
    var sockets: [ScriptedSocket] { lock.withLock { made } }
    var credentials: [String?] { lock.withLock { named } }
    func make(_ resume: String?) -> LiveGPUResumeSocket {
        let socket = ScriptedSocket(credential: credential, failsOnOpen: lock.withLock { failNewSockets })
        lock.withLock { made.append(socket); named.append(resume) }
        return socket
    }
}

private final class ScriptedSocket: LiveGPUResumeSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var event: (@Sendable (LiveGPUTransportEvent) -> Void)?
    private var messages: [Data] = []
    private var suspended = 0
    private let failsOnOpen: Bool
    let resumeCredential: String?
    init(credential: String?, failsOnOpen: Bool) { resumeCredential = credential; self.failsOnOpen = failsOnOpen }
    var queuedMessages: Int { 0 }
    var silence: TimeInterval = 0
    var sent: [Data] { lock.withLock { messages } }
    var suspendedCloses: Int { lock.withLock { suspended } }
    func open(_ event: @escaping @Sendable (LiveGPUTransportEvent) -> Void) {
        lock.withLock { self.event = event }
        if failsOnOpen { DispatchQueue.global().async { event(.closed(LiveGPUError.closed)) } }
    }
    func send(_ bytes: Data) -> Bool { lock.withLock { messages.append(bytes) }; return true }
    func close() {}
    func closeSuspended() { lock.withLock { suspended += 1 } }
    private var abnormal = 0
    var abnormalCloses: Int { lock.withLock { abnormal } }
    func close(abnormally error: Error) { lock.withLock { abnormal += 1 }; emit(.closed(error)) }
    func emit(_ incoming: LiveGPUTransportEvent) { lock.withLock { event }?(incoming) }
}
