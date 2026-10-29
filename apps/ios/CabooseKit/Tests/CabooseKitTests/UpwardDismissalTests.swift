import CoreGraphics
import Testing
@testable import CabooseKit

struct UpwardDismissalTests {
    @Test func distanceAndDirectionMustBothQualify() {
        for point in [CGPoint(x: 0, y: -63.9), CGPoint(x: 0, y: 90),
                      CGPoint(x: 90, y: -80), CGPoint(x: -90, y: -80), CGPoint(x: 64, y: -96), .zero] {
            var gesture = UpwardDismissal()
            gesture.begin(CGPoint(x: 0, y: -12))
            let check10 = !gesture.finish(point)
            #expect(check10)
        }
        for x in [CGFloat(-20), 0, 20] {
            var gesture = UpwardDismissal()
            gesture.begin(CGPoint(x: 0, y: -12))
            let check15 = gesture.finish(CGPoint(x: x, y: -64))
            #expect(check15)
            let check16 = !gesture.finish(CGPoint(x: x, y: -100))
            #expect(check16)
        }
    }

    @Test func rejectedStartsAndCancellationCannotClose() {
        for start in [CGPoint(x: 20, y: -10), CGPoint(x: 0, y: 12), .zero] {
            var gesture = UpwardDismissal()
            gesture.begin(start)
            let check24 = !gesture.finish(CGPoint(x: 0, y: -100))
            #expect(check24)
        }
        var gesture = UpwardDismissal()
        gesture.begin(CGPoint(x: 0, y: -12))
        gesture.cancel()
        let check29 = !gesture.finish(CGPoint(x: 0, y: -100))
        #expect(check29)
        gesture.begin(CGPoint(x: 0, y: -12))
        let check31 = gesture.finish(CGPoint(x: 0, y: -100))
        #expect(check31)
    }

    @Test func feedbackTracksRetreatAndRejectsInvalidCoordinates() {
        #expect(UpwardDismissal.progress(CGPoint(x: 0, y: -32)) == 0.5)
        #expect(UpwardDismissal.progress(CGPoint(x: 0, y: -120)) == 1)
        #expect(UpwardDismissal.progress(CGPoint(x: 50, y: -32)) == 0)
        #expect(UpwardDismissal.progress(CGPoint(x: 0, y: -.infinity)) == 0)
        #expect(UpwardDismissal.progress(CGPoint(x: CGFloat.nan, y: -80)) == 0)
        var gesture = UpwardDismissal()
        gesture.begin(CGPoint(x: 0, y: -80))
        let check42 = !gesture.finish(CGPoint(x: 0, y: -20))
        #expect(check42)
    }
}
