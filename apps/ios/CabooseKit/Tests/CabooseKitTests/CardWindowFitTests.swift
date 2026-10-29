import CoreGraphics
import Testing
@testable import CabooseKit

struct CardWindowFitTests {
    let portrait = CGRect(x: 0, y: 0, width: 523, height: 793)
    let viewport = CGRect(x: 0, y: 0, width: 951, height: 669)

    @Test func appResizeAfterOnboardingGetsTheViewportBack() {
        var fit = CardWindowFit()
        let check10 = fit.shouldCorrect(frame: portrait, target: viewport, now: 0)
        #expect(check10)
        let check11 = !fit.shouldCorrect(frame: viewport, target: viewport, now: 0.1)
        #expect(check11)
        let check12 = fit.shouldCorrect(frame: portrait, target: viewport, now: 20)
        #expect(check12)
    }

    @Test func minimumSizeRefusalDoesNotLoopThroughOptimisticFrames() {
        var fit = CardWindowFit()
        for i in 0..<10 {
            let check18 = fit.shouldCorrect(frame: portrait, target: viewport, now: Double(i) / 100) == (i < 2)
            #expect(check18)
            let check19 = !fit.shouldCorrect(frame: viewport, target: viewport, now: Double(i) / 100)
            #expect(check19)
        }
        let check21 = fit.shouldCorrect(frame: viewport, target: portrait, now: 0.2)
        #expect(check21)
    }
}
