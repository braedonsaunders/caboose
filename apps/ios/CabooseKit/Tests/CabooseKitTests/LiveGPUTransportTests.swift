import Foundation
import XCTest
@testable import CabooseKit

final class LiveGPUTransportTests: XCTestCase {
    func testEndpointHasNoAuthorityOverrides() throws {
        let request = try LiveGPUConnection.makeRequest(hostURL: URL(string: "https://example.com/ignored")!, phoneToken: "phone")
        XCTAssertEqual(request.url?.absoluteString, "wss://example.com/v1/gpu")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol"), "caboose.gpu.live.v1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer phone")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Caboose-GPU-Features"), "guest-handles,guest-handle-arrays,completion-feed,ordered-present,guest-images,guest-query-pools,shader-cache,executor-resume,zstd-stream,upload-cache,guest-buffer-views,batched-descriptor-sets-inline,guest-set-ids,completion-payloads,wait-serial,silent-success")
        XCTAssertNil(request.value(forHTTPHeaderField: "Sec-WebSocket-Extensions"))
        for url in ["https://example.com?executor=forged", "https://user@example.com", "https://example.com#fragment", "file:///tmp/gpu"] {
            XCTAssertThrowsError(try LiveGPUConnection.makeRequest(hostURL: URL(string: url)!, phoneToken: "phone"))
        }
        XCTAssertThrowsError(try LiveGPUConnection.makeRequest(hostURL: URL(string: "https://example.com")!, phoneToken: "x\r\ny"))
    }

    func testExactUpgradeAndNoCompression() throws {
        for selected in [nil, "binary", "CABOOSE.GPU.LIVE.V1", "caboose.gpu.live.v1, binary"] as [String?] {
            XCTAssertThrowsError(try LiveGPUConnection.validateUpgrade(selected: selected, extensions: nil))
        }
        try LiveGPUConnection.validateUpgrade(selected: "caboose.gpu.live.v1", extensions: nil)
        XCTAssertThrowsError(try LiveGPUConnection.validateUpgrade(selected: "caboose.gpu.live.v1", extensions: "permessage-deflate"))
    }

    func testBinaryOnlyAndExactMessageBoundary() throws {
        XCTAssertThrowsError(try LiveGPUConnection.binaryBytes(.string("hello")))
        XCTAssertEqual(try LiveGPUConnection.binaryBytes(.data(Data(repeating: 1, count: 256 * 1024))).count, 256 * 1024)
        XCTAssertThrowsError(try LiveGPUConnection.binaryBytes(.data(Data(repeating: 1, count: 256 * 1024 + 1))))
    }

    func testByteAndMessageCapsIncludeRunningWork() {
        let budget = LiveGPUBudget()
        for _ in 0..<32 { XCTAssertNil(budget.admit(256 * 1024)) }
        XCTAssertEqual(budget.retained.bytes, LiveGPUBudget.byteLimit)
        XCTAssertEqual(budget.admit(1), .overflow)
        XCTAssertFalse(budget.active)
        budget.release(256 * 1024)
        XCTAssertEqual(budget.admit(1), .closed)
        XCTAssertEqual(budget.retained.bytes, LiveGPUBudget.byteLimit - 256 * 1024)
        let count = LiveGPUBudget()
        for _ in 0..<LiveGPUBudget.countLimit { XCTAssertNil(count.admit(0)) }
        XCTAssertEqual(count.admit(0), .overflow)
        let oversized = LiveGPUBudget()
        XCTAssertEqual(oversized.admit(256 * 1024 + 1), .messageTooLarge)
        XCTAssertEqual(oversized.retained.count, 0)
    }

    func testConcurrentAdmissionCannotOverbookAndRevokeDoesNotFreeRetainedBytes() {
        let budget = LiveGPUBudget()
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in _ = budget.admit(16 * 1024) }
        XCTAssertEqual(budget.retained.count, 512)
        XCTAssertEqual(budget.retained.bytes, LiveGPUBudget.byteLimit)
        budget.revoke()
        XCTAssertEqual(budget.retained.bytes, LiveGPUBudget.byteLimit)
        for _ in 0..<512 { budget.release(16 * 1024) }
        XCTAssertEqual(budget.retained.bytes, 0)
    }

    func testMissingBindingFailsBeforeTransportOpens() {
        let transport = GPUTransportProbe()
        XCTAssertThrowsError(try LiveGPUSession(transport: transport, nativeBinding: nil))
        XCTAssertEqual(transport.opens, 0)
    }

    func testRevocationUnblocksConsumerBeforeFinishAndFencesLateEvents() throws {
        let transport = GPUTransportProbe()
        let consumer = GPUConsumerProbe()
        let session = try LiveGPUSession(transport: transport, nativeBinding: consumer)
        let ready = expectation(description: "opened")
        let ended = expectation(description: "cleaned")
        session.start {
            switch $0 {
            case .transportOpened: ready.fulfill()
            case .ended(let cause, let cleanup):
                XCTAssertNil(cause); XCTAssertNil(cleanup); ended.fulfill()
            }
        }
        wait(for: [ready], timeout: 2)
        XCTAssertTrue(consumer.output?(Data([4, 5])) ?? false)
        transport.emit(.bytes(Data([1])))
        XCTAssertEqual(consumer.entered.wait(timeout: .now() + 2), .success)
        session.abort()
        transport.emit(.opened)
        transport.emit(.bytes(Data([2])))
        wait(for: [ended], timeout: 2)
        XCTAssertEqual(consumer.history, ["start", "consume", "revoke", "returned", "finish"])
        XCTAssertFalse(consumer.output?(Data([9])) ?? true)
        session.start { _ in XCTFail("one-shot session restarted") }
        XCTAssertEqual(transport.opens, 1)
    }

    func testGracefulCloseKeepsTransportOpenUntilBrokerClose() throws {
        let transport = GPUTransportProbe()
        let consumer = GPUConsumerProbe()
        let session = try LiveGPUSession(transport: transport, nativeBinding: consumer)
        let ready = expectation(description: "opened")
        let ended = expectation(description: "broker closed after retirement")
        session.start {
            switch $0 {
            case .transportOpened: ready.fulfill()
            case .ended(let cause, let cleanup):
                XCTAssertNil(cause); XCTAssertNil(cleanup); ended.fulfill()
            }
        }
        wait(for: [ready], timeout: 2)
        session.close(); session.close()
        XCTAssertEqual(consumer.drainEntered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(consumer.history, ["start", "drain"])
        XCTAssertEqual(transport.closes, 0)
        XCTAssertTrue(consumer.output?(Data([7])) ?? false)
        transport.emit(.closed(nil))
        wait(for: [ended], timeout: 2)
        XCTAssertEqual(consumer.history, ["start", "drain", "revoke", "finish"])
        XCTAssertEqual(transport.closes, 1)
    }

    func testDrainDeadlineInterruptsBlockedConsumerWithoutClaimingPeerRetirement() throws {
        let transport = GPUTransportProbe()
        let consumer = GPUConsumerProbe()
        let session = try LiveGPUSession(transport: transport, nativeBinding: consumer, drainTimeout: 0.05)
        let ready = expectation(description: "opened")
        let ended = expectation(description: "forced local cleanup")
        session.start {
            switch $0 {
            case .transportOpened: ready.fulfill()
            case .ended(let cause, let cleanup):
                XCTAssertEqual(cause as? LiveGPUError, .drainTimedOut)
                XCTAssertNil(cleanup); ended.fulfill()
            }
        }
        wait(for: [ready], timeout: 2)
        transport.emit(.bytes(Data([1])))
        XCTAssertEqual(consumer.entered.wait(timeout: .now() + 2), .success)
        session.close()
        wait(for: [ended], timeout: 2)
        XCTAssertEqual(consumer.history, ["start", "consume", "revoke", "returned", "finish"])
        XCTAssertEqual(transport.closes, 1)
    }

    func testReplacementRequiresReceiptNormalPeerCloseAndSuccessfulCleanup() throws {
        for (receipt, peerClose, cleanupFails, expected) in [
            (true, true, false, true), (false, true, false, false),
            (true, false, false, false), (true, true, true, false)
        ] {
            let transport = GPUTransportProbe()
            let consumer = GPUConsumerProbe()
            consumer.retirementReceiptSent = receipt
            if cleanupFails { consumer.finishError = LiveGPUError.closed }
            let session = try LiveGPUSession(transport: transport, nativeBinding: consumer)
            let ready = expectation(description: "ready"), ended = expectation(description: "ended")
            session.start {
                switch $0 {
                case .transportOpened: ready.fulfill()
                case .ended: ended.fulfill()
                }
            }
            wait(for: [ready], timeout: 2)
            if peerClose { transport.emit(.closed(nil)) } else { session.abort() }
            wait(for: [ended], timeout: 2)
            XCTAssertEqual(session.remoteRetirementCompleted, expected)
        }
    }

    func testCleanupThatNeverReturnsStillEndsTheExecutorAsFailed() throws {
        let transport = GPUTransportProbe()
        let consumer = GPUConsumerProbe()
        let gate = DispatchSemaphore(value: 0)
        consumer.finishGate = gate
        let session = try LiveGPUSession(transport: transport, nativeBinding: consumer, drainTimeout: 10, cleanupTimeout: 0.1)
        let ready = expectation(description: "opened"), ended = expectation(description: "ended once")
        session.start {
            switch $0 {
            case .transportOpened: ready.fulfill()
            case .ended(let cause, let cleanup):
                XCTAssertEqual(cause as? LiveGPUError, .closed)
                XCTAssertEqual(cleanup as? LiveGPUError, .cleanupTimedOut)
                ended.fulfill()
            }
        }
        wait(for: [ready], timeout: 2)
        transport.emit(.closed(LiveGPUError.closed))
        wait(for: [ended], timeout: 2)
        XCTAssertFalse(session.remoteRetirementCompleted)
        // The cleanup returning later reports nothing more.
        gate.signal()
        Thread.sleep(forTimeInterval: 0.1)
    }

    func testBehindDecoderHoldsReceivingBackInsteadOfOverflowing() throws {
        let transport = GPUFlowTransportProbe()
        let consumer = GPUGatedConsumer()
        let session = try LiveGPUSession(transport: transport, nativeBinding: consumer)
        let ready = expectation(description: "opened")
        session.start { if case .transportOpened = $0 { ready.fulfill() } }
        wait(for: [ready], timeout: 2)
        // A socket that honours the pause delivers nothing more once it is asked to wait.
        var sent = 0
        while !transport.paused && sent < LiveGPUBudget.countLimit {
            transport.emit(.bytes(Data(repeating: 1, count: 64))); sent += 1
        }
        XCTAssertTrue(transport.paused)
        XCTAssertEqual(sent, LiveGPUBudget.pauseCount)
        consumer.open()
        let resumed = expectation(description: "resumed")
        transport.onChange = { if !$0 { resumed.fulfill() } }
        wait(for: [resumed], timeout: 5)
        XCTAssertEqual(transport.changes, [true, false])
        session.abort()
    }

    func testQueuedInputKeepsItsChargeUntilTheConsumerReleasesIt() throws {
        let transport = GPUFlowTransportProbe()
        let consumer = GPUQueuingConsumer()
        let session = try LiveGPUSession(transport: transport, nativeBinding: consumer)
        let ready = expectation(description: "opened")
        session.start { if case .transportOpened = $0 { ready.fulfill() } }
        wait(for: [ready], timeout: 2)
        // consume returns at once, yet the queued input still counts against the budget.
        var sent = 0
        while !transport.paused && sent < LiveGPUBudget.countLimit {
            transport.emit(.bytes(Data(repeating: 1, count: 64))); sent += 1
        }
        XCTAssertTrue(transport.paused)
        XCTAssertEqual(sent, LiveGPUBudget.pauseCount)
        let resumed = expectation(description: "resumed")
        transport.onChange = { if !$0 { resumed.fulfill() } }
        consumer.releaseAll()
        wait(for: [resumed], timeout: 5)
        XCTAssertEqual(transport.changes, [true, false])
        session.abort()
    }

    func testIngressOverflowCancelsBlockedConsumerAndReportsCleanupFailure() throws {
        let transport = GPUTransportProbe()
        let consumer = GPUConsumerProbe()
        consumer.finishError = LiveGPUError.closed
        let session = try LiveGPUSession(transport: transport, nativeBinding: consumer)
        let ready = expectation(description: "opened")
        let ended = expectation(description: "failed cleanup")
        session.start {
            switch $0 {
            case .transportOpened: ready.fulfill()
            case .ended(let cause, let cleanup):
                XCTAssertEqual(cause as? LiveGPUError, .overflow)
                XCTAssertEqual(cleanup as? LiveGPUError, .closed)
                ended.fulfill()
            }
        }
        wait(for: [ready], timeout: 2)
        transport.emit(.bytes(Data(repeating: 1, count: 256 * 1024)))
        XCTAssertEqual(consumer.entered.wait(timeout: .now() + 2), .success)
        for _ in 0..<32 { transport.emit(.bytes(Data(repeating: 1, count: 256 * 1024))) }
        wait(for: [ended], timeout: 2)
        XCTAssertEqual(consumer.history.filter { $0 == "consume" }.count, 1)
        XCTAssertEqual(consumer.history.last, "finish")
    }
}

