import CabooseKit
import SwiftUI

/// Native sidebar keeps teammates and their schedules beside the current conversation.
struct AgentLibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var section: String? = "Teammates"
    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Label("Teammates", systemImage: "person.2").tag("Teammates")
                Label("Routines", systemImage: "calendar.badge.clock").tag("Routines")
            }
            .navigationTitle("Agents")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        } detail: {
            NavigationStack {
                if section == "Routines" { AgentRoutinesView(openChat: { open($0) }) }
                else { AgentProfilesView(openChat: { open($0) }) }
            }
        }
        .tint(Brand.amber)
        .background { ShellBackground() }
    }
    private func open(_ id: String?) {
        model.agents.currentChat = id
        dismiss()
    }
}

struct AgentLibraryNotice: View {
    var error: String?
    var unavailable = false
    var loading = false
    let retry: () async -> Void
    var body: some View {
        if unavailable {
            ContentUnavailableView("Host Update Needed", systemImage: "arrow.up.circle", description: Text("Update caboose-host to use persistent teammates and routines."))
        } else if let error {
            VStack(alignment: .leading, spacing: 10) {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Button("Try Again") { Task { await retry() } }
            }
        } else if loading { HStack { ProgressView(); Text("Loading from your computer…").foregroundStyle(.secondary) } }
    }
}

struct AgentProfilesView: View {
    @Environment(AppModel.self) private var model
    @State private var creating = false
    @State private var search = ""
    let openChat: (String?) -> Void
    var body: some View {
        let library = model.agents.library
        List {
            AgentLibraryNotice(error: library.profileError, unavailable: library.profilesUnavailable,
                               loading: library.loadingProfiles, retry: { await library.refreshProfiles() })
            if !library.profilesUnavailable {
                ForEach([false, true], id: \.self) { archived in
                    let profiles = library.profiles.filter { $0.archived == archived && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
                    if !profiles.isEmpty {
                        Section(archived ? "Archived" : "Your Teammates") {
                            ForEach(profiles) { profile in
                                NavigationLink { AgentProfileDetail(profileID: profile.id, openChat: openChat) } label: {
                                    HStack(spacing: 12) {
                                        AgentAvatar(name: profile.name, size: 42)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(profile.name).font(.headline)
                                            Text(profile.description.isEmpty ? "\(profile.memories.count) saved memories" : profile.description)
                                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                    }.padding(.vertical, 4)
                                }
                            }
                        }
                    }
                }
                if library.profiles.isEmpty && !library.loadingProfiles && library.profileError == nil {
                    ContentUnavailableView("Meet Your Team", systemImage: "person.crop.circle.badge.plus", description: Text("Give a teammate a name, instructions, and memories to carry between conversations."))
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background { ShellBackground() }
        .navigationTitle("Teammates")
        .searchable(text: $search, prompt: "Find a teammate")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("New Teammate", systemImage: "plus") { creating = true }.disabled(library.profilesUnavailable) } }
        .refreshable { await library.refreshProfiles() }
        .task { await library.refreshProfiles() }
        .sheet(isPresented: $creating) { ProfileEditor(profile: nil).environment(model) }
    }
}

struct AgentProfileDetail: View {
    @Environment(AppModel.self) private var model
    let profileID: String
    let openChat: (String?) -> Void
    @State private var editing = false
    @State private var memoryEditor = false
    @State private var memory: AgentMemory?
    @State private var deletingMemory: AgentMemory?
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        let agents = model.agents
        let library = agents.library
        if let profile = library.profiles.first(where: { $0.id == profileID }) {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        AgentAvatar(name: profile.name, size: 64)
                        Text(profile.name).font(.largeTitle.bold())
                        if !profile.description.isEmpty { Text(profile.description).foregroundStyle(.secondary) }
                        Label(agents.listing(profile.agent)?.name ?? profile.agent, systemImage: "sparkles")
                            .font(.subheadline)
                    }.padding(.vertical, 12)
                    Button("Start Conversation", systemImage: "square.and.pencil") {
                        library.selectedProfileId = profile.id
                        openChat(nil)
                    }.disabled(profile.archived)
                } footer: { Text("This teammate reuses its workspace. Instructions and memories are copied into each new conversation.") }
                if let error { Section { Text(error).foregroundStyle(.orange) } }
                Section("Instructions") {
                    Text(profile.instructions.isEmpty ? "No saved instructions." : profile.instructions).textSelection(.enabled)
                    LabeledContent("Approvals", value: profile.approvals == "ask" ? "Ask before acting" : "Automatic")
                }
                Section {
                    ForEach(profile.memories) { item in
                        Button { memory = item; memoryEditor = true } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.title).font(.headline)
                                Text(item.content).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                            }.foregroundStyle(.primary).padding(.vertical, 3)
                        }
                        .swipeActions { Button("Delete", role: .destructive) { deletingMemory = item } }
                    }
                    Button("Add Memory", systemImage: "plus") { memory = nil; memoryEditor = true }
                } header: { Text("Saved Memories") } footer: { Text("Save preferences, facts, and working context this teammate should remember.") }
                Section("Conversations") {
                    let linked = agents.tasks.filter { $0.profileId == profile.id }
                    if let error = agents.tasksError {
                        Text(error).foregroundStyle(.orange)
                        Button("Retry Conversations") { Task { await agents.refresh() } }
                    } else if linked.isEmpty { Text("No linked conversations yet.").foregroundStyle(.secondary) }
                    ForEach(linked) { task in
                        Button { openChat(task.id) } label: {
                            HStack { Text(agents.title(of: task)).lineLimit(2); Spacer(); TaskStatusPill(task: task) }.foregroundStyle(.primary)
                        }
                    }
                }
                Section {
                    Button(profile.archived ? "Restore Teammate" : "Archive Teammate", systemImage: profile.archived ? "arrow.uturn.backward" : "archivebox") {
                        perform { try await library.saveProfile(profile.id, body: ["archived": .bool(!profile.archived)]) }
                    }
                } footer: { Text("Archiving prevents new conversations and routine runs. Existing conversations remain available.") }
            }
            .scrollContentBackground(.hidden)
            .background { ShellBackground() }
            .navigationTitle(profile.name).navigationBarTitleDisplayMode(.inline)
            .disabled(busy)
            .toolbar { ToolbarItem(placement: .primaryAction) { Button("Edit") { editing = true } } }
            .sheet(isPresented: $editing) { ProfileEditor(profile: profile).environment(model) }
            .sheet(isPresented: $memoryEditor) { MemoryEditor(profileID: profile.id, memory: memory).environment(model) }
            .confirmationDialog("Delete saved memory?", isPresented: Binding(get: { deletingMemory != nil }, set: { if !$0 { deletingMemory = nil } }), titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    guard let item = deletingMemory else { return }
                    perform { try await library.deleteMemory(profile: profile.id, memory: item.id) }
                    deletingMemory = nil
                }
            }
            .refreshable { await library.refreshProfiles(); await agents.refresh() }
            .task { await agents.refresh() }
        } else { ContentUnavailableView("Teammate Unavailable", systemImage: "person.crop.circle.badge.questionmark") }
    }
    private func perform(_ work: @escaping () async throws -> Void) {
        busy = true; error = nil
        Task { defer { busy = false }; do { try await work() } catch { self.error = error.localizedDescription } }
    }
}

