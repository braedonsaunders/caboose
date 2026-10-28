import CoreGraphics
import Testing
@testable import CabooseKit

struct DeviceViewportTests {
    @Test func hiddenDesktopCannotReclaimCardGeometryWhenDuoUnfolds() {
        var viewport = DeviceViewport()
        let closed = CGSize(width: 350, height: 780)
        let unfolded = CGSize(width: 720, height: 540)
        let changed1 = viewport.updateDesktop(closed)
        #expect(changed1)
        viewport.presentCard()
        let changed2 = viewport.updateCard(CGSize(width: 390, height: 730))
        #expect(changed2)
        let changed3 = !viewport.updateDesktop(unfolded)
        #expect(changed3)
        #expect(viewport.owner == .card)
        #expect(viewport.cardSize == CGSize(width: 390, height: 730))
        #expect(viewport.desktopSize == unfolded)
        let changed4 = viewport.updateCard(CGSize(width: 780, height: 490))
        #expect(changed4)
        viewport.dismissCard()
        #expect(viewport.owner == .desktop)
        #expect(viewport.desktopSize == unfolded)
        // A late geometry callback from the dismissing cover cannot resize the desktop.
        let changed5 = !viewport.updateCard(closed)
        #expect(changed5)
    }

    @Test func orientationSidebarAndFullscreenMeasurementsReplacePreviousDimensions() {
        var viewport = DeviceViewport()
        for size in [CGSize(width: 350, height: 780), CGSize(width: 720, height: 350),
                     CGSize(width: 680, height: 350), CGSize(width: 780, height: 390),
                     CGSize(width: 680, height: 350)] {
            let changed6 = viewport.updateDesktop(size)
            #expect(changed6)
            let changed7 = !viewport.updateDesktop(size)
            #expect(changed7)
            #expect(viewport.desktopSize == size)
            #expect(DeviceViewport.guestFrame(size: size, pixelsPerPoint: 2).size ==
                    CGSize(width: size.width * 2, height: size.height * 2))
        }
    }

    @Test func openingNewCardRequiresFreshContentMeasurement() {
        var viewport = DeviceViewport()
        viewport.presentCard()
        let changed8 = viewport.updateCard(CGSize(width: 350, height: 700))
        #expect(changed8)
        let changed9 = !viewport.updateCard(CGSize(width: 350, height: 700))
        #expect(changed9)
        viewport.dismissCard()
        viewport.presentCard()
        #expect(viewport.cardSize == .zero)
        let changed10 = viewport.updateCard(CGSize(width: 350, height: 700))
        #expect(changed10)
    }

    @Test func transientEmptyOrInvalidMeasurementsKeepLastUsableViewport() {
        var viewport = DeviceViewport()
        let size = CGSize(width: 350, height: 700)
        viewport.updateDesktop(size)
        viewport.presentCard()
        viewport.updateCard(size)
        for invalid in [CGSize.zero, CGSize(width: -1, height: 700),
                        CGSize(width: CGFloat.infinity, height: 700), CGSize(width: 350, height: CGFloat.nan)] {
            let changed11 = !viewport.updateDesktop(invalid)
            #expect(changed11)
            let changed12 = !viewport.updateCard(invalid)
            #expect(changed12)
        }
        #expect(viewport.desktopSize == size)
        #expect(viewport.cardSize == size)
    }

    @Test func guestConversionUsesContentSizeWithoutScreenInsetsOrSecondScaling() {
        #expect(DeviceViewport.guestFrame(size: CGSize(width: 350.25, height: 701.5), pixelsPerPoint: 2) ==
                CGRect(x: 0, y: 0, width: 701, height: 1403))
    }
}
