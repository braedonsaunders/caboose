import XCTest
@testable import CabooseKit

private final class IndexedAcquireProbe: LiveGPUAcquireOperation, @unchecked Sendable {
    var cancelled = false
    let pending: Bool
    private let gateLock = NSLock()
    private var queryEntered = true
    var signalled = false
    var observations = 0
    let signal = DispatchSemaphore(value: 0)
    init(pending: Bool, waitForQuery: Bool = false) { self.pending = pending; queryEntered = !waitForQuery }
    func enterQuery() { gateLock.withLock { queryEntered = true } }
    func poll() -> LiveGPUAcquireCompletion {
        if cancelled { return .init(status: .init(nativeErrno: ECANCELED, vkResult: nil), index: nil, reason: .cancelled) }
        return pending ? .init(status: .init(nativeErrno: 0, vkResult: 1), index: nil, reason: .none)
            : .init(status: .init(nativeErrno: 0, vkResult: 0), index: 0, reason: .none)
    }
    func cancel() -> Int32 { if !pending { return EALREADY }; cancelled = true; return 0 }
    func observeSignal() -> LiveGPUSurfaceStatus {
        observations += 1
        signalled = observations > 1 && gateLock.withLock { queryEntered }
        if signalled { signal.signal() }
        return .init(nativeErrno: 0, vkResult: signalled ? 0 : 1)
    }
    func release() -> Int32 { pending ? (cancelled ? 0 : EBUSY) : (signalled ? 0 : EBUSY) }
}
private final class IndexedSwapProbe: LiveGPUIndexedSwapchain, @unchecked Sendable {
    let id: UInt64 = 7
    let imageCount: UInt32 = 2
    var mapped = false
    var pendingAcquire = false
    var waitForQuery = false
    var badFinal = false
    var retireErrno: Int32 = 0
    var operation: IndexedAcquireProbe?
    var presents = 0
    var retirements = 0
    func map(_ images: [UInt64]) -> LiveGPUSurfaceStatus {
        mapped = images == [101,102]
        return .init(nativeErrno: mapped ? 0 : EINVAL, vkResult: nil)
    }
    func beginAcquire(_ info: LiveGPUSwapchainAcquire) -> (LiveGPUSurfaceStatus, (any LiveGPUAcquireOperation)?) {
        let value = IndexedAcquireProbe(pending: pendingAcquire, waitForQuery: waitForQuery); operation = value
        return (.init(nativeErrno: 0, vkResult: nil), value)
    }
    func present(_ info: LiveGPUIndexedPresent,
                 event: @escaping @Sendable (LiveGPUSurfaceMessage.Body) -> Void) -> LiveGPUSurfaceSubmission {
        XCTAssertTrue(operation?.signalled == true, "present preceded actual signal observation")
        presents += 1
        if !badFinal { event(.sourceReleased(serial: info.serial)) }
        event(.swapchain(.presentRetired(swapchain: id, serial: info.serial)))
        return .init(status: .init(nativeErrno: 0, vkResult: 0), disposition: .queued)
    }
    func retire() -> LiveGPUSurfaceStatus {
        retirements += 1; return .init(nativeErrno: retireErrno, vkResult: nil)
    }
}
private final class IndexedSurfaceProbe: LiveGPUIndexedSurfaceResource, @unchecked Sendable {
    let swap = IndexedSwapProbe()
    var waitForSignalInQuery = false
    var retired = 0
    /// The device stream's decoded ORDER mark; waits block until it reaches theirs.
    private let orderLock = NSCondition()
    private var decoded: UInt64 = 0
    private var orderFailure: Int32 = 0
    func decode(through order: UInt64) { orderLock.lock(); decoded = max(decoded, order); orderLock.broadcast(); orderLock.unlock() }
    func failOrders(_ code: Int32) { orderLock.lock(); orderFailure = code; orderLock.broadcast(); orderLock.unlock() }
    func waitOrder(_ serial: UInt64) -> Int32 {
        orderLock.lock(); defer { orderLock.unlock() }
        while decoded < serial && orderFailure == 0 { orderLock.wait() }
        return decoded >= serial ? 0 : orderFailure
    }
    func create(_ info: LiveGPUSwapchainCreate) -> (LiveGPUSurfaceStatus, (any LiveGPUIndexedSwapchain)?) {
        (.init(nativeErrno: 0, vkResult: 0), swap)
    }
    func query(physicalDevice: UInt64) -> (LiveGPUSurfaceStatus, LiveGPUSurfaceCapabilities?) {
        if waitForSignalInQuery {
            swap.operation?.enterQuery()
            let observed = swap.operation?.signal.wait(timeout: .now()+1) == .success
            return (.init(nativeErrno: observed ? ENOTSUP : EDEADLK, vkResult: nil), nil)
        }
        return (.init(nativeErrno: ENOTSUP, vkResult: nil), nil)
    }
    func present(_ request: LiveGPUSurfacePresent,
                 event: @escaping @Sendable (LiveGPUSurfaceMessage.Body) -> Void) -> LiveGPUSurfaceSubmission {
        XCTFail("obsolete present path called"); return .init(status: .init(nativeErrno: ENOTSUP, vkResult: nil), disposition: .rejected)
    }
    func retire() throws { retired += 1 }
}
private final class IndexedReceipts: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LiveGPUSurfaceMessage.Body] = []
    private var problems: [Error] = []
    var closed = false
    var bodies: [LiveGPUSurfaceMessage.Body] { lock.withLock { stored } }
    var errors: [Error] { lock.withLock { problems } }
    let mapped = DispatchSemaphore(value: 0)
    let final = DispatchSemaphore(value: 0)
    let acquired = DispatchSemaphore(value: 0)
    let stopped = DispatchSemaphore(value: 0)
    func add(_ body: LiveGPUSurfaceMessage.Body) throws {
        if lock.withLock({ closed }) { throw LiveGPUError.closed }
        lock.withLock { stored.append(body) }
        switch body {
        case .swapchain(.mapped): mapped.signal()
        case .swapchain(.acquired): acquired.signal()
        case .swapchain(.presentRetired): final.signal()
        case .swapchain(.retired): stopped.signal()
        default: break
        }
    }
    func fail(_ error: Error) { lock.withLock { problems.append(error) }; stopped.signal() }
}
final class LiveGPUIndexedSurfaceTests: XCTestCase {
    private func prepare(_ native: IndexedSurfaceProbe, _ receipts: IndexedReceipts) throws -> LiveGPUIndexedSurface {
        let engine = LiveGPUIndexedSurface(resource: native, budget: LiveGPUBudget(), emit: { try receipts.add($0) }, failed: { receipts.fail($0) })
        try engine.enqueue(.create(.init(request: 1, device: 2, oldSwapchain: 0, flags: 0, minImageCount: 2,
            format: 44, colorSpace: 0, width: 800, height: 600, arrayLayers: 1, usage: 2, preTransform: 1,
            compositeAlpha: 1, presentMode: 2, clipped: true, sharingMode: 0, families: [])))
        try engine.enqueue(.map(swapchain: 7, images: [101,102]))
        XCTAssertEqual(receipts.mapped.wait(timeout: .now()+2), .success)
        return engine
    }
    private func acquire(_ request: UInt64) -> LiveGPUSwapchainMessage {
        .acquire(.init(swapchain: 7, request: request, semaphore: 20, fence: 0, timeoutNanoseconds: .max, deviceMask: 1))
    }
    private func present(_ serial: UInt64, order: UInt64 = 0, index: UInt32 = 0) -> LiveGPUSwapchainMessage {
        .present(.init(swapchain: 7, serial: serial, queue: 30, index: index, family: 0, layout: 1, waits: [20], order: order))
    }
    private func kinds(_ receipts: IndexedReceipts) -> [LiveGPUEnvelope.Kind] {
        receipts.bodies.map { LiveGPUSurfaceMessage(identity: .init(epoch: Data(), grant: Data(), generation: 1), body: $0).kind }
    }
    func testOrderedPresentRunsOnlyAfterItsDeviceStreamMark() throws {
        let native = IndexedSurfaceProbe(), receipts = IndexedReceipts()
        let engine = try prepare(native, receipts)
        try engine.enqueue(acquire(2)); try engine.enqueue(present(1, order: 5))
        XCTAssertEqual(receipts.acquired.wait(timeout: .now()+2), .success)
        native.decode(through: 4)
        XCTAssertEqual(receipts.final.wait(timeout: .now()+0.2), .timedOut, "presented before its mark was decoded")
        XCTAssertEqual(native.swap.presents, 0)
        native.decode(through: 5)
        XCTAssertEqual(receipts.final.wait(timeout: .now()+2), .success)
        XCTAssertEqual(kinds(receipts), [.swapchainCreated,.swapchainMapped,.swapchainAcquired,.presentResult,.sourceReleased,.presentRetired])
        // A later present whose mark is already decoded does not wait again.
        try engine.enqueue(acquire(3)); try engine.enqueue(present(2, order: 5))
        XCTAssertEqual(receipts.final.wait(timeout: .now()+2), .success)
        XCTAssertEqual(native.swap.presents, 2)
        try engine.retire()
        XCTAssertTrue(receipts.errors.isEmpty)
    }
    func testOrderedPresentsKeepTheirOrderWhenMarksArriveTogether() throws {
        let native = IndexedSurfaceProbe(), receipts = IndexedReceipts()
        let engine = try prepare(native, receipts)
        try engine.enqueue(acquire(2)); try engine.enqueue(present(1, order: 7, index: 0))
        XCTAssertEqual(receipts.acquired.wait(timeout: .now()+2), .success)
        native.decode(through: 9)
        XCTAssertEqual(receipts.final.wait(timeout: .now()+2), .success)
        try engine.enqueue(acquire(3)); try engine.enqueue(present(2, order: 8, index: 0))
        XCTAssertEqual(receipts.final.wait(timeout: .now()+2), .success)
        let results = receipts.bodies.compactMap { body -> UInt64? in
            if case .presentResult(let serial, _, _, _) = body { return serial }; return nil
        }
        XCTAssertEqual(results, [1, 2])
        try engine.retire()
        XCTAssertTrue(receipts.errors.isEmpty)
    }
    func testOrderedPresentIsRejectedWhenItsProcessStops() throws {
        let native = IndexedSurfaceProbe(), receipts = IndexedReceipts()
        let engine = try prepare(native, receipts)
        try engine.enqueue(acquire(2)); try engine.enqueue(present(1, order: 3))
        XCTAssertEqual(receipts.acquired.wait(timeout: .now()+2), .success)
        native.failOrders(ECANCELED)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline && !receipts.bodies.contains(where: {
            if case .presentResult(1, let status, .rejected, .submission) = $0 { return status.nativeErrno == ECANCELED }
            return false
        }) { usleep(1000) }
        XCTAssertTrue(receipts.bodies.contains { if case .presentResult(1, _, .rejected, _) = $0 { return true }; return false })
        XCTAssertEqual(native.swap.presents, 0)
        try engine.retire()
        XCTAssertTrue(receipts.errors.isEmpty)
    }
    func testPresentationWaitsForSignalAndSerializesSynchronousFinalCallbacks() throws {
        let native = IndexedSurfaceProbe(), receipts = IndexedReceipts()
        let engine = try prepare(native, receipts)
        try engine.enqueue(acquire(2)); try engine.enqueue(present(1))
        XCTAssertEqual(receipts.final.wait(timeout: .now()+2), .success)
        let kinds = receipts.bodies.map { LiveGPUSurfaceMessage(identity: .init(epoch: Data(), grant: Data(), generation: 1), body: $0).kind }
        XCTAssertEqual(kinds, [.swapchainCreated,.swapchainMapped,.swapchainAcquired,.presentResult,.sourceReleased,.presentRetired])
        try engine.enqueue(.retire(swapchain: 7))
        XCTAssertEqual(receipts.stopped.wait(timeout: .now()+2), .success)
        try engine.retire()
        XCTAssertEqual(native.swap.retirements, 1); XCTAssertTrue(receipts.errors.isEmpty)
    }
    func testMoreThanHistoryLimitFramesRetireWithoutRetainingEverySerial() throws {
        let native = IndexedSurfaceProbe(), receipts = IndexedReceipts()
        let engine = try prepare(native, receipts)
        for i: UInt64 in 1...80 {
            try engine.enqueue(acquire(i+1)); try engine.enqueue(present(i))
            XCTAssertEqual(receipts.final.wait(timeout: .now()+2), .success)
        }
        try engine.retire()
        XCTAssertEqual(native.swap.presents, 80); XCTAssertEqual(native.swap.retirements, 1)
        XCTAssertTrue(receipts.errors.isEmpty)
    }
    func testSignalObserverCannotBeBlockedByAnotherNativeSurfaceCall() throws {
        let native = IndexedSurfaceProbe(), receipts = IndexedReceipts()
        native.waitForSignalInQuery = true; native.swap.waitForQuery = true
        let engine = try prepare(native, receipts)
        try engine.enqueue(acquire(2))
        XCTAssertEqual(receipts.acquired.wait(timeout: .now()+2), .success)
        // Represents a decoder operation holding a lock while waiting for the
        // acquired fence lease. Independent observation must still complete.
        XCTAssertEqual(engine.query(physicalDevice: 3).0.nativeErrno, ENOTSUP)
        try engine.enqueue(present(1))
        XCTAssertEqual(receipts.final.wait(timeout: .now()+2), .success)
        try engine.retire()
        XCTAssertTrue(receipts.errors.isEmpty)
    }
    func testCancellationAndRetirementRunWhileAcquireIsPolling() throws {
        let native = IndexedSurfaceProbe(), receipts = IndexedReceipts(); native.swap.pendingAcquire = true
        let engine = try prepare(native, receipts)
        try engine.enqueue(acquire(2)); try engine.enqueue(.cancelAcquire(swapchain: 7, request: 2))
        try engine.enqueue(.retire(swapchain: 7))
        XCTAssertEqual(receipts.stopped.wait(timeout: .now()+2), .success)
        try engine.retire()
        XCTAssertTrue(receipts.bodies.contains {
            if case .swapchain(.acquired(_, _, _, nil, .cancelled)) = $0 { return true }; return false
        })
        XCTAssertEqual(native.swap.presents, 0); XCTAssertTrue(receipts.errors.isEmpty)
    }
    func testClosedOutputDuringAcquireAndPendingPresentDoesNotPoisonNativeRetirement() throws {
        let native = IndexedSurfaceProbe(), receipts = IndexedReceipts(); native.swap.pendingAcquire = true
        let engine = try prepare(native, receipts)
        try engine.enqueue(acquire(2))
        try engine.enqueue(present(1))
        receipts.closed = true
        try engine.retire()
        XCTAssertEqual(native.swap.retirements, 1)
        XCTAssertTrue(receipts.errors.isEmpty)
    }
    func testSurfaceRetirementFailureDuringRevokeReportsNativeErrorWithoutPoisoningSession() throws {
        let native = IndexedSurfaceProbe(), receipts = IndexedReceipts()
        native.swap.retireErrno = EBUSY
        let engine = try prepare(native, receipts)
        XCTAssertThrowsError(try engine.retire()) { error in
            XCTAssertEqual(error as? LiveGPUBindingError, .native(operation: "indexed retirement", code: EBUSY))
        }
        XCTAssertEqual(native.swap.retirements, 1)
        XCTAssertTrue(receipts.errors.isEmpty)
    }
    func testFinalWithoutSourceFenceFailsAndCannotClaimRetirement() throws {
        let native = IndexedSurfaceProbe(), receipts = IndexedReceipts(); native.swap.badFinal = true
        let engine = try prepare(native, receipts)
        try engine.enqueue(acquire(2)); try engine.enqueue(present(1))
        XCTAssertEqual(receipts.stopped.wait(timeout: .now()+2), .success)
        XCTAssertFalse(receipts.errors.isEmpty)
        XCTAssertThrowsError(try engine.retire())
        XCTAssertEqual(native.swap.retirements, 0)
        XCTAssertFalse(receipts.bodies.contains { if case .swapchain(.presentRetired) = $0 { return true }; return false })
    }
}
