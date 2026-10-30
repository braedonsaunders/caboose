import CoreGraphics
import Testing
@testable import CabooseKit

struct CardWindowFitTests {
    let portrait = CGRect(x: 0, y: 0, width: 523, height: 793)
    let viewport = CGRect(x: 0, y: 0, width: 951, height: 669)

    @Test func tileReconcilesAnAppResizeEvenWhenLastSentTargetIsUnchanged() {
        var fit = CardWindowFit()
        let target = WindowSizePolicy.fitting(CGRect(x: 0, y: 41, width: 500, height: 800),
            minimum: CGSize(width: 862, height: 600), maximum: nil, fullscreen: false)!
        let accepted = fit.shouldCorrect(frame: target, target: target, now: 0)
        let appResize = CGRect(x: 0, y: 41, width: 862, height: 710)
        let correction = fit.shouldCorrect(frame: appResize, target: target, now: 1)
        let second = fit.shouldCorrect(frame: appResize, target: target, now: 1.1)
        let exhausted = fit.shouldCorrect(frame: appResize, target: target, now: 1.2)
        #expect(!accepted)
        #expect(correction && second && !exhausted)
    }

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
