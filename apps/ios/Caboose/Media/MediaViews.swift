import AVKit
import SwiftUI
import WebKit

/// "Playing on your computer — Play on iPhone", over whatever is on screen.
struct MediaBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        let media = model.media
        if let offer = media.offer {
            HStack(spacing: 12) {
                Image(systemName: offer.kind == "youtube" ? "play.rectangle.fill" : "film").font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Playing on your computer").font(.caption).foregroundStyle(.secondary)
                    Text(offer.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { Task { await media.playHere(offer) } } label: {
                    Label("Play on iPhone", systemImage: "iphone").labelStyle(.titleAndIcon).font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.glassProminent)
                Button { withAnimation(.snappy) { media.dismissOffer() } } label: {
                    Image(systemName: "xmark").font(.caption.weight(.bold)).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
            .padding(.horizontal, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let away = media.awaitingReturn {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer").font(.title3)
                Text(away.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Button("Resume on Computer") { Task { await media.resumeOnComputer() } }.buttonStyle(.glassProminent)
                Button { media.stayOnPhone() } label: { Image(systemName: "xmark").frame(width: 28, height: 28) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
            .padding(.horizontal, 12)
        }
    }
}

/// Plays a handed-off video full screen. Direct and HLS sources play in AVKit (with
/// AirPlay to an Apple TV); YouTube plays in its embedded player, which also offers AirPlay.
struct MediaPlayerScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let media: PlayingMedia
    @State private var position: Double

    init(media: PlayingMedia) {
        self.media = media
        _position = State(initialValue: media.position)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if media.kind == "youtube", let id = media.videoId {
                YouTubePlayer(videoID: id, start: media.position, position: $position) {
                    if let url = model.media.handToYouTubeApp(at: position) { openURL(url) }
                }
                .ignoresSafeArea(edges: .bottom)
                .padding(.top, 56)
            } else if let src = media.src.flatMap(URL.init(string:)) {
                NativePlayer(url: src, start: media.position, position: $position)
                    .ignoresSafeArea()
            }
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
        // Picture in Picture needs the audio background mode, which would keep the Linux
        // sound playing with the app in the background; it is left off.
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

/// YouTube's embedded player, reporting its time so the computer can continue from it.
/// A video whose owner disallows embedding goes to the YouTube app instead (`fallback`).
struct YouTubePlayer: UIViewRepresentable {
    let videoID: String
    let start: Double
    @Binding var position: Double
    let fallback: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(position: $position, fallback: fallback) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(context.coordinator, name: "caboose")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        // The embed needs a real origin; the page is ours, served as if from youtube.com.
        view.loadHTMLString(Self.page(videoID: videoID, start: Int(start)), baseURL: URL(string: "https://www.youtube.com"))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "caboose")
        view.evaluateJavaScript("player && player.pauseVideo && player.pauseVideo()")
    }

    static func page(videoID: String, start: Int) -> String {
        let id = videoID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#000}#p{position:absolute;inset:0;width:100%;height:100%}</style></head>
        <body><div id="p"></div><script>
        var player;
        function post(m){window.webkit.messageHandlers.caboose.postMessage(m)}
        function onYouTubeIframeAPIReady(){
          player=new YT.Player('p',{videoId:'\(id)',playerVars:{start:\(max(0, start)),autoplay:1,playsinline:1,rel:0},
            events:{onReady:function(e){e.target.playVideo()},onError:function(e){post({error:e.data})}}});
          setInterval(function(){if(player&&player.getCurrentTime){post({time:player.getCurrentTime()})}},500);
        }
        </script><script src="https://www.youtube.com/iframe_api"></script></body></html>
        """
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler {
        private var position: Binding<Double>
        private let fallback: () -> Void
        private var fellBack = false

        init(position: Binding<Double>, fallback: @escaping () -> Void) {
            self.position = position
            self.fallback = fallback
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if let time = body["time"] as? Double, time.isFinite, time > 0 { position.wrappedValue = time }
            // 101 and 150: the owner does not allow embedding. 2, 5, 100: bad id, HTML5 error, removed.
            if body["error"] != nil, !fellBack {
                fellBack = true
                fallback()
            }
        }
    }
}
