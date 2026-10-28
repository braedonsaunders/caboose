import CabooseKit
import SwiftUI

/// The Agents tab: a conversation with Caboose. What you ask goes to the iPhone's own model,
/// which answers, acts on the computer, or hands real work to one of the computer's agents;
/// that work appears in the conversation as a live card that opens into its own thread. Work
/// in progress stays pinned along the top.
struct AgentsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var path: [String] = []
    @State private var connectingModel = false
    @State private var clearing = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if model.phase != .ready {
                    ComputerStateView()
                } else if !model.agents.available {
                    ContentUnavailableView("No Agents on This Host", systemImage: "sparkles",
                                           description: Text("Update caboose-host to talk to agents on this computer."))
                } else {
                    Conversation(connectModel: { connectingModel = true })
                        // Bars, so the conversation blurs away beneath them as it scrolls.
                        .safeAreaBar(edge: .top) { LiveStrip { path.append($0) } }
                        .safeAreaBar(edge: .bottom) {
                            AskBar(connectModel: { connectingModel = true }).padding(.horizontal, 14).padding(.bottom, 8)
                        }
                }
            }
            .background { ShellBackground() }
            .navigationTitle("Agents")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { AgentThreadView(taskID: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    AgentsMenu(connectModel: { connectingModel = true }, clear: { clearing = true })
                }
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ComputerToolbar()
            }
            .confirmationDialog("Clear your conversation with Caboose?", isPresented: $clearing, titleVisibility: .visible) {
                Button("Clear Conversation", role: .destructive) { model.agents.clearConversation() }
            } message: {
                Text("Tasks on your computer stay, with their own threads.")
            }
        }
        .sheet(isPresented: $connectingModel) { ConnectModelView().environment(model) }
        .onChange(of: model.agents.focusedTask, initial: true) { _, id in
            guard let id else { return }
            path = [id]
            model.agents.focusedTask = nil
        }
    }
}

/// Connect a model, agent settings, and clearing the conversation.
private struct AgentsMenu: View {
    @Environment(AppModel.self) private var model
    let connectModel: () -> Void
    let clear: () -> Void

    var body: some View {
        Menu {
            Button("Connect a Model…", systemImage: "key", action: connectModel)
            Button("Agent Settings", systemImage: "slider.horizontal.3") { model.showAgentSettings = true }
            if !model.agents.conversation.messages.isEmpty {
                Button("Clear Conversation", systemImage: "trash", role: .destructive, action: clear)
            }
        } label: {
            Label("Agents", systemImage: "ellipsis")
        }
    }
}

/// The conversation, oldest first and kept scrolled to the newest; a greeting when it is empty.
private struct Conversation: View {
    @Environment(AppModel.self) private var model
    let connectModel: () -> Void

