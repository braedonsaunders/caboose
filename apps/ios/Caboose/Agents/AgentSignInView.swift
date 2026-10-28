import SwiftUI
import WebKit

/// Signing in to one of the computer's agents from the phone (docs/architecture.md § Signing in).
/// The computer runs the agent's own sign-in, and nothing opens on its screen: the page the
/// sign-in opens shows here, and when that page sends the browser back to the computer's
/// localhost, the app hands the address to the agent waiting there. A sign-in that runs in a
/// terminal shows that terminal here, to answer its prompts.
struct AgentSignInView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let agentID: String
    let method: SignInMethod
    var onSignedIn: () -> Void = {}

    enum Phase: Equatable {
        case starting
        case running
        case succeeded
        case failed(String)
        /// The sign-in opened on the computer's screen instead.
        case onScreen
    }

    enum Pane: Hashable { case page, terminal }

    @State private var phase = Phase.starting
    /// This sheet's sign-in among the agent's: it follows, finishes and cancels only this one.
    @State private var attempt: String?
    @State private var status: AgentListing.SignInStatus?
    @State private var pane = Pane.page
    @State private var terminal: TerminalModel?
    /// Pages whose answer has gone to the agent; the sign-in is finishing on the computer.
    @State private var answered: Set<String> = []
    @State private var delivering = false
    @State private var retryGeneration = 0
    @State private var isPresented = true

    private var name: String { model.agents.listing(agentID)?.name ?? agentID }
    private var page: URL? {
        guard let url = status?.url, !answered.contains(url) else { return nil }
        return URL(string: url)
    }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { ShellBackground() }
                .navigationTitle("Sign In to \(name)")
                .navigationSubtitle(method.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        .task(id: retryGeneration) { await run() }
        .onAppear { isPresented = true }
        .onDisappear {
            isPresented = false
            terminal?.hide()
            // Leaving before it finished stops it, so nothing waits on the computer. Only this
            // sheet's attempt: a newer sign-in for the agent is left running.
            if phase == .running || phase == .starting, let attempt {
                Task { await model.agents.cancelSignIn(agentID, attempt: attempt) }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .starting:
            waiting("Starting \(name)'s sign-in on your computer…")
        case .running:
            running
        case .succeeded:
            ContentUnavailableView {
                Label("Signed In", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } description: {
                Text("\(name) on your computer is signed in.")
            } actions: {
                Button("Done") { dismiss() }.buttonStyle(.glassProminent)
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Sign-In Didn't Finish", systemImage: "exclamationmark.circle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { retryGeneration += 1 }.buttonStyle(.glassProminent)
                Button("Sign In on Computer's Screen") { Task { await signInOnScreen() } }.buttonStyle(.glass)
            }
        case .onScreen:
            ContentUnavailableView {
                Label("On Your Computer's Screen", systemImage: "display")
            } description: {
                Text("\(name)'s sign-in opened on your computer's screen. Finish it there, on the Desktop tab, then come back.")
            } actions: {
                Button("Done") { dismiss() }.buttonStyle(.glassProminent)
            }
        }
    }

    @ViewBuilder private var running: some View {
        VStack(spacing: 10) {
            if page != nil, terminal != nil {
                Picker("Show", selection: $pane) {
                    Text("Sign-In Page").tag(Pane.page)
                    Text("Terminal").tag(Pane.terminal)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
            }
            if let page, pane == .page || terminal == nil {
                SignInWebView(url: page) { back in deliver(back, for: page.absoluteString) }
                    .clipShape(.rect(cornerRadius: 18))
                    .overlay {
                        if delivering {
                            ProgressView("Finishing on your computer…")
                                .padding(20)
                                .glassEffect(.regular, in: .rect(cornerRadius: 16))
                        }
                    }
                    .padding(.horizontal, 12)
                Text("You're signing in on this iPhone, and \(name) on your computer gets the sign-in. Google can't sign in inside apps; if the page offers another way, use it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
            } else if let terminal {
                Text("Answer \(name)'s sign-in below. Tap it to type.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                TerminalSurface(view: terminal.view)
                    .padding(8)
                    .background(Color(uiColor: TerminalTheme.background), in: .rect(cornerRadius: 18))
                    .padding(.horizontal, 12)
                    .onAppear { terminal.show(host: model.host) }
                    .onDisappear { terminal.hide() }
            } else if let url = status?.url, answered.contains(url) {
                waiting("Finishing on your computer…")
            } else {
                waiting("Waiting for \(name)'s sign-in…")
            }
        }
        .padding(.vertical, 8)
    }

    private func waiting(_ text: String) -> some View {
        VStack(spacing: 14) {
            ProgressView()
            Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(phase == .succeeded || phase == .onScreen ? "Done" : "Cancel") { dismiss() }
        }
        if phase == .running || phase == .starting {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Sign In on Computer's Screen", systemImage: "display") { Task { await signInOnScreen() } }
                    if let url = status?.url, let link = URL(string: url) {
                        ShareLink(item: link) { Label("Share Sign-In Page", systemImage: "square.and.arrow.up") }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
    }

    // MARK: The sign-in

    /// Starts the sign-in on the phone, then follows it until it finishes.
    private func run() async {
        let agents = model.agents
        phase = .starting
        attempt = nil
        status = nil
        answered = []
        terminal?.hide()
        terminal = nil
        // What the computer reported before this sign-in, so a stale result is not taken for its own.
        let before = try? await agents.signInStatus(of: agentID)
        do {
            let started = try await agents.signIn(agentID, with: method)
            guard !Task.isCancelled, isPresented else {
                // Dismissal can precede the start response, when onDisappear has no id yet.
                if let started { Task { await agents.cancelSignIn(agentID, attempt: started) } }
                return
            }
            attempt = started
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        phase = .running
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, phase == .running else { return }
            guard let current = try? await agents.signInStatus(of: agentID) else { continue }
            if let theirs = current.attempt, theirs != attempt {
                // The previous attempt until this one records itself; after that, a newer one.
                if theirs == before?.attempt { continue }
                phase = .failed("Another sign-in to \(name) started, so this one stopped.")
                return
            }
            if current.attempt == nil, before != nil, current.startedAt == before?.startedAt { continue }
            follow(current)
            if phase != .running { return }
        }
    }

    private func follow(_ current: AgentListing.SignInStatus) {
        // A computer whose runner predates signing in on the phone opens it on its own screen.
        if current.isRunning, current.on == nil || current.attempt == nil { phase = .onScreen; return }
        if current.url != status?.url, current.url != nil { pane = .page }
        if let session = current.terminal, terminal == nil {
            terminal = TerminalModel(pinnedTo: session)
            if current.url == nil { pane = .terminal }
        }
        status = current
        switch current.status {
        case "succeeded":
            terminal?.hide()
            phase = .succeeded
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onSignedIn()
        case "failed":
            terminal?.hide()
            phase = .failed(current.message ?? "\(name) did not sign in.")
        default:
            break
        }
    }

    /// The page sent the browser back to the computer's localhost: that answer belongs to the
    /// agent waiting there, so it goes to the computer.
    private func deliver(_ back: URL, for page: String) {
        guard !delivering, !answered.contains(page), let attempt else { return }
        delivering = true
        Task {
            defer { delivering = false }
            do {
                try await model.agents.deliverSignInCallback(agentID, attempt: attempt, url: back)
                answered.insert(page)
                if terminal != nil { pane = .terminal }
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func signInOnScreen() async {
        do {
            try await model.agents.signIn(agentID, with: method, onPhone: false)
            terminal?.hide()
            phase = .onScreen
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// The page an agent's sign-in opened, in a private browser session. A navigation to the
/// computer's loopback (`http://localhost:<port>/…`) is where the page sends its answer; it is
/// never loaded here but handed to `onLoopback`.
struct SignInWebView: UIViewRepresentable {
    let url: URL
    let onLoopback: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onLoopback: onLoopback) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Nothing of the provider's session stays in the app.
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        context.coordinator.loaded = url
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onLoopback = onLoopback
        if context.coordinator.loaded != url {
            context.coordinator.loaded = url
            view.load(URLRequest(url: url))
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var onLoopback: (URL) -> Void
        var loaded: URL?
        private var handed: Set<URL> = []

        init(onLoopback: @escaping (URL) -> Void) { self.onLoopback = onLoopback }

        static func isLoopback(_ url: URL) -> Bool {
            url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host() ?? "") && url.port != nil
        }

        private func hand(_ url: URL) {
            guard handed.insert(url).inserted else { return }
            onLoopback(url)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url, Self.isLoopback(url) else { return .allow }
            hand(url)
            return .cancel
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            // A redirect the policy check did not see still names where it was going.
            if let url = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL, Self.isLoopback(url) { hand(url) }
        }

        /// Links and windows meant to open elsewhere open here.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                if Self.isLoopback(url) { hand(url) } else { webView.load(navigationAction.request) }
            }
            return nil
        }
    }
}
