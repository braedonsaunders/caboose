import SwiftUI

/// Settings › Agents: the ACP registry's agents on this computer — install, sign in, give an
/// API key, choose the default — and who the On iPhone agent hands work to.
struct AgentsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("caboose.agent.delegate") private var delegate = ""
    @State private var search = ""

    var body: some View {
        let agents = model.agents
        let shown = search.isEmpty ? agents.catalog : agents.catalog.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.description.localizedCaseInsensitiveContains(search)
        }
        List {
            if let error = agents.registryError {
                Section { Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary) }
            }
            if !agents.installedAgents.isEmpty, search.isEmpty {
                Section {
                    Picker("Default Agent", selection: Binding(get: { agents.defaultAgent ?? "" }, set: { id in
                        Task { try? await agents.makeDefault(id) }
                    })) {
                        ForEach(agents.installedAgents) { Text($0.name).tag($0.id) }
                    }
                    if OnDeviceAgent.isAvailable {
                        Picker("On iPhone Hands Work To", selection: $delegate) {
                            Text("The Default Agent").tag("")
                            ForEach(agents.installedAgents) { Text($0.name).tag($0.id) }
                        }
                    }
                } footer: {
                    Text(OnDeviceAgent.isAvailable
                         ? "The Ask bar uses the default agent unless you pick another. On iPhone runs Apple's on-device model: it opens apps and pages, types and presses buttons itself, and hands anything bigger to this agent."
                         : "The Ask bar uses the default agent unless you pick another.")
                }
            }
            let installed = shown.filter(\.isInstalled)
            if !installed.isEmpty {
                Section("On This Computer") { ForEach(installed) { row($0) } }
            }
            let available = shown.filter { !$0.isInstalled }
            if !available.isEmpty {
                Section {
                    ForEach(available) { row($0) }
                } header: {
                    Text("Available")
                } footer: {
                    Text("From the Agent Client Protocol registry. Each runs inside your computer, signed in with your own account or key.")
                }
            }
        }
        .searchable(text: $search, prompt: "Search agents")
        .navigationTitle("Agents")
        .refreshable { await agents.refreshAgents() }
        .task { await agents.refreshAgents() }
        .overlay {
            if agents.catalog.isEmpty {
                ContentUnavailableView("No Agents Yet", systemImage: "sparkles",
                                       description: Text(agents.registryError ?? "The computer has not reached the agent registry yet. Pull to try again."))
            }
        }
    }

    private func row(_ agent: AgentListing) -> some View {
        NavigationLink {
            AgentDetailView(agentID: agent.id)
        } label: {
            HStack(spacing: 12) {
                AgentMonogram(agent: agent)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(agent.name)
                        if agent.id == model.agents.defaultAgent { Text("Default").font(.caption2.weight(.semibold)).foregroundStyle(.tint) }
                    }
                    Text(agent.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                if model.agents.installing.contains(agent.id) { ProgressView() }
                else if agent.hasUpdate { Image(systemName: "arrow.down.circle").foregroundStyle(.tint) }
            }
        }
    }
}

struct AgentMonogram: View {
    let agent: AgentListing
    var body: some View {
        Text(agent.monogram)
            .font(.caption.weight(.bold))
            .frame(width: 34, height: 34)
            .background(.tint.opacity(0.15), in: .rect(cornerRadius: 8))
            .foregroundStyle(.tint)
    }
}

/// One agent: install or update it, sign in, its environment, and making it the default.
struct AgentDetailView: View {
    @Environment(AppModel.self) private var model
    let agentID: String
    @State private var error: String?
    @State private var newName = ""
    @State private var newValue = ""
    @State private var saving = false

    var body: some View {
        let agents = model.agents
        if let agent = agents.listing(agentID) {
            Form {
                Section {
                    HStack(spacing: 12) {
                        AgentMonogram(agent: agent)
                        VStack(alignment: .leading) {
                            Text(agent.name).font(.headline)
                            Text(agent.installed.map { "Installed \($0.version)" } ?? "Version \(agent.version)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !agent.description.isEmpty { Text(agent.description).font(.subheadline) }
                    if let link = (agent.website ?? agent.repository).flatMap(URL.init(string:)) { Link("About \(agent.name)", destination: link) }
                }
                Section {
                    if agents.installing.contains(agent.id) {
                        LabeledContent("Installing") { ProgressView() }
                    } else if !agent.isInstalled || agent.hasUpdate {
                        Button(agent.isInstalled ? "Update to \(agent.version)" : "Install", systemImage: "arrow.down.circle") {
                            perform { try await agents.install(agent) }
                        }
                    }
                    if agent.isInstalled, agent.id != agents.defaultAgent {
                        Button("Make Default", systemImage: "star") { perform { try await agents.makeDefault(agent.id) } }
                    }
                } footer: {
                    Text(agent.isInstalled ? "" : "Installing downloads it into your computer now; otherwise it downloads the first time it runs.")
                }
                if let methods = agent.signIn, !methods.isEmpty {
                    Section {
                        ForEach(methods) { method in
                            Button { perform { try await agents.signIn(agent.id, with: method) } } label: {
                                VStack(alignment: .leading) {
                                    Text("Sign In: \(method.name)")
                                    if let detail = method.description { Text(detail).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                        if let status = agent.signInStatus { signInStatus(status, methods: methods) }
                    } header: {
                        Text("Sign In")
                    } footer: {
                        Text("Opens on your computer's screen. Finish it there, in the Caboose window.")
                    }
                }
                Section {
                    ForEach(agent.env ?? [], id: \.self) { name in
                        Text(name).font(.body.monospaced())
                            .swipeActions { Button("Remove", role: .destructive) { perform { try await agents.setEnv(agent.id, remove: [name]) } } }
                    }
                    TextField("Name, e.g. OPENROUTER_API_KEY", text: $newName)
                        .font(.body.monospaced()).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    SecureField("Value", text: $newValue)
                    Button((agent.env ?? []).contains(newName.trimmingCharacters(in: .whitespaces)) ? "Replace" : "Add") {
                        let name = newName.trimmingCharacters(in: .whitespaces), value = newValue
                        perform {
                            try await agents.setEnv(agent.id, set: [name: value])
                            newName = ""; newValue = ""
                        }
                    }
                    .disabled(!Self.validName(newName) || newValue.isEmpty || newValue.contains("\n"))
                } header: {
                    Text("Environment")
                } footer: {
                    Text("For an API key instead of signing in, or a provider's address. Kept in your computer for this agent only, and never shown again.")
                }
                if let error {
                    Section { Text(error).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle(agent.name)
            .navigationBarTitleDisplayMode(.inline)
            .disabled(saving)
            .refreshable { await agents.refreshAgents() }
        } else {
            ContentUnavailableView("Agent Not Found", systemImage: "questionmark.circle")
        }
    }

    @ViewBuilder private func signInStatus(_ status: AgentListing.SignInStatus, methods: [SignInMethod]) -> some View {
        let name = methods.first { $0.id == status.methodId }?.name ?? status.methodId
        switch status.status {
        case "running": Label("Signing in with \(name) on your computer…", systemImage: "hourglass").foregroundStyle(.secondary)
        case "succeeded": Label("Signed in with \(name).", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        default: Label("Sign-in with \(name) failed\(status.message.map { ": \($0)" } ?? ".")", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
        }
    }

    static func validName(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespaces).range(of: "^[A-Za-z_][A-Za-z0-9_]{0,127}$", options: .regularExpression) != nil
    }

    private func perform(_ work: @escaping () async throws -> Void) {
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do { try await work() } catch { self.error = error.localizedDescription }
        }
    }
}
