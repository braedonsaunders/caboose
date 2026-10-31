import SafariServices
import SwiftUI

/// The page in Safari's in-app browser, with its AirPlay and full-screen controls.
struct WebPage: UIViewControllerRepresentable {
    let url: URL
    /// The controls' tint: white over a video, or the system's over an ordinary page.
    var tint: UIColor? = .white
    let done: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .done
        controller.preferredControlTintColor = tint
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let done: () -> Void
        init(done: @escaping () -> Void) { self.done = done }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { done() }
    }
}