private final class GPUTransportProbe: LiveGPUTransport, @unchecked Sendable {
    var event: (@Sendable (LiveGPUTransportEvent) -> Void)?
    var opens = 0
    private let lock = NSLock()
    private var closeCount = 0
    var closes: Int { lock.withLock { closeCount } }
    func open(_ event: @escaping @Sendable (LiveGPUTransportEvent) -> Void) {
        opens += 1; self.event = event; event(.opened)
    }
    func send(_ bytes: Data) -> Bool { true }
    func close() { lock.withLock { closeCount += 1 } }
    func emit(_ event: LiveGPUTransportEvent) { self.event?(event) }
}

private final class GPUConsumerProbe: LiveGPUByteConsumer, LiveGPURetirementReporting, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let drainEntered = DispatchSemaphore(value: 0)
    private let unblock = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var records: [String] = []
    var history: [String] { lock.withLock { records } }
    var output: (@Sendable (Data) -> Bool)?
    var finishError: Error?
    var retirementReceiptSent = false
    private func record(_ s: String) { lock.withLock { records.append(s) } }
    func start(output: @escaping @Sendable (Data) -> Bool, failed: @escaping @Sendable (Error) -> Void) throws {
        self.output = output; record("start")
    }
    func consume(_ bytes: Data) throws {
        record("consume"); entered.signal()
        _ = unblock.wait(timeout: .now() + 5)
        record("returned")
    }
    func requestDrain() throws { record("drain"); drainEntered.signal() }
    func revoke() throws { record("revoke"); unblock.signal() }
    var finishGate: DispatchSemaphore?
    func finish() throws {
        record("finish"); finishGate?.wait()
        if let finishError { throw finishError }
    }
}

