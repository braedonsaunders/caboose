import CabooseKit
import SwiftUI

/// "Ask your computer": hand a task to an agent that works on its own seat.
struct AskBar: View {
    @Environment(AppModel.self) private var model
    @State private var prompt = ""
    @AppStorage("caboose.agent") private var agent = "claude"
    @AppStorage("caboose.agent.askFirst") private var askFirst = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Agent", selection: $agent) {
                    Label("Claude Code", systemImage: "sparkle").tag("claude")
                    Label("Codex", systemImage: "chevron.left.forwardslash.chevron.right").tag("codex")
                }
                if agent == "claude" {
                    Toggle(isOn: $askFirst) {
                        Label("Ask Before Acting", systemImage: "hand.raised")
                    }
                }
            } label: {
                Image(systemName: agent == "claude" ? "sparkle" : "chevron.left.forwardslash.chevron.right")
                    .frame(width: 36, height: 36)
            }
            TextField("Ask your computer to do something…", text: $prompt, axis: .vertical)
                .lineLimit(1 ... 4)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit(send)
            if !prompt.isEmpty {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
        .animation(.snappy, value: prompt.isEmpty)
    }

    private func send() {
        let text = prompt
        prompt = ""
        focused = false
        Task { await model.agents.ask(text, agent: agent, askFirst: askFirst) }
    }
}

/// Tasks and the agent seat's windows, on Home.
struct AgentSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let agents = model.agents
        if !agents.tasks.isEmpty || !(agents.seat?.windows.isEmpty ?? true) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Agents").font(.headline).foregroundStyle(.secondary)
                if let seat = agents.seat, !seat.windows.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 14) {
                            ForEach(seat.windows.values.filter { !$0.isAuxiliary }.sorted { $0.id < $1.id }) { window in
                                Button { model.presentAgentWindow(window.id) } label: {
                                    WindowCard(window: window, icon: model.icon(for: window))
                                        .overlay(alignment: .topTrailing) {
                                            Label("Agent", systemImage: "sparkle").font(.caption2.weight(.semibold))
                                                .padding(.horizontal, 8).padding(.vertical, 4)
                                                .glassEffect(.regular, in: .capsule).padding(8)
                                        }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
                ForEach(agents.tasks.prefix(6)) { task in
                    TaskCard(task: task, lines: agents.output[task.id] ?? [])
                }
            }
        }
    }
}

struct TaskCard: View {
    @Environment(AppModel.self) private var model
    let task: AgentCenter.Task
    let lines: [AgentCenter.Line]
    @State private var expanded = false
    @State private var reply = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                statusIcon
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.prompt).font(.subheadline.weight(.semibold)).lineLimit(expanded ? nil : 2)
                    Text(task.summary ?? lines.last?.text ?? (task.isRunning ? "Working…" : ""))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(expanded ? nil : 2)
                }
                Spacer(minLength: 0)
                if task.isRunning {
                    Button { Task { await model.agents.cancel(task) } } label: {
                        Image(systemName: "stop.circle").font(.title3)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let approval = task.pendingApproval {
                ApprovalRow(task: task, approval: approval)
            }
            if expanded, !lines.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(lines.suffix(200)) { line in
                            Text(line.text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(line.kind == "error" ? .orange : line.kind == "tool" ? .cyan
                                                 : line.kind == "prompt" ? .secondary : .primary)
                                .fontWeight(line.kind == "prompt" ? .semibold : nil)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 260)
                .defaultScrollAnchor(.bottom)
            }
            if expanded, task.canReply {
                HStack(spacing: 8) {
                    TextField("Reply to continue…", text: $reply, axis: .vertical)
                        .lineLimit(1 ... 4)
                        .submitLabel(.send)
                        .onSubmit(sendReply)
                    if !reply.isEmpty {
                        Button(action: sendReply) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
    }

    private func sendReply() {
        let text = reply
        reply = ""
        Task { await model.agents.reply(to: task, text) }
    }

    @ViewBuilder private var statusIcon: some View {
        switch task.status {
        case "succeeded": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case "failed": Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case "cancelled": Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        case "paused": Image(systemName: "pause.circle.fill").foregroundStyle(.yellow)
        case _ where task.pendingApproval != nil: Image(systemName: "hand.raised.circle.fill").foregroundStyle(.yellow)
        default: ProgressView().controlSize(.small)
        }
    }
}

/// An agent-seat window full screen: watch the agent work, or take over with touch and keyboard.
struct AgentWindowScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if let seat = model.agents.seat, let id = model.presentedAgentWindowID, let window = seat.windows[id] {
                GeometryReader { proxy in
                    AgentSeatCanvas(seat: seat, window: window, pixelsPerPoint: model.pixelsPerPoint,
                                    interactive: model.agents.tookOver)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .onAppear {
                            let frame = CGRect(x: 0, y: 0, width: proxy.size.width * model.pixelsPerPoint,
                                               height: proxy.size.height * model.pixelsPerPoint).integral
                            if window.frame != frame { seat.configure(window, frame: frame) }
                        }
                }
                .padding(.top, 52)
                HStack {
                    Button { model.presentedAgentWindowID = nil } label: {
                        Image(systemName: "chevron.down").frame(width: 40, height: 40)
                    }
                    .glassEffect(.regular.interactive(), in: .circle)
                    Label(window.title.isEmpty ? "Agent window" : window.title, systemImage: "sparkle")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 14).frame(height: 40)
                        .glassEffect(.regular, in: .capsule)
                    Spacer()
                    takeOverButton
                }
                .padding(.horizontal, 12).padding(.top, 4)
            }
        }
        // Leaving the window always hands control back to the agent.
        .onDisappear { Task { await model.agents.handBack() } }
    }

    /// Watching is the default; taking over stops the agent until it is handed back.
    private var takeOverButton: some View {
        let agents = model.agents
        return Button {
            Task { agents.tookOver ? await agents.handBack() : await agents.takeOver() }
        } label: {
            Label(agents.tookOver ? "Hand Back" : "Take Over",
                  systemImage: agents.tookOver ? "arrow.uturn.backward" : "hand.raised.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).frame(height: 40)
        }
        .glassEffect(agents.tookOver ? .regular.tint(.orange).interactive() : .regular.interactive(), in: .capsule)
    }
}

