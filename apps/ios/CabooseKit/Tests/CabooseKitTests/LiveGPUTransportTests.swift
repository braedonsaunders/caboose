import Foundation
import XCTest
@testable import CabooseKit

final class LiveGPUTransportTests: XCTestCase {
    func testEndpointHasNoAuthorityOverrides() throws {
        let request = try LiveGPUConnection.makeRequest(hostURL: URL(string: "https://example.com/ignored")!, phoneToken: "phone")
        XCTAssertEqual(request.url?.absoluteString, "wss://example.com/v1/gpu")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol"), "caboose.gpu.live.v1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer phone")
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
        for _ in 0..<4 { XCTAssertNil(budget.admit(256 * 1024)) }
        XCTAssertEqual(budget.retained.bytes, 1024 * 1024)
        XCTAssertEqual(budget.admit(1), .overflow)
        XCTAssertFalse(budget.active)
        budget.release(256 * 1024)
        XCTAssertEqual(budget.admit(1), .closed)
        XCTAssertEqual(budget.retained.bytes, 768 * 1024)
        let count = LiveGPUBudget()
        for _ in 0..<64 { XCTAssertNil(count.admit(0)) }
        XCTAssertEqual(count.admit(0), .overflow)
        let oversized = LiveGPUBudget()
        XCTAssertEqual(oversized.admit(256 * 1024 + 1), .messageTooLarge)
        XCTAssertEqual(oversized.retained.count, 0)
    }

    func testConcurrentAdmissionCannotOverbookAndRevokeDoesNotFreeRetainedBytes() {
        let budget = LiveGPUBudget()
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in _ = budget.admit(16 * 1024) }
        XCTAssertEqual(budget.retained.count, 64)
        XCTAssertEqual(budget.retained.bytes, 1024 * 1024)
        budget.revoke()
        XCTAssertEqual(budget.retained.bytes, 1024 * 1024)
        for _ in 0..<64 { budget.release(16 * 1024) }
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
        session.close()
        transport.emit(.opened)
        transport.emit(.bytes(Data([2])))
        wait(for: [ended], timeout: 2)
        XCTAssertEqual(consumer.history, ["start", "consume", "revoke", "returned", "finish"])
        XCTAssertFalse(consumer.output?(Data([9])) ?? true)
        session.start { _ in XCTFail("one-shot session restarted") }
        XCTAssertEqual(transport.opens, 1)
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
        for _ in 0..<4 { transport.emit(.bytes(Data(repeating: 1, count: 256 * 1024))) }
        wait(for: [ended], timeout: 2)
        XCTAssertEqual(consumer.history.filter { $0 == "consume" }.count, 1)
        XCTAssertEqual(consumer.history.last, "finish")
    }
}

private final class GPUTransportProbe: LiveGPUTransport, @unchecked Sendable {
    var event: (@Sendable (LiveGPUTransportEvent) -> Void)?
    var opens = 0
    func open(_ event: @escaping @Sendable (LiveGPUTransportEvent) -> Void) {
        opens += 1; self.event = event; event(.opened)
    }
    func send(_ bytes: Data) -> Bool { true }
    func close() {}
    func emit(_ event: LiveGPUTransportEvent) { self.event?(event) }
}

private final class GPUConsumerProbe: LiveGPUByteConsumer, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    private let unblock = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var records: [String] = []
    var history: [String] { lock.withLock { records } }
    var output: (@Sendable (Data) -> Bool)?
    var finishError: Error?
    private func record(_ s: String) { lock.withLock { records.append(s) } }
    func start(output: @escaping @Sendable (Data) -> Bool, failed: @escaping @Sendable (Error) -> Void) throws {
        self.output = output; record("start")
    }
    func consume(_ bytes: Data) throws {
        record("consume"); entered.signal()
        _ = unblock.wait(timeout: .now() + 5)
        record("returned")
    }
    func revoke() throws { record("revoke"); unblock.signal() }
    func finish() throws { record("finish"); if let finishError { throw finishError } }
}