    var body: some View {
        let agents = model.agents
        let items = ConversationItem.merge(messages: agents.conversation.messages, tasks: agents.tasks, started: AgentCenter.started)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if needsModel { SetupCard(connectModel: connectModel) }
                if items.isEmpty {
                    Greeting()
                } else {
                    ForEach(items) { item in
                        switch item {
                        case .message(let message): MessageView(message: message, connectModel: connectModel)
                        case .task(let task):
                            VStack(alignment: .leading, spacing: 10) {
                                PromptBubble(text: task.prompt, attachments: 0)
                                TaskCard(task: task, connectModel: connectModel)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .animation(.snappy, value: items.map(\.id))
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .refreshable {
            await agents.refresh()
            await agents.refreshAgents()
        }
    }

    /// Real work needs a computer agent; until one is installed and chosen, say how to get one.
    private var needsModel: Bool {
        let agents = model.agents
        return agents.defaultAgent == nil || agents.installedAgents.isEmpty
    }
}

/// What the owner asked Caboose, and its answer: the steps it took on the computer, what it
/// said, and the task it handed over, live.
private struct MessageView: View {
    @Environment(AppModel.self) private var model
    let message: ConversationMessage
    let connectModel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PromptBubble(text: message.prompt)
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.prompt }
                    Button("Ask Again", systemImage: "arrow.clockwise") { model.agents.draft = message.prompt }
                    Button("Delete", systemImage: "trash", role: .destructive) { model.agents.dismiss(message) }
                }
            HStack(alignment: .top, spacing: 10) {
                CabooseAvatar(size: 28, busy: message.status == .working)
                VStack(alignment: .leading, spacing: 8) {
                    if !message.steps.isEmpty {
                        FlowSteps(steps: message.steps)
                    }
                    switch message.status {
                    case .working:
                        if message.steps.isEmpty { TypingDots() }
                    case .done, .failed:
                        if let reply = message.reply, !reply.isEmpty {
                            Text(Markdown.inline(reply))
                                .font(.body)
                                .foregroundStyle(message.status == .failed ? .orange : .primary)
                                .textSelection(.enabled)
                        }
                    }
                    if let id = message.taskID, let task = model.agents.tasks.first(where: { $0.id == id }) {
                        TaskCard(task: task, connectModel: connectModel)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// The things Caboose did on the computer, as small chips.
private struct FlowSteps: View {
    let steps: [String]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    Label(step, systemImage: "arrow.turn.down.right")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .glassEffect(.regular.tint(Brand.amber.opacity(0.12)), in: .capsule)
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }
}

private struct TypingDots: View {
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0 ..< 3) { index in
                Circle().frame(width: 7, height: 7).foregroundStyle(.secondary)
                    .phaseAnimator([0.3, 1]) { dot, phase in dot.opacity(phase) } animation: { _ in
                        .easeInOut(duration: 0.5).delay(Double(index) * 0.15)
                    }
            }
        }
        .padding(.vertical, 8)
        .accessibilityLabel("Thinking")
    }
}

/// Work in progress, pinned above the conversation: each running or waiting task with its
/// current step. Tapping one opens its thread.
private struct LiveStrip: View {
    @Environment(AppModel.self) private var model
    let open: (String) -> Void

    var body: some View {
        let agents = model.agents
        let live = agents.tasks.filter { $0.isRunning || $0.pendingApproval != nil }
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
                                    Text(agents.name(of: task)).font(.caption.weight(.semibold))
                                    Text(task.pendingApproval.map { "Wants to use \($0.tool)" } ?? agents.threads[task.id]?.activity ?? task.prompt)
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
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// An empty conversation: who is listening, and a few things to ask.
private struct Greeting: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let agents = model.agents
        let worker = agents.defaultAgent.flatMap { agents.listing($0)?.name }
        VStack(spacing: 18) {
            CabooseAvatar(size: 72)
                .padding(.top, 36)
            Text("What should your computer do?")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            Text(subtitle(worker: worker))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            VStack(spacing: 8) {
                ForEach(suggestions, id: \.text) { suggestion in
                    Button { agents.draft = suggestion.text } label: {
                        Label(suggestion.text, systemImage: suggestion.symbol)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14).padding(.vertical, 11)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                }
            }
            .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
    }

    private func subtitle(worker: String?) -> String {
        switch (OnDeviceAgent.isAvailable, worker) {
        case (true, let worker?): "Caboose answers right here on your iPhone, works your apps, and hands bigger jobs to \(worker) on your computer."
        case (true, nil): "Caboose answers right here on your iPhone and works your apps. Connect a model for bigger jobs."
        case (false, let worker?): "\(worker) works on its own screen in your computer, so yours stays free."
        case (false, nil): "Connect a model, and an agent works on its own screen in your computer."
        }
    }

    private var suggestions: [(symbol: String, text: String)] {
        var list: [(String, String)] = []
        if OnDeviceAgent.isAvailable {
            list.append(("macwindow", "What's on my screen?"))
            list.append(("safari", "Open the weather for tomorrow"))
        }
        list.append(("folder", "Tidy my Downloads folder by type and tell me what you moved"))
        list.append(("doc.richtext", "Summarize the newest document in my Documents folder"))
        list.append(("tablecells", "Make a spreadsheet comparing three laptops under $1,500"))
        return list
    }
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
        .glassEffect(.regular.tint(Brand.amber.opacity(0.10)), in: .rect(cornerRadius: 22))
    }
}
