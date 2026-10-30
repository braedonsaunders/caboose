import XCTest
@testable import CabooseKit

private final class AcquireOperationProbe: LiveGPUAcquireOperation, @unchecked Sendable {
    let lock = NSLock()
    var values: [LiveGPUAcquireCompletion] = []
    var signals: [LiveGPUSurfaceStatus] = []
    var cancelCode: Int32 = 0
    var releaseCode: Int32 = 0
    var polls = 0, cancels = 0, observations = 0, releases = 0
    let entered = DispatchSemaphore(value: 0)
    func poll() -> LiveGPUAcquireCompletion {
        lock.withLock {
            polls += 1; entered.signal()
            return values.count > 1 ? values.removeFirst() : values[0]
        }
    }
    func cancel() -> Int32 { lock.withLock { cancels += 1; return cancelCode } }
    func observeSignal() -> LiveGPUSurfaceStatus {
        lock.withLock { observations += 1; return signals.count > 1 ? signals.removeFirst() : signals[0] }
    }
    func release() -> Int32 { lock.withLock { releases += 1; return releaseCode } }
}
final class LiveGPUAcquireTaskTests: XCTestCase {
    private let pending = LiveGPUAcquireCompletion(status: .init(nativeErrno: 0, vkResult: 1), index: nil, reason: .none)
    private let success = LiveGPUAcquireCompletion(status: .init(nativeErrno: 0, vkResult: 0), index: 2, reason: .none)
    private let queue = DispatchQueue(label: "test.gpu.acquire")

    func testZeroTimeoutPreservesActualNotReadyAndReleasesUnsignalledRequest() {
        let native = AcquireOperationProbe(); native.values = [pending]
        let done = expectation(description: "finished")
        let task = LiveGPUAcquireTask(operation: native, queue: queue, timeoutNanoseconds: 0,
            completion: { [pending] in XCTAssertEqual($0, pending) },
            signalReady: { _ in XCTFail("not acquired") }, finished: { XCTAssertNil($0); done.fulfill() })
        task.start(); wait(for: [done], timeout: 2)
        XCTAssertEqual(native.polls, 1); XCTAssertEqual(native.cancels, 1)
        XCTAssertEqual(native.observations, 0); XCTAssertEqual(native.releases, 1)
    }
    func testFiniteDeadlineIsLocalOnlyAfterSuccessfulCancellation() {
        let native = AcquireOperationProbe(); native.values = [pending]
        let done = expectation(description: "deadline")
        let task = LiveGPUAcquireTask(operation: native, queue: queue, timeoutNanoseconds: 1,
            completion: {
                XCTAssertEqual($0.reason, .deadline); XCTAssertEqual($0.status.nativeErrno, ETIMEDOUT)
                XCTAssertNil($0.status.vkResult); XCTAssertNil($0.index)
            }, signalReady: { _ in XCTFail() }, finished: { XCTAssertNil($0); done.fulfill() })
        task.start(); wait(for: [done], timeout: 2)
        XCTAssertEqual(native.cancels, 1); XCTAssertEqual(native.releases, 1)
    }
    func testPollingYieldsAndCancellationDoesNotBlockConsumerQueue() {
        let native = AcquireOperationProbe(); native.values = [pending]
        let done = expectation(description: "cancelled"), interleaved = expectation(description: "queue remains available")
        let task = LiveGPUAcquireTask(operation: native, queue: queue, timeoutNanoseconds: .max,
            pollIntervalNanoseconds: 100_000_000, completion: {
                XCTAssertEqual($0.reason, .cancelled); XCTAssertNil($0.index)
            }, signalReady: { _ in XCTFail() }, finished: { XCTAssertNil($0); done.fulfill() })
        task.start()
        XCTAssertEqual(native.entered.wait(timeout: .now() + 2), .success)
        queue.async { interleaved.fulfill() }
        task.cancel()
        wait(for: [interleaved, done], timeout: 2)
        XCTAssertEqual(native.releases, 1)
    }
    func testActualAcquireWinningCancellationKeepsIndexAndObservesSignal() {
        let native = AcquireOperationProbe(); native.values = [pending, success]; native.cancelCode = EALREADY
        native.signals = [.init(nativeErrno: 0, vkResult: 1), .init(nativeErrno: 0, vkResult: 0)]
        let received = expectation(description: "one actual acquire"), done = expectation(description: "signal released")
        received.assertForOverFulfill = true
        let task = LiveGPUAcquireTask(operation: native, queue: queue, timeoutNanoseconds: 0,
            completion: { [success] in XCTAssertEqual($0, success); received.fulfill() },
            signalReady: { XCTAssertEqual($0, 2) }, finished: { XCTAssertNil($0); done.fulfill() })
        task.start(); wait(for: [received, done], timeout: 2)
        task.cancel(); queue.sync {} // Late cancellation is not a second terminal result.
        XCTAssertEqual(native.releases, 1); XCTAssertEqual(native.observations, 2)
    }
    func testPendingSignalDeadlineQuarantinesWithoutFreeingRequest() {
        let native = AcquireOperationProbe(); native.values = [success]
        native.signals = [.init(nativeErrno: 0, vkResult: 1)]
        let done = expectation(description: "quarantined")
        let task = LiveGPUAcquireTask(operation: native, queue: queue, timeoutNanoseconds: 0,
            signalBudgetNanoseconds: 0, completion: { [success] in XCTAssertEqual($0, success) },
            signalReady: { _ in XCTFail() }, finished: { XCTAssertEqual($0, .signalDeadline); done.fulfill() })
        task.start(); wait(for: [done], timeout: 2)
        XCTAssertEqual(native.releases, 0); XCTAssertEqual(native.cancels, 0)
    }
    func testContradictoryProviderIndexNeverPublishesOrReleases() {
        let native = AcquireOperationProbe()
        native.values = [.init(status: .init(nativeErrno: EPROTO, vkResult: 0), index: 2, reason: .none)]
        let done = expectation(description: "contradiction")
        let task = LiveGPUAcquireTask(operation: native, queue: queue, timeoutNanoseconds: 0,
            completion: { _ in XCTFail("forensic contradiction sent as success") }, signalReady: { _ in XCTFail() },
            finished: { XCTAssertEqual($0, .contradictoryResult); done.fulfill() })
        task.start(); wait(for: [done], timeout: 2)
        XCTAssertEqual(native.releases, 0)
    }
    func testCancellationLosingToProviderErrorPreservesActualResult() {
        let native = AcquireOperationProbe(); native.cancelCode = EIO
        native.values = [pending, .init(status: .init(nativeErrno: 0, vkResult: -1000001004), index: nil, reason: .none)]
        let done = expectation(description: "actual error")
        let task = LiveGPUAcquireTask(operation: native, queue: queue, timeoutNanoseconds: 0,
            completion: {
                XCTAssertEqual($0.status.vkResult, -1000001004)
                XCTAssertEqual($0.status.nativeErrno, 0); XCTAssertEqual($0.reason, .none)
            }, signalReady: { _ in XCTFail() }, finished: { XCTAssertNil($0); done.fulfill() })
        task.start(); wait(for: [done], timeout: 2)
        XCTAssertEqual(native.releases, 1)
    }
}
