import CabooseKit
import SwiftUI

/// The Agents tab: a chat with an agent on your computer. Everything you send goes to that
/// agent as the next turn of one session, so it always has the whole conversation; while it
/// works, what you send waits for its turn to end. New Chat starts a fresh session, and the
/// chat list holds the earlier ones. Other chats still working are pinned along the top.
struct AgentsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var connectingModel = false
    @State private var showingChats = false
    @State private var showingLibrary = false

    var body: some View {
        let agents = model.agents
        let chat = agents.currentChat.flatMap { id in agents.tasks.first { $0.id == id } }
        NavigationStack {
            Group {
                if model.phase != .ready {
                    ComputerStateView()
                } else if !agents.available {
                    ContentUnavailableView("No Agents on This Host", systemImage: "sparkles",
                                           description: Text("Update caboose-host to talk to agents on this computer."))
                } else if let chat {
                    AgentThreadView(taskID: chat.id)
                        .id(chat.id)
                } else {
                    NewChat(connectModel: { connectingModel = true })
                        .safeAreaBar(edge: .bottom) { ChatComposer(task: nil) { connectingModel = true } }
                        .navigationTitle("Agents")
                }
            }
            .safeAreaBar(edge: .top) { LiveStrip(excluding: chat?.id) { agents.currentChat = $0 } }
            .background { ShellBackground() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Chats", systemImage: "list.bullet") { showingChats = true }
                }
                if chat != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("New Chat", systemImage: "square.and.pencil") { agents.currentChat = nil }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Teammates and Routines", systemImage: "person.2") { showingLibrary = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Agent Settings", systemImage: "slider.horizontal.3") { model.showAgentSettings = true }
                }
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ComputerToolbar()
            }
        }
        .alert("Agent Action Failed", isPresented: Binding(get: { agents.lastError != nil }, set: { if !$0 { agents.lastError = nil } })) {
            Button("OK") { agents.lastError = nil }
        } message: { Text(agents.lastError ?? "") }
        .sheet(isPresented: $connectingModel) { ConnectModelView().environment(model) }
        .sheet(isPresented: $showingChats) { ChatList().environment(model) }
        .sheet(isPresented: $showingLibrary) { AgentLibraryView().environment(model) }
        .onChange(of: agents.focusedTask, initial: true) { _, id in
            guard let id else { return }
            agents.currentChat = id
            agents.focusedTask = nil
        }
    }
}

/// Every chat on the computer, newest first: its name, agent, and where it stands.
private struct ChatList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        let agents = model.agents
        NavigationStack {
            List(agents.tasks.filter { search.isEmpty || agents.title(of: $0).localizedCaseInsensitiveContains(search) || agents.name(of: $0).localizedCaseInsensitiveContains(search) }) { task in
                Button {
                    agents.currentChat = task.id
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        AgentAvatar(name: agents.name(of: task), size: 32)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(agents.title(of: task)).font(.body.weight(.medium)).lineLimit(1)
                            HStack(spacing: 6) {
                                Text(agents.name(of: task))
                                if let started = AgentCenter.started(task) {
                                    Text("·")
                                    Text(started, format: .relative(presentation: .named))
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        TaskStatusPill(task: task)
                    }
                }
                .foregroundStyle(.primary)
                .listRowBackground(task.id == agents.currentChat ? Color.accentColor.opacity(0.12) : nil)
            }
            .overlay {
                if agents.tasks.isEmpty { ContentUnavailableView("No Chats Yet", systemImage: "bubble.left.and.bubble.right") }
            }
            .searchable(text: $search, prompt: "Search chats and agents")
            .refreshable { await agents.refresh() }
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("New Chat", systemImage: "square.and.pencil") {
                        agents.currentChat = nil
                        dismiss()
                    }
                }
            }
        }
    }
}

/// Other chats whose agents are working or waiting on you, pinned above the current one.
private struct LiveStrip: View {
    @Environment(AppModel.self) private var model
    let excluding: String?
    let open: (String) -> Void

