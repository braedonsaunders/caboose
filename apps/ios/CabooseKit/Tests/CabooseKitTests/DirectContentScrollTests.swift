import Foundation
import Testing
@testable import CabooseKit

/// A finger panning window content sends its own distance in window pixels: the computer
/// scrolls the content exactly that far (docs/input.md, "Scrolling").
struct DirectContentScrollTests {
    @Test func aPanSendsTheFingersDistanceInWindowPixels() throws {
        // Portrait, landscape, letterboxed and independently stretched surfaces.
        for shown in [CGRect(x: 0, y: 0, width: 390, height: 700),
                      CGRect(x: 0, y: 0, width: 700, height: 390),
                      CGRect(x: 40, y: 90, width: 300, height: 200)] {
            for remote in [CGSize(width: 585, height: 1050), CGSize(width: 1200, height: 600)] {
                let mapping = DesktopGeometry.SurfaceMapping(shown: shown, remote: remote)
                // Natural scrolling has already negated the finger movement.
                let drag = CGPoint(x: -37.25, y: 61.5)
                let wire = try #require(mapping.delta(drag))
                // Shown again on the phone, the content moved exactly under the finger.
                #expect(abs(wire.x * shown.width / remote.width - drag.x) < 1e-9)
                #expect(abs(wire.y * shown.height / remote.height - drag.y) < 1e-9)
            }
        }
    }

    @Test func aPanEndsWithTheFingersLiftVelocityAtEveryFrameRate() {
        for hz in [30.0, 60, 90, 120] {
            var physics = ScrollPhysics()
            physics.begin(at: 0)
            physics.append(CGPoint(x: -0.3, y: 0.7), at: 0.01)
            let tracked = physics.frame(elapsed: 1 / hz)
            #expect(abs(tracked.delta.x + 0.3) < 1e-9)
            #expect(abs(tracked.delta.y - 0.7) < 1e-9)
            #expect(tracked.lift == nil)
            physics.end(at: 0.02, velocity: CGPoint(x: -600, y: 1200))
            // The phone sends the lift and nothing after it: the computer coasts.
            #expect(physics.frame(elapsed: 1 / hz) == ScrollPhysics.Step(delta: .zero, lift: CGPoint(x: -600, y: 1200)))
            #expect(!physics.needsFrame)
        }
    }
}
