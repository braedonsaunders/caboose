import CabooseKit
import SwiftUI

/// The computer's own settings, kept by the host: its name, the memory and cores it boots
/// with, how long it waits before parking, and the actions that park or restart it.
struct ComputerSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var push = PushCoordinator.shared
    @State private var draft: HostClient.ComputerStatus.Settings?
    @State private var sizeId = "custom"
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var saving = false
    @State private var parking = false
    @State private var confirmRestart = false
    @State private var confirmSignOut = false
    @State private var alternateAddress = ""
    @State private var addressError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let status = model.computerStatus, draft != nil {
                    form(status)
                } else if let loadError {
                    Form {
                        FilesSettingsSection()
                        NativeBridgeSettingsSection(bridge: model.bridge)
                        connectionAddressSection
                        Section {
                            ContentUnavailableView {
                                Label("Settings unavailable", systemImage: "exclamationmark.triangle")
                            } description: {
                                Text(loadError)
                            } actions: {
                                Button("Try Again") { Task { await load() } }.buttonStyle(.glass)
                            }
                        }
                    }
                } else {
                    Form {
                        FilesSettingsSection()
                        NativeBridgeSettingsSection(bridge: model.bridge)
                        connectionAddressSection
                        Section { ProgressView() }
                    }
                }
            }
            .navigationTitle("Computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }.disabled(changes.isEmpty || !nameIsValid)
                    }
                }
            }
            .confirmationDialog("Restart your computer?", isPresented: $confirmRestart, titleVisibility: .visible) {
                Button(changes.isEmpty ? "Restart" : "Save and Restart", role: .destructive) {
                    Task {
                        // Restarting is how new memory and cores apply, so unsaved edits go first.
                        if !changes.isEmpty {
                            await save()
                            guard saveError == nil else { return }
                        }
                        await model.restartComputer()
                    }
                }
            } message: {
                Text("Open apps close and unsaved work in them is lost. Your files and installed apps are kept.")
            }
            .confirmationDialog("Change computer?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Forget This Computer", role: .destructive) { model.signOut() }
            } message: {
                Text("This phone forgets the address and token. The computer and everything on it stay as they are.")
            }
        }
        .task { await load() }
        .onChange(of: model.computerStatus?.settings) { previous, settings in
            // Another device changed the settings; follow it unless there are unsaved edits here.
            if let settings, draft == nil || draft == previous { draft = settings }
        }
    }

    @ViewBuilder
    private func form(_ status: HostClient.ComputerStatus) -> some View {
        let limits = status.limits
        Form {
            FilesSettingsSection()
            NativeBridgeSettingsSection(bridge: model.bridge)
            connectionAddressSection
            if let upgrade = status.upgrade, let title = HostMessage.upgradeStatus(upgrade.state) {
                Section {
                    if upgrade.state == "failed" {
                        StatusRow(title: title, systemImage: "exclamationmark.triangle", tint: .orange, message: upgrade.message)
                    } else {
                        Label { Text(title) } icon: { ProgressView() }
                    }
                }
            }
            if status.restartRequired {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Restart to apply", systemImage: "arrow.clockwise.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text(pendingText(status))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if status.capabilities.restart {
                        Button("Restart Now") { confirmRestart = true }
                    }
                }
            }

            if status.capabilities.push == true {
                Section {
                    Toggle("Approval requests", isOn: $push.approvals)
                    Toggle("Finished tasks", isOn: $push.tasks)
                    Toggle("Desktop notifications", isOn: $push.desktop)
                    if let error = push.error { Text(error).font(.footnote).foregroundStyle(.orange) }
                    Button("Enable Notifications") { Task { await push.enable() } }
                } header: {
                    Text("Notifications on This Device")
                } footer: {
                    Text("Choose what can reach you when Caboose is closed. Enable notifications in iOS to receive them.")
                }
            }
            Section {
                NativeTextInput("Name", text: binding(\.name), capitalization: .words)
                    .submitLabel(.done)
                LabeledContent("State", value: Self.stateText(status.state))
                LabeledContent("Running with", value: status.activeResources.map {
                    "\(Self.memoryText($0.memoryMb)) · \(Self.coresText($0.vcpus))"
                } ?? "Known after the next restart")
            } header: {
                Text("Computer")
            } footer: {
                if !nameIsValid { Text("A name is 1 to 80 characters.") }
            }

            Section {
                if let sizes = status.sizes, !sizes.isEmpty {
                    Picker("Size", selection: Binding(get: { sizeId }, set: { id in
                        sizeId = id
                        if let size = sizes.first(where: { $0.id == id && $0.available }) {
                            draft?.memoryMb = size.memoryMb
                            draft?.vcpus = size.vcpus
                        }
                    })) {
                        Text("Custom / current").tag("custom")
                        ForEach(sizes) { size in
                            Text("\(size.name) · \(Self.memoryText(size.memoryMb)) · \(Self.coresText(size.vcpus))\(size.available ? "" : " (unavailable)")")
                                .tag(size.id).disabled(!size.available)
                        }
                    }
                }
                Picker("Memory", selection: Binding(get: { draft!.memoryMb }, set: { draft?.memoryMb = $0; sizeId = "custom" })) {
                    ForEach(Self.memoryChoices(limits.memoryMb.range, current: draft?.memoryMb), id: \.self) {
                        Text(Self.memoryText($0)).tag($0)
                    }
                }
                Stepper(value: Binding(get: { draft!.vcpus }, set: { draft?.vcpus = $0; sizeId = "custom" }), in: limits.vcpus.range) {
                    LabeledContent("Cores", value: "\(draft?.vcpus ?? 0)")
                }
            } header: {
                Text("Resources")
            } footer: {
                Text("Memory and cores apply the next time your computer restarts. GPU access uses the host GPU and is shared.")
            }

            Section {
                Picker("Park after", selection: binding(\.idleMs)) {
                    ForEach(Self.idleChoices(limits.idleMs.range, current: draft?.idleMs), id: \.self) {
                        Text(Self.durationText($0)).tag($0)
                    }
                }
            } footer: {
                Text("When no screen or agent is using it, your computer parks with everything still open, and wakes the next time you open Caboose.")
            }

            Section {
                Button {
                    Task {
                        parking = true
                        defer { parking = false }
                        dismiss()
                        try? await model.parkComputer()
                    }
                } label: {
                    Label("Park Now", systemImage: "moon.zzz")
                }
                .disabled(parking || !["running", "frozen"].contains(status.state))
                if status.capabilities.restart {
                    Button(role: .destructive) { confirmRestart = true } label: {
                        Label("Restart", systemImage: "arrow.clockwise")
                    }
                    .disabled(status.state == "restarting")
                }
            } footer: {
                Text("Parking keeps every app open. Restarting starts the computer fresh from its disk.")
            }

            Section {
                NavigationLink {
                    AgentsView()
                } label: {
                    LabeledContent("Agents", value: model.agents.defaultAgent.flatMap { model.agents.listing($0)?.name } ?? "Choose")
                }
            }

            Section {
                NavigationLink {
                    BackgroundPicker()
                } label: {
                    LabeledContent {
                        Text(backgroundName)
                    } label: {
                        Label("Wallpaper", systemImage: "photo.on.rectangle")
                    }
                }
            }

            Section("Connection") {
                if let host = model.credentials?.hostURL.host() {
                    LabeledContent("Host", value: host)
                }
                NavigationLink {
                    ConnectionDiagnosticsView()
                } label: {
                    LabeledContent("Display", value: model.connectionSummary)
                }
                LabeledContent("Screens connected", value: "\(status.clients.display)")
                LabeledContent("Agents working", value: "\(status.tasks.running + status.tasks.paused)")
            }

            if let error = saveError ?? status.lastError {
                Section {
                    StatusRow(title: saveError != nil ? "Couldn't Save" : "Last Error", systemImage: "exclamationmark.circle", tint: .secondary, message: error)
                }
            }

            Section {
                Button("Change Computer", role: .destructive) { confirmSignOut = true }
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { await load() }
    }

    private var connectionAddressSection: some View {
        Section {
            NativeTextInput("Remote address", text: $alternateAddress, keyboard: .URL, capitalization: .none, correction: false, contentType: .URL)
            Button("Save Remote Address") {
                guard var credentials = model.credentials,
                      let url = Credentials.normalizedAddress(alternateAddress) else {
                    addressError = "Enter an HTTP or HTTPS address without a username, password, query, or fragment."
                    return
                }
                credentials.addAlternate(url)
                do { try model.updateAddresses(credentials) }
                catch { addressError = error.localizedDescription; return }
                alternateAddress = ""
                addressError = nil
            }
            ForEach(model.credentials?.alternateURLs ?? [], id: \.self) { url in
                HStack {
                    Text(url.absoluteString).textSelection(.enabled)
                    Spacer()
                    Button("Remove", role: .destructive) {
                        guard var credentials = model.credentials else { return }
                        credentials.alternateURLs.removeAll { $0 == url }
                        do { try model.updateAddresses(credentials) }
                        catch { addressError = error.localizedDescription }
                    }
                }
            }
            if let addressError { Text(addressError).foregroundStyle(.red) }
        } header: {
            Text("Remote Access")
        } footer: {
            Text("Add an address for this same computer. Your phone keeps its existing sign-in.")
        }
    }

    private var backgroundName: String {
        switch WallpaperStore.shared.choice {
        case .gradient: "Gradient"
        case .rotating: "Rotating"
        case .photo(let id): Wallpaper.scene(id)?.name ?? "Wallpaper"
        case .custom: "Your Photo"
        }
    }

    // MARK: Editing

    private func binding<Value>(_ keyPath: WritableKeyPath<HostClient.ComputerStatus.Settings, Value>) -> Binding<Value> {
        Binding(
            get: { draft![keyPath: keyPath] },
            set: { draft?[keyPath: keyPath] = $0 })
    }

    private var nameIsValid: Bool {
        let name = draft?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (1 ... 80).contains(name.count)
    }

    /// Only the fields that differ from what the host has.
    private var changes: [String: JSONValue] {
        guard let draft, let saved = model.computerStatus?.settings else { return [:] }
        var changes: [String: JSONValue] = [:]
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name != saved.name { changes["name"] = .string(name) }
        if draft.memoryMb != saved.memoryMb || draft.vcpus != saved.vcpus {
            if sizeId != "custom" { changes["size"] = .string(sizeId) }
            else {
                if draft.memoryMb != saved.memoryMb { changes["memoryMb"] = .int(draft.memoryMb) }
                if draft.vcpus != saved.vcpus { changes["vcpus"] = .int(draft.vcpus) }
            }
        }
        if draft.idleMs != saved.idleMs { changes["idleMs"] = .int(draft.idleMs) }
        return changes
    }

    private func load() async {
        let baseline = model.computerStatus?.settings
        do {
            try await model.refreshComputer()
            loadError = nil
            // Keep edits in progress; otherwise show what the host has now.
            if draft == nil || draft == baseline { draft = model.computerStatus?.settings }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await model.saveSettings(changes)
            draft = model.computerStatus?.settings
            sizeId = "custom"
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func pendingText(_ status: HostClient.ComputerStatus) -> String {
        let wanted = "\(Self.memoryText(status.settings.memoryMb)) and \(Self.coresText(status.settings.vcpus))"
        guard let active = status.activeResources else { return "Your computer starts with \(wanted) after a restart." }
        return "Running with \(Self.memoryText(active.memoryMb)) and \(Self.coresText(active.vcpus)); restarting switches to \(wanted)."
    }

    // MARK: Formatting

    static func stateText(_ state: String) -> String {
        switch state {
        case "running": "Running"
        case "parked": "Parked"
        case "frozen": "Sleeping"
        case "waking": "Waking"
        case "parking": "Parking"
        case "restarting": "Restarting"
        case "error": "Needs attention"
        default: state.capitalized
        }
    }

    static func memoryText(_ megabytes: Int) -> String {
        megabytes % 1024 == 0 ? "\(megabytes / 1024) GB" : String(format: "%.1f GB", Double(megabytes) / 1024)
    }

    static func coresText(_ cores: Int) -> String { cores == 1 ? "1 core" : "\(cores) cores" }

    static func durationText(_ milliseconds: Int) -> String {
        let minutes = milliseconds / 60_000
        if minutes < 60 { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
        let hours = minutes / 60
        if minutes % 60 == 0 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        return "\(hours) h \(minutes % 60) min"
    }

    /// Whole-gigabyte steps within the host's bounds, plus the current value if it is not one.
    static func memoryChoices(_ range: ClosedRange<Int>, current: Int?) -> [Int] {
        let steps = [512, 1024, 2048, 3072, 4096, 6144, 8192, 12288, 16384, 24576, 32768, 49152, 65536]
        return Set(steps.filter(range.contains) + [current].compactMap { $0 }).sorted()
    }

    static func idleChoices(_ range: ClosedRange<Int>, current: Int?) -> [Int] {
        let minutes = [1, 5, 10, 15, 30, 60, 120, 240, 480, 1440]
        return Set(minutes.map { $0 * 60_000 }.filter(range.contains) + [current].compactMap { $0 }).sorted()
    }
}

/// A one-line status from the host; a tap shows its message, held to a few lines.
struct StatusRow: View {
    let title: String
    let systemImage: String
    let tint: Color
    let message: String?
    @State private var expanded = false

    var body: some View {
        if let message, !message.isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                Text(HostMessage.clipped(message))
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
            } label: {
                Label(title, systemImage: systemImage).foregroundStyle(tint)
            }
        } else {
            Label(title, systemImage: systemImage).foregroundStyle(tint)
        }
    }
}
