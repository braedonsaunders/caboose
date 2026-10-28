import CabooseKit
import CoreSpotlight
import SwiftUI

@main
struct CabooseApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    if url.isFileURL { model.documents.receive(url) }
                    else if let pairing = PairingLink(link: url) { model.pair(with: pairing) }
                    else if let credentials = Credentials(link: url) { model.connect(with: credentials) }
                    else if let link = ShellLink(url) { model.follow(link) }
                }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
                    Task {
                        do { try await ComputerSearch.open(id) }
                        catch { model.launchFailure = error.localizedDescription }
                    }
                }
                .externalDesktopAccessory(model)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.sceneBecameActive()
            case .background: model.sceneEnteredBackground()
            default: break
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Backdrop()
            if model.phase == .needsSetup {
                SetupView()
            } else {
                MainTabs()
            }
        }
        .animation(.smooth(duration: 0.35), value: model.phase == .needsSetup)
        .overlay(alignment: .top) {
            // Home and Agents answer approvals in place; the other tabs get the banner.
            if model.phase == .ready, !model.externalDisplayActive, [.desktop, .apps].contains(model.selectedTab) { ApprovalBanner() }
        }
        .animation(.snappy, value: model.agents.awaitingApproval.first?.pendingApproval?.id)
        .sheet(item: Binding(get: { model.phase == .ready ? model.documents.pending : nil }, set: { _ in })) { item in
            OpenDocumentPicker(item: item).environment(model).interactiveDismissDisabled()
        }
        .alert("Document conflict", isPresented: Binding(get: { !model.documents.conflicts.isEmpty && model.documents.pending == nil }, set: { _ in })) {
            if let conflict = model.documents.conflicts.first {
                Button("Keep Computer Copy") { Task { await model.documents.resolve(conflict, keepComputer: true, model: model) } }
                Button("Keep Original") { Task { await model.documents.resolve(conflict, keepComputer: false, model: model) } }
            }
        } message: {
            Text("Both the original and the computer copy of \(model.documents.conflicts.first?.record.name ?? "this document") changed. Choose which version to keep.")
        }
        .alert("Document sync", isPresented: Binding(get: { model.documents.error != nil && model.documents.pending == nil && model.documents.conflicts.isEmpty }, set: { if !$0 { model.documents.error = nil } })) {
            Button("Retry") { model.documents.error = nil; model.documents.requestSync(model: model) }
            Button("OK", role: .cancel) { model.documents.error = nil }
        } message: { Text(model.documents.error ?? "") }
        .alert("Couldn't sign in", isPresented: Binding(get: { model.pairingFailure != nil }, set: { if !$0 { model.pairingFailure = nil } })) {
            Button("OK", role: .cancel) { model.pairingFailure = nil }
        } message: { Text(model.pairingFailure ?? "") }
        .sheet(isPresented: Bindable(model).wallpaperPickerPresented) {
            NavigationStack {
                BackgroundPicker()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done", systemImage: "checkmark") { model.wallpaperPickerPresented = false }
                        }
                    }
            }
            .environment(model)
        }
        .sheet(isPresented: Bindable(model).settingsPresented) {
            ComputerSettingsView().environment(model)
        }
        .sheet(item: Binding(get: { model.notificationTaskID.map(NotificationTask.init) }, set: { model.notificationTaskID = $0?.id })) { destination in
            NavigationStack {
                Group {
                    if let task = model.agents.tasks.first(where: { $0.id == destination.id }) {
                        ScrollView { TaskCard(task: task, lines: model.agents.output[task.id] ?? []).padding() }
                    } else {
                        ContentUnavailableView("Task unavailable", systemImage: "sparkles", description: Text("Reconnect to your computer to see this task."))
                    }
                }
                .navigationTitle("Agent Task")
                .toolbar { Button("Done") { model.notificationTaskID = nil } }
            }
        }
        .sheet(isPresented: Bindable(model).showAgentSettings) {
            NavigationStack {
                AgentsView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.showAgentSettings = false } } }
            }
            .environment(model)
        }
    }
}