private final class GPUFlowTransportProbe: LiveGPUTransport, LiveGPUReceiveFlow, @unchecked Sendable {
    private let lock = NSLock()
    private var event: (@Sendable (LiveGPUTransportEvent) -> Void)?
    private var history: [Bool] = []
    var onChange: ((Bool) -> Void)?
    var paused: Bool { lock.withLock { history.last ?? false } }
    var changes: [Bool] { lock.withLock { history } }
    func open(_ event: @escaping @Sendable (LiveGPUTransportEvent) -> Void) {
        lock.withLock { self.event = event }; event(.opened)
    }
    func send(_ bytes: Data) -> Bool { true }
    func close() {}
    func emit(_ event: LiveGPUTransportEvent) { lock.withLock { self.event }?(event) }
    func setReceivingPaused(_ paused: Bool) {
        let change = lock.withLock { () -> ((Bool) -> Void)? in history.append(paused); return onChange }
        change?(paused)
    }
}

/// Holds every consume until opened.
private final class GPUGatedConsumer: LiveGPUByteConsumer, @unchecked Sendable {
    private let gate = DispatchGroup()
    init() { gate.enter() }
    func open() { gate.leave() }
    func start(output: @escaping @Sendable (Data) -> Bool, failed: @escaping @Sendable (Error) -> Void) throws {}
    func consume(_ bytes: Data) throws { _ = gate.wait(timeout: .now() + 5) }
    func requestDrain() throws {}
    func revoke() throws {}
    func finish() throws {}
}

/// Queues every input and releases its charge only when the test says so.
private final class GPUQueuingConsumer: LiveGPUByteConsumer, LiveGPUDeferredIngress, @unchecked Sendable {
    private let lock = NSLock()
    private var releases: [@Sendable () -> Void] = []
    private var releasing = false
    func start(output: @escaping @Sendable (Data) -> Bool, failed: @escaping @Sendable (Error) -> Void) throws {}
    func consume(_ bytes: Data) throws { XCTFail("the session passes the release") }
    func consume(_ bytes: Data, release: @escaping @Sendable () -> Void) throws {
        // Once released, input still on its way to the consumer is released as it arrives.
        if lock.withLock({ () -> Bool in if !releasing { releases.append(release) }; return releasing }) { release() }
    }
    func releaseAll() {
        let pending = lock.withLock { () -> [@Sendable () -> Void] in
            releasing = true
            defer { releases = [] }
            return releases
        }
        for release in pending { release() }
    }
    func requestDrain() throws {}
    func revoke() throws {}
    func finish() throws {}
}
