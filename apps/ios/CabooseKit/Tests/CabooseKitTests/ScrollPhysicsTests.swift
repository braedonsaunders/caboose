import Foundation
import Testing
@testable import CabooseKit

struct ScrollPhysicsTests {
    @Test func fractionalInputIsConservedAndCoalesced() {
        var physics = ScrollPhysics()
        physics.begin(at: 0)
        for i in 1...10 { physics.append(CGPoint(x: 0.03, y: -0.07), at: Double(i) / 240) }
        let delta = physics.frame(elapsed: 1.0 / 60)
        #expect(abs(delta.x - 0.3) < 0.000001)
        #expect(abs(delta.y + 0.7) < 0.000001)
        #expect(physics.frame(elapsed: 1.0 / 60) == .zero)
    }

    @Test func samplesWithSameTimestampRetainDistance() {
        var physics = ScrollPhysics()
        physics.begin(at: 0)
        physics.append(CGPoint(x: 1, y: 2), at: 0.01)
        physics.append(CGPoint(x: 3, y: 4), at: 0.01)
        #expect(physics.frame(elapsed: 0.016) == CGPoint(x: 4, y: 6))
    }

    @Test func slowRecognitionDoesNotManufactureAFastFling() {
        var physics = ScrollPhysics()
        physics.begin(at: 0)
        physics.append(CGPoint(x: 0, y: 8), at: 0.4)
        physics.end(at: 0.41)
        #expect(!physics.isCoasting)
        #expect(physics.frame(elapsed: 0.016).y == 8)
    }

    private func distance(hz: Double) -> CGPoint {
        var physics = ScrollPhysics()
        physics.begin(at: 0)
        physics.append(CGPoint(x: 10, y: -20), at: 0.01)
        _ = physics.frame(elapsed: 0.01)
        physics.end(at: 0.01, velocity: CGPoint(x: 1000, y: -2000))
        var total = CGPoint.zero
        for _ in 0..<Int(hz * 5) {
            let delta = physics.frame(elapsed: 1 / hz)
            total.x += delta.x
            total.y += delta.y
        }
        #expect(!physics.isCoasting)
        return total
    }

    @Test func flingDistanceDoesNotDependOnRefreshRate() {
        let baseline = distance(hz: 60)
        for hz in [30.0, 90, 120] {
            let actual = distance(hz: hz)
            #expect(abs(actual.x - baseline.x) < 0.000001)
            #expect(abs(actual.y - baseline.y) < 0.000001)
        }
        #expect(baseline.x > 400 && baseline.x < 500)
    }

    @Test func liftAfterPauseAndHardwareScrollDoNotFling() {
        for hardware in [false, true] {
            var physics = ScrollPhysics()
            physics.begin(at: 0)
            physics.append(CGPoint(x: 0, y: 20), at: 0.02)
            physics.end(at: hardware ? 0.03 : 0.3, coast: !hardware)
            #expect(!physics.isCoasting)
            #expect(physics.frame(elapsed: 0.016).y == 20)
        }
    }

    @Test func cancellationAndNewTouchDiscardOldMotion() {
        var physics = ScrollPhysics()
        physics.begin(at: 0)
        physics.append(CGPoint(x: 10, y: 20), at: 0.01)
        physics.end(at: 0.02)
        #expect(physics.isCoasting)
        physics.begin(at: 1)
        #expect(physics.frame(elapsed: 0.016) == .zero)
        physics.append(CGPoint(x: 2, y: 3), at: 1.01)
        physics.cancel()
        #expect(!physics.needsFrame)
        #expect(physics.frame(elapsed: 0.016) == .zero)
    }

    @Test func stalledDisplayNeverReplaysBacklog() {
        var physics = ScrollPhysics()
        physics.begin(at: 0)
        physics.append(CGPoint(x: 10, y: 20), at: 0.01)
        physics.end(at: 0.02)
        #expect(physics.frame(elapsed: 1) == .zero)
        #expect(!physics.needsFrame)
    }

    @Test func aDisplayStallDoesNotDisableTheRestOfAFingerPan() {
        var physics = ScrollPhysics()
        physics.begin(at: 0)
        physics.append(CGPoint(x: 10, y: 20), at: 0.01)
        #expect(physics.frame(elapsed: 0.2) == .zero)
        #expect(!physics.needsFrame)
        physics.append(CGPoint(x: 3, y: 7), at: 0.22)
        #expect(physics.frame(elapsed: 1.0 / 60) == CGPoint(x: 3, y: 7))
        physics.end(at: 0.23, coast: false)
        #expect(!physics.isCoasting)
    }

    @Test func reversedMovementReversesFlingAndRejectsInvalidSamples() {
        var physics = ScrollPhysics()
        physics.begin(at: 0)
        physics.append(CGPoint(x: 0, y: 30), at: 0.03)
        for i in 2...8 { physics.append(CGPoint(x: 0, y: -30), at: Double(i) * 0.03) }
        physics.append(CGPoint(x: CGFloat.nan, y: 0), at: 0.25)
        physics.append(CGPoint(x: 100, y: 100), at: 0.1)
        physics.end(at: 0.25)
        #expect(physics.isCoasting)
        #expect(physics.velocity.y < 0)
        #expect(physics.velocity.x == 0)
    }
}
