#if canImport(UIKit)
import UIKit
import Testing
@testable import CabooseKit

@MainActor struct VideoLayerHostingTests {
    @Test func inactivePresentationReleasesVideoWithoutRemovingNewOwnersLayer() throws {
        let surface = WindowSurface()
        surface.resize(width: 500, height: 678)
        let window = RemoteWindow(id: 7, frame: CGRect(x: 0, y: 0, width: 500, height: 678),
                                  overrideRedirect: false, surface: surface)
        guard case .videoCreate(let fields) = VideoMessageTests.server(.videoCreate, [
            "id": 1, "window": 7, "rect": [20, 200, 460, 240], "codec": "h264", "source": "motion"
        ]) else { Issue.record("video create"); return }
        let video = try #require(RemoteVideo(fields, send: { _ in }))
        window.videos = [video]
        let yard = RemoteWindowView(session: nil, window: window)
        yard.bounds = CGRect(x: 0, y: 0, width: 250, height: 339)
        yard.layoutVideos()
        #expect(video.container.superlayer === yard.layer)
        yard.showsVideo = false
        #expect(video.container.superlayer == nil)
        let card = RemoteWindowView(session: nil, window: window)
        card.bounds = CGRect(x: 0, y: 0, width: 233, height: 339)
        card.layoutVideos()
        yard.didMoveToWindow()
        #expect(video.container.superlayer === card.layer)
        #expect(abs(video.container.frame.width - 214.36) < 0.0001)
        card.attach(nil)
        #expect(video.container.superlayer == nil)
    }
}
#endif