struct ProfileEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let profile: AgentProfile?
    @State private var name: String
    @State private var description: String
    @State private var instructions: String
    @State private var agent: String
    @State private var approvals: String
    @State private var busy = false
    @State private var error: String?
    init(profile: AgentProfile?) {
        self.profile = profile
        _name = State(initialValue: profile?.name ?? "")
        _description = State(initialValue: profile?.description ?? "")
        _instructions = State(initialValue: profile?.instructions ?? "")
        _agent = State(initialValue: profile?.agent ?? "")
        _approvals = State(initialValue: profile?.approvals ?? "ask")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    NativeTextInput("Name", text: $name)
                    NativeTextInput("What does this teammate do?", text: $description, lines: 2...4)
                }
                Section {
                    NativeTextInput("Instructions", text: $instructions, lines: 6...16)
                } header: { Text("Instructions") } footer: { Text("Changes apply to new conversations. Existing conversations keep their original instructions and memories.") }
                Section("Provider") {
                    Picker("Runs With", selection: $agent) {
                        Text("Choose an agent").tag("")
                        if !agent.isEmpty && !model.agents.catalog.contains(where: { $0.id == agent }) { Text(agent).tag(agent) }
                        ForEach(model.agents.catalog) { Text($0.name).tag($0.id) }
                    }
                    Picker("Approvals", selection: $approvals) {
                        Text("Ask before acting").tag("ask")
                        Text("Automatic").tag("auto")
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.orange) } }
            }
            .scrollContentBackground(.hidden)
            .background { ShellBackground() }
            .navigationTitle(profile == nil ? "New Teammate" : "Edit Teammate")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(busy)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!valid || busy) }
            }
            .overlay { if busy { ProgressView() } }
            .task { await model.agents.refreshAgents(); if agent.isEmpty { agent = model.agents.defaultAgent ?? "" } }
        }
    }
    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf16.count <= 80 && description.utf16.count <= 500 && instructions.utf16.count <= 16000 && !agent.isEmpty
    }
    private func save() {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                try await model.agents.library.saveProfile(profile?.id, body: ["name": .string(name), "description": .string(description), "instructions": .string(instructions), "agent": .string(agent), "approvals": .string(approvals)])
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct MemoryEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let profileID: String
    let memory: AgentMemory?
    @State private var title: String
    @State private var content: String
    @State private var busy = false
    @State private var error: String?
    init(profileID: String, memory: AgentMemory?) {
        self.profileID = profileID; self.memory = memory
        _title = State(initialValue: memory?.title ?? ""); _content = State(initialValue: memory?.content ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Memory") {
                    NativeTextInput("Title", text: $title)
                    NativeTextInput("What should this teammate remember?", text: $content, lines: 8...20)
                }
                if let error { Text(error).foregroundStyle(.orange) }
            }
            .scrollContentBackground(.hidden)
            .background { ShellBackground() }
            .navigationTitle(memory == nil ? "New Memory" : "Edit Memory").navigationBarTitleDisplayMode(.inline)
            .disabled(busy)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        busy = true; error = nil
                        Task {
                            defer { busy = false }
                            do { try await model.agents.library.saveMemory(profile: profileID, memory: memory?.id, title: title, content: content); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }
                    }.disabled(busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.utf16.count > 120 || content.utf16.count > 8000)
                }
            }
            .overlay { if busy { ProgressView() } }
        }
    }
}
