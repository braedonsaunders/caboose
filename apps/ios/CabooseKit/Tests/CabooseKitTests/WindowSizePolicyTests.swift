import CoreGraphics
import Testing
@testable import CabooseKit

struct WindowSizePolicyTests {
    private let card = CGRect(x: 0, y: 0, width: 1062, height: 1000)

    @Test func layoutViewportExpandsBothAxesForWideMinimum() {
        let viewport = CGRect(x: 20, y: 41, width: 500, height: 800)
        let target = WindowSizePolicy.fitting(viewport,
            minimum: CGSize(width: 862, height: 600), maximum: nil, fullscreen: false)!
        #expect(target.origin == viewport.origin)
        #expect(target.size == CGSize(width: 862, height: 1380))
        let shown = DesktopGeometry.surfaceFrame(natural: target.size, available: viewport.size, resizing: false)
        #expect(abs(shown.width - viewport.width) < 1)
        #expect(abs(shown.height - viewport.height) < 1)
        // Input follows the committed fitted surface, including the far corner.
        let mapped = DesktopGeometry.remotePoint(CGPoint(x: shown.maxX, y: shown.maxY),
            shown: shown, remote: target.size, captured: true)
        #expect(mapped == CGPoint(x: target.width, y: target.height))
    }

    @Test func fittedRequestsRespectFixedSizesAndIncompatibleLimits() {
        let viewport = CGRect(x: 0, y: 0, width: 500, height: 800)
        let fixed = CGSize(width: 862, height: 600)
        #expect(WindowSizePolicy.fitting(viewport, minimum: fixed, maximum: fixed,
            fullscreen: false)?.size == fixed)
        #expect(WindowSizePolicy.fitting(viewport, minimum: CGSize(width: 862, height: 0),
            maximum: CGSize(width: 0, height: 900), fullscreen: false)?.size == CGSize(width: 862, height: 800))
        #expect(WindowSizePolicy.fitting(viewport, minimum: nil,
            maximum: CGSize(width: 250, height: 0), fullscreen: false)?.size == CGSize(width: 250, height: 400))
        #expect(WindowSizePolicy.fitting(viewport, minimum: nil, maximum: nil, fullscreen: true) == nil)
        #expect(WindowSizePolicy.fitting(.zero, minimum: fixed, maximum: nil, fullscreen: false) == nil)
    }

    @Test func fittingIsIdempotentAtTheSharedSessionBoundary() {
        let minimum = CGSize(width: 862, height: 600)
        let target = WindowSizePolicy.fitting(CGRect(x: 0, y: 41, width: 500, height: 800),
            minimum: minimum, maximum: nil, fullscreen: false)!
        #expect(WindowSizePolicy.request(target, minimum: minimum, maximum: nil, fullscreen: false) == target)
        #expect(WindowSizePolicy.fitting(target, minimum: minimum, maximum: nil, fullscreen: false) == target)
    }

    @Test func ordinaryUnconstrainedWindowKeepsItsViewportRequest() {
        #expect(WindowSizePolicy.request(card, minimum: nil, maximum: nil, fullscreen: false) == card)
    }

    @Test func perAxisMinimumAndMaximumPreserveFixedSizeAndConflictingMinimum() {
        let constrained = WindowSizePolicy.request(card,
            minimum: CGSize(width: 1400, height: 0), maximum: CGSize(width: 0, height: 700), fullscreen: false)
        #expect(constrained?.size == CGSize(width: 1400, height: 700))
        let fixed = CGSize(width: 1200, height: 800)
        #expect(WindowSizePolicy.request(card, minimum: fixed, maximum: fixed, fullscreen: false)?.size == fixed)
        #expect(WindowSizePolicy.request(card, minimum: fixed,
            maximum: CGSize(width: 500, height: 600), fullscreen: false)?.size == fixed)
    }

    @Test func invalidHintsAreIgnoredAndPixelRoundingStaysWithinHints() {
        #expect(WindowSizePolicy.request(card, minimum: CGSize(width: -.infinity, height: .nan),
            maximum: CGSize(width: -10, height: 0), fullscreen: false) == card)
        let result = WindowSizePolicy.request(CGRect(x: 0.2, y: -0.2, width: 500.9, height: 600.1),
            minimum: CGSize(width: 400.1, height: 600.5), maximum: CGSize(width: 500.5, height: 900), fullscreen: false)
        #expect(result == CGRect(x: 0, y: 0, width: 500, height: 601))
        #expect(WindowSizePolicy.request(.zero, minimum: nil, maximum: nil, fullscreen: false) == nil)
    }

    @Test func fullscreenNeverGetsACardRequestAndExplicitExitRestoresFitting() {
        for proposed in [card, CGRect(x: 0, y: 0, width: 2204, height: 1702)] {
            #expect(WindowSizePolicy.request(proposed, minimum: nil, maximum: nil, fullscreen: true) == nil)
        }
        let minimum = CGSize(width: 1400, height: 900)
        #expect(WindowSizePolicy.request(card, minimum: minimum, maximum: nil, fullscreen: false)?.width == 1400)
    }

    @Test func lateMinimumChangesTargetWithoutPretendingAppAcceptedIt() {
        var fit = CardWindowFit()
        let reported = CGRect(x: 0, y: 0, width: 1600, height: 1200)
        let first = WindowSizePolicy.request(card, minimum: nil, maximum: nil, fullscreen: false)!
        _ = fit.shouldCorrect(frame: reported, target: first, now: 0)
        _ = fit.shouldCorrect(frame: reported, target: first, now: 0.1)
        let minimum = CGSize(width: 1400, height: 1100)
        let second = WindowSizePolicy.request(card, minimum: minimum, maximum: nil, fullscreen: false)!
        let correct = fit.shouldCorrect(frame: reported, target: second, now: 0.2)
        #expect(correct)
        #expect(second.size == minimum)
        #expect(reported.size == CGSize(width: 1600, height: 1200))
    }

    @Test func oversizedDialogKeepsMinimumAndFitsThroughExistingPresentation() {
        let requested = WindowSizePolicy.request(CGRect(x: 20, y: 40, width: 300, height: 300),
            minimum: CGSize(width: 1600, height: 1000), maximum: nil, fullscreen: false)!
        let viewport = CGSize(width: 400, height: 600)
        let shown = DesktopGeometry.surfaceFrame(natural: CGSize(width: requested.width / 2, height: requested.height / 2),
                                                available: viewport, resizing: false)
        #expect(requested.size == CGSize(width: 1600, height: 1000))
        #expect(shown == CGRect(x: 0, y: 0, width: 400, height: 250))
    }
}
