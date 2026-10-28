import CabooseKit
import SwiftUI

/// A chat: one task's whole conversation with its agent. Each turn's message, what the agent
/// thought, planned, ran and said, the permissions it asked for, and how the turn ended, live
/// while it works. What you send while it works waits for the turn to end, or goes now with
/// Send Now, which stops the turn.
struct AgentThreadView: View {
    @Environment(AppModel.self) private var model
    let taskID: String
    @State private var connectingModel = false

    var body: some View {
        let agents = model.agents
        Group {
            if let task = agents.tasks.first(where: { $0.id == taskID }) {
                let thread = agents.threads[taskID] ?? AgentThread(entries: [], prompt: task.prompt)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if thread.truncated {
                            Label("Earlier parts of this conversation are too long to show here.", systemImage: "text.append")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(thread.turns) { turn in
                            TurnView(task: task, turn: turn, isLast: turn.number == thread.lastTurn?.number)
                        }
                        if thread.turns.last?.outcome == nil, !task.isRunning, let summary = task.summary, !summary.isEmpty, task.signIn?.isEmpty != false {
                            // The transcript could not be read (the computer is parked): the host's summary stands in.
                            ChatMessageView(text: summary)
                        }
                        if task.isRunning, let draft = task.draft, draft.turn == task.turns {
                            if draft.kind == "thought" { ThoughtView(text: draft.text) }
                            else { ChatMessageView(text: draft.text) }
                        }
                        if task.isRunning {
                            WorkingIndicator(task: task, thread: thread)
                            if let seat = agents.seat,
                               let window = seat.windows.values.filter({ !$0.isAuxiliary }).sorted(by: { $0.id < $1.id }).last {
                                AgentSeatCard(seat: seat, window: window)
                            }
                        }
                        if let approval = task.pendingApproval {
                            ApprovalRow(task: task, approval: approval)
                                .padding(14)
                                .glassEffect(.regular.tint(.yellow.opacity(0.1)), in: .rect(cornerRadius: 20))
                        }
                        if let methods = task.signIn, !methods.isEmpty, !task.isRunning {
                            SignInRow(task: task, methods: methods) { connectingModel = true }
                        }
                        if agents.isLoading(taskID) && thread.turns.allSatisfy({ $0.items.isEmpty }) {
                            ProgressView().frame(maxWidth: .infinity)
                        }
                        if let queued = task.queued, !queued.isEmpty { QueuedView(task: task, queued: queued) }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .safeAreaBar(edge: .bottom) { ChatComposer(task: task) { connectingModel = true } }
                .toolbar { toolbar(task) }
                .navigationTitle(agents.title(of: task))
                .navigationSubtitle(agents.name(of: task))
                .navigationBarTitleDisplayMode(.inline)
            } else {
                ContentUnavailableView("Task Unavailable", systemImage: "sparkles",
                                       description: Text("Reconnect to your computer to see this conversation."))
            }
        }
        .background { ShellBackground() }
        // Again once the task list arrives, for a thread opened from a notification before it did.
        .task(id: "\(taskID):\(agents.tasks.contains { $0.id == taskID })") { await agents.loadThread(taskID) }
        .sheet(isPresented: $connectingModel) { ConnectModelView().environment(model) }
    }

    @ToolbarContentBuilder private func toolbar(_ task: AgentCenter.Task) -> some ToolbarContent {
        let agents = model.agents
        let seatWindows = agents.seat?.windows.values.filter { !$0.isAuxiliary }.sorted { $0.id < $1.id } ?? []
        if task.isRunning, let window = seatWindows.last {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Watch", systemImage: "eye") { model.presentAgentWindow(window.id) }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if task.isRunning {
                    Button("Stop", systemImage: "stop", role: .destructive) { Task { await agents.cancel(task) } }
                } else if let summary = task.summary, !summary.isEmpty {
                    Button("Copy Answer", systemImage: "doc.on.doc") { UIPasteboard.general.string = summary }
                }
                Button("Connect a Model…", systemImage: "key") { connectingModel = true }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }
}

/// What the owner sent while the agent worked: it goes with the agent's next turn, or now.
private struct QueuedView: View {
    @Environment(AppModel.self) private var model
    let task: AgentCenter.Task
    let queued: [String]
    @State private var sending = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(Array(queued.enumerated()), id: \.offset) { index, text in
                PromptBubble(text: text, attachmentNames: task.queuedAttachments?.indices.contains(index) == true ? task.queuedAttachments![index] : []).opacity(0.65)
            }
            HStack(spacing: 10) {
                Label("Waiting for \(model.agents.name(of: task)) to finish this step", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(sending ? "Sending…" : "Send Now") {
                    sending = true
                    Task { await model.agents.sendNow(task); sending = false }
                }
                    .disabled(sending)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.glass)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// One turn: the owner's message, then everything the agent did, then how it ended.
private struct TurnView: View {
    let task: AgentCenter.Task
    let turn: AgentThread.Turn
    let isLast: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !turn.prompt.isEmpty { PromptBubble(text: turn.prompt, attachmentNames: turn.attachments) }
            ForEach(turn.items) { item in
                switch item {
                case .text(_, let text):
                    ChatMessageView(text: text)
                case .thought(_, let text): ThoughtView(text: text)
                case .tools(_, let tools): ToolGroupView(tools: tools, live: isLast && task.isRunning)
                case .plan(_, let entries): PlanView(entries: entries)
                case .permission(_, let permission): PermissionLine(permission: permission)
                case .notice(_, let text):
                    Label(text, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let outcome = turn.outcome { OutcomeView(outcome: outcome, turn: turn) }
        }
    }
}

/// What the owner wrote, on the right like any message they sent.
struct PromptBubble: View {
    let text: String
    var attachmentNames: [String] = []

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 4) {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Brand.amber.opacity(0.22), in: .rect(cornerRadius: 20))
                ForEach(Array(attachmentNames.enumerated()), id: \.offset) { _, path in
                    Label((path as NSString).lastPathComponent, systemImage: "paperclip")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

private struct ThoughtView: View {
    let text: String
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                Label(open ? "Thought" : "Thought — \(text.prefix(60))…", systemImage: "brain")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            if open {
                Text(text).font(.footnote).italic().foregroundStyle(.secondary).textSelection(.enabled)
                    .padding(.leading, 22)
            }
        }
    }
}

/// Consecutive tool calls: shown one per row when few or still running, else folded into a
/// line of their icons that opens.
private struct ToolGroupView: View {
    let tools: [AgentThread.Tool]
    let live: Bool
    @State private var open = false

    var body: some View {
        let folded = tools.count > 3 && !open && !(live && tools.contains(where: \.isActive))
        VStack(alignment: .leading, spacing: 8) {
            if folded {
                Button { withAnimation(.snappy) { open = true } } label: {
                    HStack(spacing: 8) {
                        HStack(spacing: -4) {
                            ForEach(Array(tools.prefix(6).enumerated()), id: \.offset) { _, tool in
                                ToolIcon(kind: tool.kind)
                                    .frame(width: 22, height: 22)
                                    .background(.ultraThinMaterial, in: .circle)
                            }
                        }
                        Text("Used \(tools.count) tools").font(.footnote.weight(.medium))
                        if tools.contains(where: \.isFailed) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                        }
                        Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                ForEach(tools) { ToolRow(tool: $0) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: .rect(cornerRadius: 16))
    }
}

private struct ToolRow: View {
    let tool: AgentThread.Tool
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ToolIcon(kind: tool.kind).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.title).font(.footnote.weight(.medium)).lineLimit(2)
                if let detail = tool.detail, !tool.title.contains(detail) {
                    Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(expanded ? nil : 2).textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            Group {
                if tool.isActive { ProgressView().controlSize(.mini) }
                else if tool.isFailed { Image(systemName: "xmark.circle.fill").foregroundStyle(.orange) }
                else if tool.isDone { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green.opacity(0.8)) }
                else { Image(systemName: "circle").foregroundStyle(.secondary) }
            }
            .font(.caption)
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
        .accessibilityAction(named: expanded ? "Collapse details" : "Show details") { expanded.toggle() }
    }
}

struct ToolIcon: View {
    let kind: String

    var body: some View {
        Image(systemName: Self.symbol(kind)).font(.caption).foregroundStyle(.secondary)
    }

    static func symbol(_ kind: String) -> String {
        switch kind {
        case "read": "doc.text"
        case "edit": "pencil"
        case "delete": "trash"
        case "move": "arrow.right.doc.on.clipboard"
        case "search": "magnifyingglass"
        case "execute": "terminal"
        case "think": "brain"
        case "fetch": "globe"
        case "switch_mode": "arrow.triangle.swap"
        default: "wrench.and.screwdriver"
        }
    }
}

/// The agent's plan as a checklist that ticks off as it works.
private struct PlanView: View {
    let entries: [TranscriptEntry.PlanEntry]

    var body: some View {
        let done = entries.filter { $0.status == "completed" }.count
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Plan", systemImage: "list.bullet.clipboard").font(.footnote.weight(.semibold))
                Spacer()
                Text("\(done) of \(entries.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: entry.status == "completed" ? "checkmark.circle.fill" : entry.status == "in_progress" ? "circle.dotted.circle" : "circle")
                        .foregroundStyle(entry.status == "completed" ? .green : entry.status == "in_progress" ? Brand.amber : .secondary)
                        .symbolEffect(.pulse, isActive: entry.status == "in_progress")
                    Text(entry.content)
                        .font(.footnote)
                        .strikethrough(entry.status == "completed", color: .secondary)
                        .foregroundStyle(entry.status == "completed" ? .secondary : .primary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: .rect(cornerRadius: 16))
    }
}

private struct PermissionLine: View {
    let permission: AgentThread.Permission

    var body: some View {
        let (symbol, color, verb): (String, Color, String) = switch permission.allowed {
        case .some(true): ("checkmark.shield", .green, permission.auto ? "Allowed automatically" : "You allowed")
        case .some(false): ("xmark.shield", .orange, "You denied")
        case .none: ("hand.raised", .yellow, "Asked to use")
        }
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text("\(verb) **\(permission.tool)**") + Text(permission.summary.isEmpty ? "" : " — \(permission.summary)").foregroundStyle(.secondary)
            } icon: {
                Image(systemName: symbol).foregroundStyle(color)
            }
            .font(.caption)
            .lineLimit(2)
            if let message = permission.message { Text("“\(message)”").font(.caption2).foregroundStyle(.secondary).padding(.leading, 24) }
        }
    }
}

private struct OutcomeView: View {
    let outcome: AgentThread.Outcome
    let turn: AgentThread.Turn

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch outcome {
            case .finished(let stopReason, _):
                if stopReason == "cancelled" {
                    Label("Stopped", systemImage: "stop.circle").font(.caption).foregroundStyle(.secondary)
                } else if stopReason != "end_turn" {
                    Label(Self.describe(stopReason), systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .background(.orange.opacity(0.1), in: .rect(cornerRadius: 12))
            case .signInRequired:
                EmptyView() // the sign-in options below the thread say what to do
            }
            if let usage = turn.usage {
                HStack(spacing: 6) {
                    Gauge(value: usage.fraction) { EmptyView() }
                        .gaugeStyle(.accessoryLinearCapacity)
                        .tint(usage.fraction > 0.8 ? .orange : Brand.amber)
                        .frame(width: 60)
                    Text("\(Int((usage.fraction * 100).rounded()))% of context")
                    if let cost = turn.cost { Text("· \(cost.amount, format: .currency(code: cost.currency))") }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
    }

    static func describe(_ stopReason: String) -> String {
        switch stopReason {
        case "max_tokens": "Stopped: the answer reached the agent's length limit"
        case "max_turn_requests": "Stopped: the agent reached its limit of steps"
        case "refusal": "The agent declined"
        default: "Ended: \(stopReason)"
        }
    }
}

/// The agent at work: its current step under a rolling wheel.
private struct WorkingIndicator: View {
    let task: AgentCenter.Task
    let thread: AgentThread

    var body: some View {
        HStack(spacing: 10) {
            if task.status == "paused" {
                Image(systemName: "pause.circle.fill").foregroundStyle(.yellow)
            } else {
                CabooseWheel(motion: .rolling).frame(width: 18, height: 18)
            }
            Text(task.status == "paused" ? "Paused" : thread.activity ?? "Working…")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .contentTransition(.opacity)
        }
        .animation(.snappy, value: thread.activity)
    }
}
