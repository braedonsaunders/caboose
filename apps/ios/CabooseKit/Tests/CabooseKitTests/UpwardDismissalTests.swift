import CoreGraphics
import Testing
@testable import CabooseKit

struct UpwardDismissalTests {
    @Test func distanceAndDirectionMustBothQualify() {
        for point in [CGPoint(x: 0, y: -63.9), CGPoint(x: 0, y: 90),
                      CGPoint(x: 90, y: -80), CGPoint(x: -90, y: -80), CGPoint(x: 64, y: -96), .zero] {
            var gesture = UpwardDismissal()
            gesture.begin(CGPoint(x: 0, y: -12))
            #expect(!gesture.finish(point))
        }
        for x in [CGFloat(-20), 0, 20] {
            var gesture = UpwardDismissal()
            gesture.begin(CGPoint(x: 0, y: -12))
            #expect(gesture.finish(CGPoint(x: x, y: -64)))
            #expect(!gesture.finish(CGPoint(x: x, y: -100)))
        }
    }

    @Test func rejectedStartsAndCancellationCannotClose() {
        for start in [CGPoint(x: 20, y: -10), CGPoint(x: 0, y: 12), .zero] {
            var gesture = UpwardDismissal()
            gesture.begin(start)
            #expect(!gesture.finish(CGPoint(x: 0, y: -100)))
        }
        var gesture = UpwardDismissal()
        gesture.begin(CGPoint(x: 0, y: -12))
        gesture.cancel()
        #expect(!gesture.finish(CGPoint(x: 0, y: -100)))
        gesture.begin(CGPoint(x: 0, y: -12))
        #expect(gesture.finish(CGPoint(x: 0, y: -100)))
    }

    @Test func feedbackTracksRetreatAndRejectsInvalidCoordinates() {
        #expect(UpwardDismissal.progress(CGPoint(x: 0, y: -32)) == 0.5)
        #expect(UpwardDismissal.progress(CGPoint(x: 0, y: -120)) == 1)
        #expect(UpwardDismissal.progress(CGPoint(x: 50, y: -32)) == 0)
        #expect(UpwardDismissal.progress(CGPoint(x: 0, y: -.infinity)) == 0)
        #expect(UpwardDismissal.progress(CGPoint(x: CGFloat.nan, y: -80)) == 0)
        var gesture = UpwardDismissal()
        gesture.begin(CGPoint(x: 0, y: -80))
        #expect(!gesture.finish(CGPoint(x: 0, y: -20)))
    }
}
