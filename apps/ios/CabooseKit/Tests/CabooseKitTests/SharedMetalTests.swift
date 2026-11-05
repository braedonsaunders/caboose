import Foundation
import Metal
import QuartzCore
import XCTest
@testable import CabooseKit

/// The phone's own Metal never waits for a GPU that has stopped completing its work.
final class SharedMetalTests: XCTestCase {
    func testWindowHealthAcceptsCompletionBeforeNativeSubmissionReturns() {
        for background in [false, true] {
            let health = LiveGPUWindowHealthTracker()
            _ = health.submit(1, at: 10) {
                if background {
                    let completed = DispatchSemaphore(value: 0)
                    DispatchQueue.global().async { health.released(1); completed.signal() }
                    XCTAssertEqual(completed.wait(timeout: .now() + 1), .success,
                                   "Submission must not hold the lock needed by its completion")
                } else {
                    health.released(1)
                }
                return .init(status: .init(nativeErrno: 0, vkResult: 0), disposition: .queued)
            }
            XCTAssertEqual(health.state(at: 100), .running)
        }
    }

    func testRejectedSubmissionDoesNotLeaveAStalledWaitButUncertainWorkDoes() {
        let health = LiveGPUWindowHealthTracker()
        _ = health.submit(1, at: 10) {
            .init(status: .init(nativeErrno: 5, vkResult: nil), disposition: .rejected)
        }
        XCTAssertEqual(health.state(at: 100), .running)
        _ = health.submit(2, at: 100) {
            .init(status: .init(nativeErrno: 5, vkResult: nil), disposition: .uncertain)
        }
        XCTAssertEqual(health.state(at: 102), .stalled)
        health.released(2)
        XCTAssertEqual(health.state(at: 103), .running)
        _ = health.submit(3, at: 104) {
            health.deviceLost()
            return .init(status: .init(nativeErrno: 0, vkResult: -4), disposition: .uncertain)
        }
        XCTAssertEqual(health.state(at: 104), .lost)
    }

    func testAStalledGPURefusesCommandBuffersAndBoundsWaitsUntilItCompletesAgain() throws {
        let metal = SharedMetal()
        // Command buffers held by an event nobody signals stand in for a GPU that stopped.
        let hold = try XCTUnwrap(metal.device.makeSharedEvent())
        for _ in 0..<3 {
            let commands = try XCTUnwrap(metal.makeCommandBuffer())
            commands.encodeWaitForEvent(hold, value: 1)
            commands.commit()
        }
        XCTAssertFalse(metal.isStalled)
        // A bounded wait returns rather than block, while the GPU is held.
        let waiting = try XCTUnwrap(metal.makeCommandBuffer())
        let started = CACurrentMediaTime()
        XCTAssertFalse(metal.commitAndWait(waiting, timeout: 0.2))
        XCTAssertLessThan(CACurrentMediaTime() - started, 1)
        // A command buffer made and not committed is its caller's, not a stall.
        let uncommitted = try XCTUnwrap(metal.makeCommandBuffer())
        // Once the oldest has waited 2 s, no command buffer is made, without waiting.
        Thread.sleep(forTimeInterval: SharedMetal.stalledAfter + 0.1)
        XCTAssertTrue(metal.isStalled)
        let refused = CACurrentMediaTime()
        XCTAssertNil(metal.makeCommandBuffer())
        XCTAssertLessThan(CACurrentMediaTime() - refused, 0.1)
        // When the GPU completes them, command buffers come again.
        hold.signaledValue = 1
        let deadline = Date().addingTimeInterval(2)
        while metal.isStalled && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertFalse(metal.isStalled)
        XCTAssertTrue(metal.commitAndWait(uncommitted, timeout: 2))
        XCTAssertTrue(metal.commitAndWait(try XCTUnwrap(metal.makeCommandBuffer()), timeout: 2))
    }

    func testAWindowIsStalledOnlyWhileAPresentWaitsAndLostForGood() {
        var health = LiveGPUWindowHealth()
        XCTAssertEqual(health.state(at: 10), .running)
        health.presented(1, at: 10)
        health.presented(2, at: 10.5)
        XCTAssertEqual(health.state(at: 11.9), .running)
        XCTAssertEqual(health.state(at: 12), .stalled)
        health.released(1)
        XCTAssertEqual(health.state(at: 12), .running)  // the oldest now waited 1.5 s
        health.released(2)
        XCTAssertEqual(health.state(at: 100), .running)  // an idle window is not stalled
        for serial in UInt64(0)..<100 { health.presented(serial, at: 200 + Double(serial)) }
        XCTAssertEqual(health.pending.count, 64)
        health.deviceLost()
        XCTAssertEqual(health.state(at: 300), .lost)
        health.presented(500, at: 300)
        XCTAssertEqual(health.state(at: 300), .lost)
    }
}
