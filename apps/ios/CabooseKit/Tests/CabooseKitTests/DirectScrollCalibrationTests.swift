import Foundation
import Testing
@testable import CabooseKit

struct DirectScrollCalibrationTests {
    @Test func referenceDisplacementSurvivesRotationFitAndDisplayScale() throws {
        // Exercise portrait, landscape, letterboxed and independently stretched surfaces.
        for shown in [CGRect(x: 0, y: 0, width: 390, height: 700),
                      CGRect(x: 0, y: 0, width: 700, height: 390),
                      CGRect(x: 40, y: 90, width: 300, height: 200)] {
            for remote in [CGSize(width: 585, height: 1050), CGSize(width: 1200, height: 600)] {
                for scale in [CGFloat(1), 1.5, 3] {
                    let mapping = DesktopGeometry.SurfaceMapping(shown: shown, remote: remote)
                    // Natural scrolling has already negated the finger movement.
                    let drag = CGPoint(x: -37.25, y: 61.5)
                    let mapped = try #require(mapping.delta(drag))
                    let wire = DirectScrollCalibration.preciseDelta(mapped, directContent: true)
                    let axis = CGPoint(x: wire.x / scale, y: wire.y / scale)
                    // Reference client gain; NOT an assertion about every Linux app.
                    let content = CGPoint(x: axis.x * 12, y: axis.y * 12)
                    let presented = CGPoint(x: content.x * scale * shown.width / remote.width,
                                            y: content.y * scale * shown.height / remote.height)
                    #expect(abs(presented.x - drag.x) < 1e-9)
                    #expect(abs(presented.y - drag.y) < 1e-9)
                    #expect(DirectScrollCalibration.preciseDelta(mapped, directContent: false) == mapped)
                }
            }
        }
    }

    @Test func referenceFixtureMapsTwentyFourPixelsToTwo() {
        let wire = DirectScrollCalibration.preciseDelta(CGPoint(x: -24, y: 24), directContent: true)
        #expect(wire == CGPoint(x: -2, y: 2))
        // Three samples at output scale 1.5: 48 reference content units, formerly 576.
        #expect(wire.y * 3 / 1.5 * 12 == 48)
    }

    @Test func calibrationPreservesFractionalTrackingAndInertiaAcrossFrameRates() {
        var totals: [CGPoint] = []
        for hz in [30.0, 60, 90, 120] {
            var physics = ScrollPhysics()
            physics.begin(at: 0)
            physics.append(CGPoint(x: -0.3, y: 0.7), at: 0.01)
            let tracked = DirectScrollCalibration.preciseDelta(physics.frame(elapsed: 1 / hz), directContent: true)
            #expect(abs(tracked.x + 0.025) < 1e-9)
            #expect(abs(tracked.y - 0.7 / 12) < 1e-9)
            physics.end(at: 0.02, velocity: CGPoint(x: -600, y: 1200))
            var total = tracked
            for _ in 0..<Int(hz * 5) {
                let delta = DirectScrollCalibration.preciseDelta(physics.frame(elapsed: 1 / hz), directContent: true)
                total.x += delta.x
                total.y += delta.y
            }
            #expect(!physics.isCoasting)
            totals.append(total)
        }
        for total in totals.dropFirst() {
            #expect(abs(total.x - totals[0].x) < 1e-8)
            #expect(abs(total.y - totals[0].y) < 1e-8)
        }
    }
}
