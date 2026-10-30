import CabooseKit
import SwiftUI
import WebKit
import OSLog

struct ChatHTMLArtifact: View {
    @Environment(AppModel.self) private var model
    let html: String
    @State private var height: CGFloat = 240
    @State private var expanded = false
    @State private var loading = true
    @State private var error: String?
    @State private var retry = UUID()
    @State private var proposed: String?
    @State private var export: ChatArtifactFile?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Label("Interactive", systemImage: "slider.horizontal.3").font(.caption.weight(.semibold))
                Spacer()
                if loading { ProgressView().controlSize(.small).accessibilityLabel("Loading interactive content") }
                if let export { ShareLink(item: export.url) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Export HTML") }
                Button { expanded = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }.accessibilityLabel("Open interactive content full screen")
            }.padding(12)
            Divider()
            IsolatedArtifactWebView(html: html, height: $height, loading: $loading, error: $error, expanded: $expanded) { message in
                expanded = false
                if proposed == nil { proposed = message }
            }
            .id(retry)
            .frame(height: error == nil ? min(500, max(180, height)) : 0)
            .accessibilityLabel("Interactive chart or tool")
            if let error {
                VStack(alignment: .leading, spacing: 12) {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout)
                    Button("Try Again") { self.error = nil; loading = true; retry = UUID() }
                        .buttonStyle(.bordered)
                }.padding(16)
            }
        }
        .background(.thinMaterial, in: .surface(cornerRadius: 16))
        .clipShape(.surface(cornerRadius: 16))
        .overlay(ConcentricRectangle(cornerRadius: 16).stroke(.primary.opacity(0.1)))
        .task(id: html) {
            do { export = try ChatArtifactFile(data: Data(html.utf8), name: "Interactive.html") }
            catch { self.error = "HTML export could not be prepared: \(error.localizedDescription)" }
        }
        .sheet(isPresented: Binding(get: { proposed != nil }, set: { if !$0 { proposed = nil } })) {
            NavigationStack {
                ScrollView { Text(proposed ?? "").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
                    .navigationTitle("Proposed message").navigationBarTitleDisplayMode(.inline)
                    .safeAreaInset(edge: .bottom) {
                        Button("Use in Composer") {
                            model.agents.draft = proposed
                            proposed = nil
                        }.buttonStyle(.borderedProminent).padding()
                    }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { proposed = nil } } }
            }
        }
    }
}

