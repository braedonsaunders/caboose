import SwiftUI
import CoreSpotlight

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
                    if let credentials = Credentials(link: url) { model.connect(with: credentials) }
                    else if url.scheme == "caboose", url.host == "task", let id = url.pathComponents.dropFirst().first { model.notificationTaskID = id }
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
            switch model.phase {
            case .needsSetup:
                SetupView()
            case .waking, .connecting:
                WakeView(connecting: model.phase == .connecting)
            case .restarting:
                RestartingView()
            case .parked:
                ParkedView()
            case .failed(let message):
                FailureView(message: message)
            case .displayElsewhere:
                ElsewhereView()
            case .ready where model.externalDisplayActive:
                TrackpadScreen(desktop: model.desktop)
            case .ready where model.deviceDesktopActive:
                DeviceDesktopScreen()
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            case .ready:
                HomeView()
                    .fullScreenCover(isPresented: Binding(
                        get: { model.presentedWindowID != nil },
                        set: { if !$0 { model.presentedWindowID = nil } })) {
                        WindowScreen()
                            .environment(model)
                    }
            }
        }
        .animation(.smooth(duration: 0.35), value: model.phase)
        .overlay(alignment: .top) {
            if model.phase == .ready, !model.externalDisplayActive { ApprovalBanner() }
        }
        .animation(.snappy, value: model.agents.awaitingApproval.first?.pendingApproval?.id)
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
            VStack(spacing: 6) {
                Text(connecting ? "Opening your display" : "Waking your computer")
                    .font(.title3.weight(.semibold))
                Text(connecting ? "Your apps are right where you left them." : "Every app comes back exactly as it was.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
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
            VStack(spacing: 6) {
                Text("Restarting your computer")
                    .font(.title3.weight(.semibold))
                Text("It starts fresh from its disk. Your files and apps are all still there.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
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
            VStack(spacing: 6) {
                Text("Your computer is parked")
                    .font(.title3.weight(.semibold))
                Text("Every app is saved exactly as you left it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("Wake") { Task { await model.wake() } }
                    .buttonStyle(.glassProminent)
                Button("Settings", systemImage: "gearshape") { model.settingsPresented = true }
                    .buttonStyle(.glass)
            }
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
            Text("Your computer is out of reach")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Try Again") { Task { await model.wake() } }
                    .buttonStyle(.glassProminent)
                Button("Change Computer") { model.signOut() }
                    .buttonStyle(.glass)
            }
            // A computer that will not wake can often be fixed from its settings: less memory, or a restart.
            Button("Computer Settings", systemImage: "gearshape") { model.settingsPresented = true }
                .buttonStyle(.glass)
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
            Text("Showing on another device")
                .font(.title3.weight(.semibold))
            Text("Another device is showing this computer's display. Your apps keep running there.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
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
                    .padding(.leading, -7) // the rail's overhang sits left of the c
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
                SecureField("Sign-in token", text: $token)
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
                Text("Wake My Computer").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(host.isEmpty || token.isEmpty)
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
        model.connect(with: Credentials(hostURL: url, token: token.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}

private struct NotificationTask: Identifiable { let id: String }