struct AgentSeatCanvas: UIViewRepresentable {
    let seat: XpraSession
    let window: RemoteWindow
    let pixelsPerPoint: CGFloat
    let interactive: Bool

    func makeUIView(context: Context) -> RemoteWindowView {
        let view = RemoteWindowView(session: seat, window: window)
        view.pixelsPerPoint = pixelsPerPoint
        view.isInteractive = interactive
        return view
    }

    func updateUIView(_ view: RemoteWindowView, context: Context) {
        if view.remoteWindow?.id != window.id { view.attach(window) }
        view.isInteractive = interactive
    }
}

/// What an agent wants to do next, with Allow and Deny.
struct ApprovalRow: View {
    @Environment(AppModel.self) private var model
    let task: AgentCenter.Task
    let approval: AgentCenter.Approval
    @State private var deciding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("\(task.agent == "codex" ? "Codex" : "Claude") wants to use **\(approval.tool)**")
            } icon: {
                Image(systemName: "hand.raised.fill").foregroundStyle(.yellow)
            }
            .font(.footnote)
            if !approval.summary.isEmpty {
                Text(approval.summary)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.black.opacity(0.25), in: .rect(cornerRadius: 8))
            }
            HStack {
                Button("Deny", role: .destructive) { decide(false) }
                    .buttonStyle(.glass)
                Spacer()
                Button("Allow") { decide(true) }
                    .buttonStyle(.glassProminent)
            }
            .disabled(deciding)
        }
    }

    private func decide(_ allow: Bool) {
        deciding = true
        Task {
            await model.agents.decide(task, allow: allow)
            deciding = false
        }
    }
}

/// The oldest action waiting for the owner, shown over whatever is on screen.
struct ApprovalBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let task = model.agents.awaitingApproval.first, let approval = task.pendingApproval {
            VStack(alignment: .leading, spacing: 6) {
                Text(task.prompt).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                ApprovalRow(task: task, approval: approval)
            }
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
            .padding(.horizontal, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
            .id(approval.id)
        }
    }
}

/// Hands the window the owner is looking at to an agent: its screenshot, title and app go
/// with the request.
struct AskAboutWindowSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let window: RemoteWindow
    @State private var prompt = ""
    @State private var snapshot: UIImage?
    @State private var sending = false
    @AppStorage("caboose.agent") private var agent = "claude"
    @AppStorage("caboose.agent.askFirst") private var askFirst = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                if let snapshot {
                    Section {
                        Image(uiImage: snapshot).resizable().scaledToFit().frame(maxHeight: 220).frame(maxWidth: .infinity)
                    } footer: {
                        Text("A screenshot of “\(window.title.isEmpty ? "this window" : window.title)” goes with your request.")
                    }
                }
                Section {
                    TextField("What should the agent do with it?", text: $prompt, axis: .vertical)
                        .lineLimit(3 ... 8)
                        .focused($focused)
                }
                Section {
                    Picker("Agent", selection: $agent) {
                        Text("Claude Code").tag("claude")
                        Text("Codex").tag("codex")
                    }
                    if agent == "claude" { Toggle("Ask Before Acting", isOn: $askFirst) }
                }
            }
            .navigationTitle("Ask an Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send", action: send).disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                }
            }
        }
        .onAppear {
            focused = true
            snapshot = window.surface.snapshot().map { UIImage(cgImage: $0) }
        }
    }

    private func send() {
        sending = true
        let app = window.appClass?.name ?? "an app"
        let title = window.title.isEmpty ? app : window.title
        let text = """
        I'm looking at the window “\(title)” (\(app)) on my display. The attached screenshot shows it as I see it.

        \(prompt)
        """
        let attachments = snapshot?.pngData().map { [AgentCenter.Attachment(name: "window.png", type: "image/png", data: $0)] } ?? []
        Task {
            let started = await model.agents.ask(text, agent: agent, askFirst: askFirst, attachments: attachments)
            sending = false
            if started { dismiss() }
        }
    }
}
