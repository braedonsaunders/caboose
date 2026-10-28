import CabooseKit
import GameController
import SwiftUI

/// A real shell on the computer, drawn natively: `TerminalModel` keeps the session, and
/// `CabooseTerminalView` (SwiftTerm) renders it. The screen is the tab's content; the shell
/// around it supplies the navigation stack, the wallpaper and its own toolbar items, and this
/// adds the session menu. Like Desktop, the grid fills the space beside a vertical sidebar.
struct TerminalScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.toolbarVerticalEdgeIfAvailable) private var barEdge
    @State private var terminal = TerminalModel.shared
    @State private var onScreen = false

    /// The terminal needs the computer, not its display: it wakes the computer itself, and
    /// runs while the display is connecting, has failed or shows on another device. Only a
    /// computer the owner parked or is restarting shows its state instead.
    private var computerAvailable: Bool {
        switch model.phase {
        case .parked, .restarting, .needsSetup: false
        case .waking, .connecting, .ready, .failed, .displayElsewhere: true
        }
    }

    var body: some View {
        Group {
            if computerAvailable {
                TerminalSurface(view: terminal.view)
                    .ignoresSafeArea(.container, edges: terminalEdges)
                    .overlay(alignment: .bottom) { TerminalStatusBar(terminal: terminal) }
                    .onAppear { onScreen = true; attach() }
                    .onDisappear { onScreen = false; terminal.hide() }
            } else {
                ComputerStateView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(terminal.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .toolbar {
            if computerAvailable { ToolbarItem(placement: .topBarTrailing) { sessionMenu } }
        }
        .keepsTabBarInVerticalBar()
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: if onScreen, computerAvailable { attach() }
            case .background: terminal.hide()
            default: break
            }
        }
        .onChange(of: model.host?.baseURL) { _, _ in if onScreen, computerAvailable { attach() } }
    }

    private var terminalEdges: Edge.Set {
        switch barEdge {
        case .trailing: [.top, .bottom, .leading]
        case .leading: [.top, .bottom, .trailing]
        case nil: []
        }
    }

    private func attach() {
        terminal.show(host: model.host)
        // With a hardware keyboard, typing goes straight to the shell; on the phone's own
        // keyboard a tap brings it up, so the screen is not half covered on arrival.
        if GCKeyboard.coalesced != nil { DispatchQueue.main.async { _ = terminal.view.becomeFirstResponder() } }
    }

    private var sessionMenu: some View {
        Menu {
            Button("New Session", systemImage: "plus") { terminal.newSession() }
            if !terminal.sessions.isEmpty {
                Section("Sessions") {
                    ForEach(terminal.sessions) { session in
                        Button { terminal.open(session) } label: {
                            if session.id == terminal.sessionID {
                                Label(session.displayName, systemImage: "checkmark")
                            } else {
                                Text(session.displayName)
                            }
                            if session.attached, session.id != terminal.sessionID { Text("Open on another device") }
                        }
                    }
                }
            }
            Section {
                Button("Larger Text", systemImage: "textformat.size.larger") { terminal.adjustTextSize(by: 1) }
                Button("Smaller Text", systemImage: "textformat.size.smaller") { terminal.adjustTextSize(by: -1) }
            }
            if terminal.sessionID != nil {
                Button("Close Session", systemImage: "xmark", role: .destructive) { terminal.closeSession() }
            }
        } label: {
            Label("Sessions", systemImage: "terminal")
        }
        .onAppear { Task { await terminal.refreshSessions() } }
    }
}

/// Hosts the long-lived terminal view, which moves into each new container as the tab is rebuilt.
private struct TerminalSurface: UIViewRepresentable {
    let view: CabooseTerminalView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {}

    static func dismantleUIView(_ container: UIView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }
}

/// What the session is doing when it is not simply live, with the one action that helps.
private struct TerminalStatusBar: View {
    let terminal: TerminalModel

    var body: some View {
        Group {
            switch terminal.status {
            case .live:
                EmptyView()
            case .starting:
                bar { ProgressView().controlSize(.small); Text("Starting a shell…") }
            case .reconnecting:
                bar { ProgressView().controlSize(.small); Text("Reconnecting…") }
            case .exited(let how):
                bar(action: ("New Session", terminal.newSession)) {
                    Image(systemName: "checkmark.circle")
                    Text("The shell \(how).")
                }
            case .elsewhere:
                bar(action: ("Show Here", terminal.reconnect)) {
                    Image(systemName: "rectangle.on.rectangle")
                    Text("Open on another device.")
                }
            case .idle:
                bar(action: ("Reconnect", terminal.reconnect)) {
                    Image(systemName: "moon.zzz")
                    Text("Disconnected while idle.")
                }
            case .failed(let message):
                bar(action: ("Try Again", terminal.reconnect)) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(message).lineLimit(3)
                }
            }
        }
        .animation(.snappy, value: terminal.status)
    }

    private func bar<Content: View>(action: (String, () -> Void)? = nil, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            content()
            if let action {
                Spacer(minLength: 4)
                Button(action.0, action: action.1)
                    .buttonStyle(.glassProminent)
                    .tint(Brand.amber)
                    .foregroundStyle(.black)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
