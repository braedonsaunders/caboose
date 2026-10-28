import AVFoundation
import SwiftUI
import UIKit

/// Routes an AirPlay or USB-C display to the desktop on iOS 26. SwiftUI's own app delegate
/// answers scene configuration for a SwiftUI app, so the plist entry alone can leave the TV
/// mirroring the phone; claiming the external role here makes it the desktop.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // The computer's sound plays like a media app's (and so follows AirPlay to the TV), mixed
        // with whatever else is playing rather than stopping it.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        PushCoordinator.shared.configure()
        LiveActivityCoordinator.shared.configure()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushCoordinator.shared.received(token: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushCoordinator.shared.error = error.localizedDescription
    }

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

extension View {
    /// The desktop as the content of a connected display. Since iOS 27 an app is offered the
    /// external-display scene only once it registers a scene accessory; the Info.plist entry
    /// and `ExternalSceneDelegate` above serve iOS 26.
    @ViewBuilder
    func externalDesktopAccessory(_ model: AppModel) -> some View {
        if #available(iOS 27, *) {
            sceneAccessory {
                ExternalNonInteractiveAccessory {
                    ExternalDesktopContent().environment(model).preferredColorScheme(.dark)
                }
            }
        } else {
            self
        }
    }
}

/// Reports the connected display's size to the model while it is showing the desktop.
private struct ExternalDesktopContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var scale

    var body: some View {
        GeometryReader { proxy in
            Group {
                if model.externalDisplayActive {
                    DesktopView(desktop: model.desktop)
                } else {
                    Color.black
                }
            }
            .onAppear { model.externalDisplayConnected(size: proxy.size, scale: scale) }
            .onDisappear { model.externalDisplayDisconnected() }
        }
        .ignoresSafeArea()
    }
}
