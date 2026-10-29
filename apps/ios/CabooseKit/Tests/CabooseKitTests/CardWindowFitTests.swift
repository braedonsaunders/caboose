import CoreGraphics
import Testing
@testable import CabooseKit

struct CardWindowFitTests {
    let portrait = CGRect(x: 0, y: 0, width: 523, height: 793)
    let viewport = CGRect(x: 0, y: 0, width: 951, height: 669)

    @Test func appResizeAfterOnboardingGetsTheViewportBack() {
        var fit = CardWindowFit()
        #expect(fit.shouldCorrect(frame: portrait, target: viewport, now: 0))
        #expect(!fit.shouldCorrect(frame: viewport, target: viewport, now: 0.1))
        #expect(fit.shouldCorrect(frame: portrait, target: viewport, now: 20))
    }

    @Test func minimumSizeRefusalDoesNotLoopThroughOptimisticFrames() {
        var fit = CardWindowFit()
        for i in 0..<10 {
            #expect(fit.shouldCorrect(frame: portrait, target: viewport, now: Double(i) / 100) == (i < 2))
            #expect(!fit.shouldCorrect(frame: viewport, target: viewport, now: Double(i) / 100))
        }
        #expect(fit.shouldCorrect(frame: viewport, target: portrait, now: 0.2))
    }
}
