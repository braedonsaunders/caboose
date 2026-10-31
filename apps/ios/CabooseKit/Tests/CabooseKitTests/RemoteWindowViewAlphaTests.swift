#if canImport(UIKit)
import UIKit
import Testing
@testable import CabooseKit

@MainActor struct RemoteWindowViewAlphaTests {
    @Test func aWindowWithAlphaShowsThroughAndAnOpaqueOneSitsOnBlack() {
        let surface = WindowSurface()
        surface.resize(width: 40, height: 30)
        let popup = RemoteWindow(id: 9, frame: CGRect(x: 10, y: 10, width: 40, height: 30), overrideRedirect: true, surface: surface)
        popup.hasAlpha = true
        let view = RemoteWindowView(session: nil, window: popup)
        let layer = view.layer as! CAMetalLayer
        #expect(view.showsThrough && view.backgroundColor == .clear && !layer.isOpaque)
        // window.update can clear the alpha; the next presentation follows it.
        popup.hasAlpha = false
        view.attach(popup)
        #expect(!view.showsThrough && view.backgroundColor == .black && layer.isOpaque)
    }
}
#endif