    var body: some View {
        let agents = model.agents
        let live = agents.tasks.filter { $0.id != excluding && ($0.isRunning || $0.pendingApproval != nil) }
            .sorted { ($0.pendingApproval != nil ? 0 : 1) < ($1.pendingApproval != nil ? 0 : 1) }
        if !live.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(live) { task in
                        Button { open(task.id) } label: {
                            HStack(spacing: 8) {
                                if task.pendingApproval != nil {
                                    Image(systemName: "hand.raised.fill").foregroundStyle(.yellow)
                                } else if task.status == "paused" {
                                    Image(systemName: "pause.fill").foregroundStyle(.yellow)
                                } else {
                                    CabooseWheel(motion: .rolling).frame(width: 16, height: 16)
                                }
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(agents.title(of: task)).font(.caption.weight(.semibold))
                                    Text(task.pendingApproval.map { "Wants to use \($0.tool)" } ?? agents.threads[task.id]?.activity ?? agents.name(of: task))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .lineLimit(1)
                                .frame(maxWidth: 200, alignment: .leading)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.tint(task.pendingApproval != nil ? .yellow.opacity(0.18) : .clear).interactive(), in: .capsule)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .padding(.vertical, 4)
        }
    }
}

/// A new chat: who will answer, a few things to ask, and how to connect a model if none can.
private struct NewChat: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AskTarget.key) private var target = ""
    let connectModel: () -> Void

    var body: some View {
        let agents = model.agents
        let agent = agents.listing(target).flatMap { $0.isInstalled ? $0 : nil } ?? agents.defaultAgent.flatMap { agents.listing($0) }
        ScrollView {
            VStack(spacing: 18) {
                if agents.defaultAgent == nil || agents.installedAgents.isEmpty {
                    SetupCard(connectModel: connectModel)
                }
                Group {
                    if let agent { AgentAvatar(name: agent.name, size: 72) } else { CabooseAvatar(size: 72) }
                }
                .padding(.top, 36)
                Text("What shall we\nmake happen?")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .tracking(-0.7)
                    .multilineTextAlignment(.center)
                Text(agent.map { "Your files. Your apps. \($0.name), with a whole computer to work with." }
                     ?? "Your files. Your apps. Connect an agent and give it a whole computer to work with.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                VStack(spacing: 8) {
                    ForEach(Self.suggestions, id: \.text) { suggestion in
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            agents.draft = suggestion.text
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: suggestion.symbol).font(.title3).foregroundStyle(Brand.amber).frame(width: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(suggestion.title).font(.subheadline.weight(.semibold))
                                    Text(suggestion.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14).padding(.vertical, 13)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                    }
                }
                .frame(maxWidth: 420)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    static let suggestions: [(symbol: String, title: String, detail: String, text: String)] = [
        ("doc.text", "Make sense of a document", "Find the useful details in your files", "Find the newest document in my Documents folder and summarize it. Tell me which file you read."),
        ("globe", "Research something", "Bring the sources and an answer", "Help me research a topic. Ask me what I want to find out, then check current sources."),
        ("tablecells", "Make something useful", "A spreadsheet, a report, a starting point", "Help me make a spreadsheet. Ask me what it should contain, then save it in my Documents folder."),
    ]
}

/// Shown until a computer agent can take work: connect a model with a key, or sign in to one.
private struct SetupCard: View {
    @Environment(AppModel.self) private var model
    let connectModel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Give your computer a brain", systemImage: "key.horizontal")
                .font(.headline)
            Text("Agents run inside your computer with your own model. Paste an OpenRouter key to use any model — Claude, GPT, Gemini, Grok, Llama — or an Anthropic or OpenAI key. Or sign in to Claude, Codex or another agent with your account.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Button(action: connectModel) { Label("Connect a Model", systemImage: "key") }
                    .buttonStyle(.glassProminent)
                Button { model.showAgentSettings = true } label: { Text("Sign In Instead") }
                    .buttonStyle(.glass)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(Brand.amber.opacity(0.10)), in: .rect(cornerRadius: 22))
        .padding(.top, 12)
    }
}
