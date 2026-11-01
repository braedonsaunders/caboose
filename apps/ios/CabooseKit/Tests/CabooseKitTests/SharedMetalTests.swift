import Foundation
import Metal
import QuartzCore
import XCTest
@testable import CabooseKit

/// The phone's own Metal never waits for a GPU that has stopped completing its work.
final class SharedMetalTests: XCTestCase {
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
