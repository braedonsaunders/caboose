import Foundation
import Darwin
import XCTest
@testable import CabooseKit

@MainActor
final class LiveGPUOwnerWaiterTests: XCTestCase {
    func testCrossChannelMetadataAndLayoutResolveOnlyActualOwner() throws {
        let waiter = LiveGPUOwnerWaiter<Int>()
        var metadata = false, visible = false, results: [Int] = []
        waiter.request(resolve: {
            guard metadata && visible else { throw LiveGPUBindingError.native(operation: "pending", code: EAGAIN) }
            return 42
        }, complete: { result in if case .success(let owner) = result { results.append(owner) } })
        XCTAssertEqual(waiter.pendingCount, 1)
        metadata = true; waiter.retry()
        XCTAssertTrue(results.isEmpty)
        visible = true; waiter.retry(); waiter.retry()
        XCTAssertEqual(results, [42]); XCTAssertEqual(waiter.pendingCount, 0)
        waiter.cancel()
    }
    func testDeadlineRejectsInsteadOfInventingGeometry() async {
        let waiter = LiveGPUOwnerWaiter<Int>(timeout: 0.01)
        let completed = expectation(description: "missing view deadline")
        waiter.request(resolve: { throw LiveGPUBindingError.native(operation: "pending", code: EAGAIN) }) { result in
            if case .failure(let error) = result,
               case .native(_, let code) = error as? LiveGPUBindingError { XCTAssertEqual(code, EAGAIN) }
            else { XCTFail("missing geometry became success") }
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(waiter.pendingCount, 0)
        waiter.cancel()
    }
    func testCancellationAndCapacityPreserveBoundedAdmission() {
        let waiter = LiveGPUOwnerWaiter<Int>(capacity: 1)
        var codes: [Int32] = []
        let completion: @MainActor (Result<Int, Error>) -> Void = { result in
            if case .failure(let error) = result,
               case .native(_, let code) = error as? LiveGPUBindingError { codes.append(code) }
            else { XCTFail("unexpected owner") }
        }
        let pending: @MainActor () throws -> Int = { throw LiveGPUBindingError.native(operation: "pending", code: EAGAIN) }
        waiter.request(resolve: pending, complete: completion)
        waiter.request(resolve: pending, complete: completion)
        XCTAssertEqual(codes, [ENOSPC]); XCTAssertEqual(waiter.pendingCount, 1)
        waiter.cancel(); waiter.retry()
        waiter.request(resolve: { 42 }, complete: completion)
        XCTAssertEqual(codes, [ENOSPC, ECANCELED, ECANCELED])
        XCTAssertEqual(waiter.pendingCount, 0)
    }
    func testForeignEpochAndAmbiguousOwnerAreNotRetried() {
        let waiter = LiveGPUOwnerWaiter<Int>()
        var results = 0
        for code in [ESTALE, EBUSY] {
            waiter.request(resolve: { throw LiveGPUBindingError.native(operation: "invalid owner", code: code) }) { result in
                if case .failure = result { results += 1 } else { XCTFail("invalid owner") }
            }
        }
        XCTAssertEqual(results, 2); XCTAssertEqual(waiter.pendingCount, 0)
        waiter.cancel()
    }
}