private struct IsolatedArtifactWebView: UIViewRepresentable {
    let html: String
    @Binding var height: CGFloat
    @Binding var loading: Bool
    @Binding var error: String?
    @Binding var expanded: Bool
    let compose: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.allowsAirPlayForMediaPlayback = false
        config.allowsPictureInPictureMediaPlayback = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.userContentController.addUserScript(WKUserScript(
            source: "for(const name of ['RTCPeerConnection','webkitRTCPeerConnection']){Object.defineProperty(window,name,{value:undefined,writable:false,configurable:false})}",
            injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.add(context.coordinator, name: "artifact")
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.navigationDelegate = context.coordinator
        let gesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        gesture.cancelsTouchesInView = false
        gesture.delegate = context.coordinator
        view.addGestureRecognizer(gesture)
        context.coordinator.load(html, in: view)
        let container = UIView()
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(view)
        context.coordinator.webView = view
        context.coordinator.inlineContainer = container
        return container
    }
    func updateUIView(_ container: UIView, context: Context) {
        context.coordinator.parent = self
        guard let view = context.coordinator.webView else { return }
        // A completed fence keeps the same web view and JS state as later tokens arrive.
        if context.coordinator.html != html { context.coordinator.load(html, in: view) }
        context.coordinator.updatePresentation()
    }
    static func dismantleUIView(_ container: UIView, coordinator: Coordinator) {
        coordinator.fullscreen?.dismiss(animated: false)
        guard let view = coordinator.webView else { return }
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "artifact")
        view.navigationDelegate = nil
        coordinator.webView = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, UIGestureRecognizerDelegate, UIAdaptivePresentationControllerDelegate {
        var parent: IsolatedArtifactWebView
        var html = ""
        var webView: WKWebView?
        weak var inlineContainer: UIView?
        weak var fullscreen: UINavigationController?
        private var fullscreenConstraints: [NSLayoutConstraint] = []
        private var changingPresentation = false
        private var lastInteraction = Date.distantPast
        private var generation = UUID()
        init(_ parent: IsolatedArtifactWebView) { self.parent = parent }
        func updatePresentation() {
            guard !changingPresentation else { return }
            if parent.expanded, fullscreen == nil {
                guard let webView, let inlineContainer, var presenter = inlineContainer.window?.rootViewController else { return }
                while let next = presenter.presentedViewController { presenter = next }
                let content = UIViewController()
                content.title = "Interactive"
                content.view.backgroundColor = .systemBackground
                content.navigationItem.rightBarButtonItem = UIBarButtonItem(
                    title: "Done", style: .done, target: self, action: #selector(closeFullscreen))
                webView.removeFromSuperview()
                webView.translatesAutoresizingMaskIntoConstraints = false
                content.view.addSubview(webView)
                let area = content.view.safeAreaLayoutGuide
                fullscreenConstraints = [webView.leadingAnchor.constraint(equalTo: area.leadingAnchor),
                    webView.trailingAnchor.constraint(equalTo: area.trailingAnchor),
                    webView.topAnchor.constraint(equalTo: area.topAnchor),
                    webView.bottomAnchor.constraint(equalTo: area.bottomAnchor)]
                NSLayoutConstraint.activate(fullscreenConstraints)
                let navigation = UINavigationController(rootViewController: content)
                navigation.modalPresentationStyle = .fullScreen
                fullscreen = navigation
                changingPresentation = true
                presenter.present(navigation, animated: true) { [weak self] in
                    self?.changingPresentation = false
                    self?.updatePresentation()
                }
                navigation.presentationController?.delegate = self
            } else if !parent.expanded, let fullscreen {
                changingPresentation = true
                fullscreen.dismiss(animated: true) { [weak self] in self?.restoreInline() }
            }
        }
        @objc private func closeFullscreen() { parent.expanded = false; updatePresentation() }
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            parent.expanded = false
            restoreInline()
        }
        private func restoreInline() {
            NSLayoutConstraint.deactivate(fullscreenConstraints)
            fullscreenConstraints = []
            fullscreen = nil
            changingPresentation = false
            guard let webView, let inlineContainer else { return }
            webView.removeFromSuperview()
            webView.translatesAutoresizingMaskIntoConstraints = true
            webView.frame = inlineContainer.bounds
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            inlineContainer.addSubview(webView)
        }
        @objc func tapped() {}
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            lastInteraction = Date()
            return true
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
        func load(_ html: String, in view: WKWebView) {
            self.html = html
            let current = UUID(); generation = current
            parent.error = nil
            parent.loading = true
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "caboose-isolated-artifact-v2", encodedContentRuleList: ChatArtifactPolicy.contentRules) { [weak self, weak view] list, error in
                guard let self, let view, self.generation == current else { return }
                guard let list else {
                    self.parent.loading = false
                    Logger(subsystem: "com.braedonsaunders.caboose", category: "ChatPreview").error("Content rule compilation failed: \(String(describing: error), privacy: .public)")
                    self.parent.error = "This interactive preview couldn’t start. Try loading it again."
                    return
                }
                view.configuration.userContentController.removeAllContentRuleLists()
                view.configuration.userContentController.add(list)
                view.loadHTMLString(ChatArtifactPolicy.htmlDocument(html), baseURL: nil)
            }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
            switch body["kind"] as? String {
            case "size":
                if let height = body["height"] as? Double, height.isFinite { parent.height = CGFloat(min(20_000, max(100, height))) }
            case "compose":
                guard Date().timeIntervalSince(lastInteraction) < 2,
                      let value = body["message"] as? String, let message = ChatArtifactPolicy.proposedMessage(value) else { return }
                lastInteraction = .distantPast
                if let fullscreen {
                    parent.expanded = false
                    changingPresentation = true
                    fullscreen.dismiss(animated: true) { [weak self] in
                        self?.restoreInline()
                        self?.parent.compose(message)
                    }
                } else { parent.compose(message) }
            default: break
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            let url = navigationAction.request.url?.absoluteString
            // loadHTMLString and its opaque sandbox frame are the only documents permitted.
            return navigationAction.navigationType == .other && navigationAction.targetFrame != nil &&
                (url == "about:blank" || url == "about:srcdoc") ? .allow : .cancel
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { parent.loading = false }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            parent.loading = false
            parent.error = "This interactive preview stopped. Try loading it again."
        }
        private func failed(_ error: Error) {
            parent.loading = false
            parent.error = "The interactive preview could not load: \(error.localizedDescription)"
        }
    }
}
