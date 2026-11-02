import Foundation
import Testing
@testable import CabooseKit

struct ScrollPhysicsTests {
    @Test func fractionalInputIsConservedAndCoalesced() {
        var physics = ScrollPhysics()
        physics.begin(at: 0)
        for i in 1...10 { physics.append(CGPoint(x: 0.03, y: -0.07), at: Double(i) / 240) }
        let delta = physics.frame(elapsed: 1.0 / 60).delta
        #expect(abs(delta.x - 0.3) < 0.000001)
        #expect(abs(delta.y + 0.7) < 0.000001)
        #expect(physics.frame(elapsed: 1.0 / 60).delta == .zero)
    }

    @Test func samplesWithSameTimestampRetainDistance() {
        var physics = ScrollPhysics()
        physics.begin(at: 0)
        physics.append(CGPoint(x: 1, y: 2), at: 0.01)
        physics.append(CGPoint(x: 3, y: 4), at: 0.01)
        #expect(physics.frame(elapsed: 0.016).delta == CGPoint(x: 4, y: 6))
    }

    @Test func slowRecognitionDoesNotManufactureAFastFling() {
        var physics = ScrollPhysics()
        physics.begin(at: 0)
        physics.append(CGPoint(x: 0, y: 8), at: 0.4)
        physics.end(at: 0.41)
        // 8 points over 0.4 s: a lift at rest, with the last movement.
        #expect(physics.frame(elapsed: 0.016) == ScrollPhysics.Step(delta: CGPoint(x: 0, y: 8), lift: .zero))
    }

    @Test func theLiftCarriesTheMeasuredVelocityWithTheLastMovement() {
        var physics = ScrollPhysics()
        physics.begin(at: 0)
        physics.append(CGPoint(x: 10, y: -20), at: 0.01)
        physics.end(at: 0.01, velocity: CGPoint(x: 1000, y: -2000))
        #expect(physics.needsFrame)
        #expect(physics.frame(elapsed: 0.008) == ScrollPhysics.Step(delta: CGPoint(x: 10, y: -20), lift: CGPoint(x: 1000, y: -2000)))
        #expect(!physics.needsFrame)
        #expect(physics.frame(elapsed: 0.008) == ScrollPhysics.Step(delta: .zero))
    }

    @Test func liftAfterPauseAndHardwareScrollLiftAtRest() {
        for hardware in [false, true] {
            var physics = ScrollPhysics()
            physics.begin(at: 0)
            physics.append(CGPoint(x: 0, y: 20), at: 0.02)
            physics.end(at: hardware ? 0.03 : 0.3, coast: !hardware)
            #expect(physics.frame(elapsed: 0.016) == ScrollPhysics.Step(delta: CGPoint(x: 0, y: 20), lift: .zero))
        }
    }

    @Test func cancellationAndNewTouchDiscardOldMotion() {
        var physics = ScrollPhysics()
        physics.begin(at: 0)
        physics.append(CGPoint(x: 10, y: 20), at: 0.01)
        physics.end(at: 0.02)
        physics.begin(at: 1)
        #expect(physics.frame(elapsed: 0.016) == ScrollPhysics.Step(delta: .zero))
        physics.append(CGPoint(x: 2, y: 3), at: 1.01)
        physics.cancel()
        #expect(!physics.needsFrame)
        #expect(physics.frame(elapsed: 0.016) == ScrollPhysics.Step(delta: .zero))
    }

    @Test func aDisplayStallDropsMovementButStillLifts() {
        var physics = ScrollPhysics()
        physics.begin(at: 0)
        physics.append(CGPoint(x: 10, y: 20), at: 0.01)
        #expect(physics.frame(elapsed: 0.2) == ScrollPhysics.Step(delta: .zero))
        #expect(!physics.needsFrame)
        physics.append(CGPoint(x: 3, y: 7), at: 0.22)
        #expect(physics.frame(elapsed: 1.0 / 60).delta == CGPoint(x: 3, y: 7))
        physics.append(CGPoint(x: 0, y: 9), at: 0.23)
        physics.end(at: 0.23, velocity: CGPoint(x: 0, y: 900))
        #expect(physics.frame(elapsed: 1) == ScrollPhysics.Step(delta: .zero, lift: CGPoint(x: 0, y: 900)))
    }

    @Test func partialLiftDiscardsPendingMovementAndCannotLift() {
        var physics = ScrollPhysics()
        physics.begin(at: 0)
        physics.append(CGPoint(x: 0, y: 30), at: 0.02)
        physics.end(at: 0.03, remainingContacts: 1)
        #expect(!physics.needsFrame)
        #expect(physics.frame(elapsed: 0.016) == ScrollPhysics.Step(delta: .zero))
        physics.append(CGPoint(x: 0, y: 30), at: 0.04)
        physics.end(at: 0.05)
        #expect(!physics.needsFrame)

        physics.begin(at: 1)
        physics.append(CGPoint(x: 0, y: 30), at: 1.02)
        physics.end(at: 1.03, remainingContacts: 0)
        let last = physics.frame(elapsed: 0.016)
        #expect(last.delta.y == 30)
        #expect((last.lift?.y ?? 0) > 80)
    }

    @Test func reversedMovementReversesTheLiftAndRejectsInvalidSamples() {
        var physics = ScrollPhysics()
        physics.begin(at: 0)
        physics.append(CGPoint(x: 0, y: 30), at: 0.03)
        for i in 2...8 { physics.append(CGPoint(x: 0, y: -30), at: Double(i) * 0.03) }
        physics.append(CGPoint(x: CGFloat.nan, y: 0), at: 0.25)
        physics.append(CGPoint(x: 100, y: 100), at: 0.1)
        physics.end(at: 0.25)
        let lift = physics.frame(elapsed: 0.016).lift
        #expect((lift?.y ?? 0) < 0)
        #expect(lift?.x == 0)
    }

    @Test func theComputerCoastsAsLongAsItsDecelerationTakes() {
        // 2000 px/s slowing 0.2 % a millisecond to 20 px/s: ln(100) / 2.002 s.
        #expect(abs(KineticScroll.duration(lifting: CGPoint(x: 0, y: 2000)) - log(100) / (-log(0.998) * 1000)) < 1e-9)
        #expect(KineticScroll.duration(lifting: .zero) == 0)
        #expect(KineticScroll.duration(lifting: CGPoint(x: 1e9, y: 0)) == KineticScroll.duration(lifting: CGPoint(x: 30000, y: 0)))
    }
}
