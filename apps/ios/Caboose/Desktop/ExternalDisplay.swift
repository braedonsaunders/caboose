import SwiftUI
import UIKit

/// Routes an AirPlay or USB-C display to the desktop. SwiftUI's own app delegate answers
/// scene configuration for a SwiftUI app, so the plist entry alone can leave the TV
/// mirroring the phone; claiming the external role here makes it the desktop.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if session.role == .windowExternalDisplayNonInteractive {
            let configuration = UISceneConfiguration(name: "External Display", sessionRole: session.role)
            configuration.delegateClass = ExternalSceneDelegate.self
            return configuration
        }
        return UISceneConfiguration(name: nil, sessionRole: session.role)
    }
}

/// The scene iOS creates for an AirPlay or USB-C display. It shows the desktop; the phone
/// switches to the trackpad while it is connected.
final class ExternalSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        MainActor.assumeIsolated {
            let model = AppModel.shared
            // Connect first: it creates the desktop model the trackpad and this screen share.
            let screen = windowScene.screen
            model.externalDisplayConnected(size: screen.bounds.size, scale: screen.scale)
            let window = UIWindow(windowScene: windowScene)
            let root = DesktopView(desktop: model.desktop).environment(model).preferredColorScheme(.dark)
            window.rootViewController = UIHostingController(rootView: root)
            window.isHidden = false
            self.window = window
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        MainActor.assumeIsolated {
            AppModel.shared.externalDisplayDisconnected()
            window = nil
        }
    }
}
