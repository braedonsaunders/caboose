import AVKit
import SafariServices
import SwiftUI

/// Plays a handed-off video full screen: its own source in AVKit (with AirPlay to an Apple
/// TV), or, for a stream the page builds itself, the page in the phone's browser.
struct MediaPlayerScreen: View {
    @Environment(AppModel.self) private var model
    let media: PlayingMedia
    @State private var position: Double

    init(media: PlayingMedia) {
        self.media = media
        _position = State(initialValue: media.position)
    }

    var body: some View {
        if media.kind == "page", let page = media.pageURL {
            // The page's own player runs here; its position does not carry back.
            WebPage(url: page) { Task { await model.media.finished(at: nil) } }
                .ignoresSafeArea()
        } else if let src = media.sourceURL {
            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()
                NativePlayer(url: src, start: media.position, position: $position)
                    .ignoresSafeArea()
                HStack(spacing: 10) {
                    Button { Task { await model.media.finished(at: position) } } label: {
                        Label("Back to Computer", systemImage: "desktopcomputer").font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).frame(height: 40)
                    }
                    .glassEffect(.regular.interactive(), in: .capsule)
                    Spacer()
                    RoutePicker().frame(width: 40, height: 40).glassEffect(.regular.interactive(), in: .circle)
                }
                .padding(.horizontal, 12).padding(.top, 8)
                .foregroundStyle(.white)
            }
            .statusBarHidden()
        }
    }
}

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

/// The AirPlay button: pick an Apple TV and the video plays there.
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.tintColor = .white
        view.activeTintColor = .systemBlue
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

struct NativePlayer: UIViewControllerRepresentable {
    let url: URL
    let start: Double
    @Binding var position: Double

    func makeCoordinator() -> Coordinator { Coordinator(position: $position) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let player = AVPlayer(url: url)
        player.allowsExternalPlayback = true
        if start > 1 { player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        context.coordinator.observe(player)
        player.play()
        let controller = AVPlayerViewController()
        controller.player = player
        // Picture in Picture is left off: the video returns to the computer's window, which
        // only plays while Caboose is open.
        controller.allowsPictureInPicturePlayback = false
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        controller.player?.pause()
        coordinator.stop()
    }

    @MainActor final class Coordinator {
        private var position: Binding<Double>
        private var token: Any?
        private weak var player: AVPlayer?

        init(position: Binding<Double>) { self.position = position }

        func observe(_ player: AVPlayer) {
            self.player = player
            token = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
                MainActor.assumeIsolated { if time.seconds.isFinite { self?.position.wrappedValue = time.seconds } }
            }
        }

        func stop() {
            if let token { player?.removeTimeObserver(token) }
            token = nil
        }
    }
}