/// The dusk-to-night gradient behind everything.
struct Backdrop: View {
    var body: some View {
        MeshGradient(width: 3, height: 3, points: [
            [0, 0], [0.5, 0], [1, 0],
            [0, 0.5], [0.6, 0.45], [1, 0.55],
            [0, 1], [0.5, 1], [1, 1],
        ], colors: [
            Color(red: 0.06, green: 0.07, blue: 0.13), Color(red: 0.10, green: 0.08, blue: 0.20), Color(red: 0.05, green: 0.10, blue: 0.18),
            Color(red: 0.16, green: 0.09, blue: 0.20), Color(red: 0.32, green: 0.12, blue: 0.16), Color(red: 0.10, green: 0.12, blue: 0.24),
            Color(red: 0.05, green: 0.05, blue: 0.09), Color(red: 0.12, green: 0.06, blue: 0.10), Color(red: 0.04, green: 0.06, blue: 0.10),
        ])
        .ignoresSafeArea()
    }
}

struct WakeView: View {
    let connecting: Bool
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 22) {
            CabooseWordmark(motion: .rolling)
                .frame(height: 58)
                .foregroundStyle(.white.opacity(0.9))
            Text(connecting ? "Connecting" : "Waking")
                .font(.title3.weight(.semibold))
            ProgressView().tint(.white)
        }
        .multilineTextAlignment(.center)
        .padding(32)
    }
}

struct RestartingView: View {
    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 56, weight: .light))
                .symbolEffect(.rotate, options: .repeating, isActive: true)
                .foregroundStyle(.white.opacity(0.9))
            Text("Restarting")
                .font(.title3.weight(.semibold))
            ProgressView().tint(.white)
        }
        .multilineTextAlignment(.center)
        .padding(32)
    }
}

struct ParkedView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 22) {
            // Parked: the wordmark at rest with its hubs unlit.
            CabooseWordmark(lit: false)
                .frame(height: 58)
                .foregroundStyle(.white.opacity(0.9))
            Text("Parked")
                .font(.title3.weight(.semibold))
            Button("Turn On", systemImage: "power") { Task { await model.wake() } }
                .buttonStyle(.glassProminent)
        }
        .multilineTextAlignment(.center)
        .padding(32)
    }
}

struct FailureView: View {
    @Environment(AppModel.self) private var model
    let message: String

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.orange)
            Text("Out of Reach")
                .font(.title3.weight(.semibold))
            Text(HostMessage.clipped(message, maxLines: 3, maxCharacters: 200))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
            // A computer that will not wake can often be fixed from its settings: less memory, or a restart.
            HStack(spacing: 12) {
                Button("Try Again") { Task { await model.wake() } }
                    .buttonStyle(.glassProminent)
                Button("Change Computer") { model.signOut() }
                    .buttonStyle(.glass)
            }
        }
        .padding(32)
    }
}

/// Another device (a TV, an iPad) took the computer's display over. Nothing reconnects on its
/// own, so two devices never take it back and forth; Show Here takes it back on request.
struct ElsewhereView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("On Another Device")
                .font(.title3.weight(.semibold))
            Button("Show Here") { Task { await model.wake() } }
                .buttonStyle(.glassProminent)
        }
        .padding(32)
    }
}

struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var host = ""
    @State private var token = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                CabooseWordmark(motion: .intro)
                    .frame(height: 64)
                    .padding(.bottom, 6)
                    .accessibilityAddTraits(.isHeader)
                Text("Your phone's computer. A real Linux machine that wakes when you open it and keeps every app exactly where you left it.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 12) {
                TextField("Computer address — https://…", text: $host)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(14)
                    .glassEffect(.regular, in: .rect(cornerRadius: 14))
                SecureField("Pairing code or sign-in token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(14)
                    .glassEffect(.regular, in: .rect(cornerRadius: 14))
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Button {
                connect()
            } label: {
                Text(model.pairing ? "Signing In…" : "Wake My Computer").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(host.isEmpty || token.isEmpty || model.pairing)
            Text("Scan the QR code on the computer's Phones page in the Caboose console, or type its address and pairing code here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(28)
    }

    private func connect() {
        var text = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "http://" + text }
        guard let url = URL(string: text), url.host != nil else {
            error = "That doesn't look like a computer address."
            return
        }
        let entered = token.trimmingCharacters(in: .whitespacesAndNewlines)
        // A pairing code is traded for this phone's own token; anything else is a token itself.
        if let code = PairingLink.normalize(entered) {
            model.pair(with: PairingLink(hostURL: url, code: code))
        } else {
            model.connect(with: Credentials(hostURL: url, token: entered))
        }
    }
}

private struct NotificationTask: Identifiable { let id: String }
