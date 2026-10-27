import SwiftUI
import UIKit

/// The scene iOS creates for an AirPlay or USB-C display. It shows the desktop; the phone
/// switches to the trackpad while it is connected.
final class ExternalSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        MainActor.assumeIsolated {
            let model = AppModel.shared
            let window = UIWindow(windowScene: windowScene)
            let root = DesktopView(desktop: model.desktop).environment(model).preferredColorScheme(.dark)
            window.rootViewController = UIHostingController(rootView: root)
            window.isHidden = false
            self.window = window
            let screen = windowScene.screen
            model.externalDisplayConnected(size: screen.bounds.size, scale: screen.scale)
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        MainActor.assumeIsolated {
            AppModel.shared.externalDisplayDisconnected()
            window = nil
        }
    }
}
