import CabooseKit
import SwiftUI

/// "Ask your computer": hand a task to an agent that works on its own seat.
struct AskBar: View {
    @Environment(AppModel.self) private var model
    @State private var prompt = ""
    /// A registry id, "" for the owner's default agent, or `onDevice`.
    @AppStorage("caboose.agent.choice") private var agent = ""
    @AppStorage("caboose.agent.askFirst") private var askFirst = false
    @AppStorage("caboose.agent.craftMcp") private var craftMcp = true
    @AppStorage("caboose.agent.delegate") private var delegate = ""
    @FocusState private var focused: Bool

    /// The bar's choice for the phone's own model, beside the computer's agents.
    static let onDevice = "iphone"

    var body: some View {
        let agents = model.agents
        HStack(spacing: 10) {
            Menu {
                Picker("Agent", selection: $agent) {
                    if OnDeviceAgent.isAvailable { Label("On iPhone", systemImage: "iphone").tag(Self.onDevice) }
                    Label(agents.defaultAgent.flatMap { agents.listing($0)?.name }.map { "Default (\($0))" } ?? "Default Agent",
                          systemImage: "sparkles").tag("")
                    ForEach(agents.installedAgents.filter { $0.id != agents.defaultAgent }) { agent in
                        Text(agent.name).tag(agent.id)
                    }
                }
                if agent != Self.onDevice {
                    Toggle(isOn: $askFirst) { Label("Ask Before Acting", systemImage: "hand.raised") }
                    Toggle(isOn: $craftMcp) { Label("Use Craft App Tools", systemImage: "wrench.and.screwdriver") }
                }
                Button { model.showAgentSettings = true } label: { Label("Agents…", systemImage: "slider.horizontal.3") }
            } label: {
                Image(systemName: agent == Self.onDevice ? "iphone" : "sparkles")
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
        .onAppear { if model.askFocusRequested { focused = true; model.askFocusRequested = false } }
        .onChange(of: model.askFocusRequested) { _, requested in
            if requested { focused = true; model.askFocusRequested = false }
        }
    }

    private func send() {
        let text = prompt
        prompt = ""
        focused = false
        let agents = model.agents
        if agent == Self.onDevice, OnDeviceAgent.isAvailable {
            Task { await agents.askOnDevice(text, delegatingTo: delegate.isEmpty ? nil : delegate) }
        } else {
            // An agent uninstalled elsewhere falls back to the default.
            let chosen = agents.listing(agent)?.isInstalled == true ? agent : nil
            Task { await agents.ask(text, agent: chosen, askFirst: askFirst) }
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
                    Text(model.agents.name(of: task)).font(.caption2).foregroundStyle(.tertiary)
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
            // A signed-out agent: sign in on the computer's screen, then reply to retry.
            if let methods = task.signIn, !methods.isEmpty, !task.isRunning {
                SignInRow(agentID: task.agent, methods: methods)
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
        default: CabooseWheel(motion: .rolling).frame(width: 20, height: 20)
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
    let seat: CabooseDisplaySession
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

/// Sign-in methods for a task whose agent was signed out.
struct SignInRow: View {
    @Environment(AppModel.self) private var model
    let agentID: String
    let methods: [SignInMethod]
    @State private var started: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(methods) { method in
                Button {
                    Task {
                        do {
                            try await model.agents.signIn(agentID, with: method)
                            started = "Finish signing in on your computer's screen, then reply to try again."
                        } catch {
                            started = error.localizedDescription
                        }
                    }
                } label: {
                    Label("Sign In: \(method.name)", systemImage: method.type == "terminal" ? "terminal" : "person.badge.key")
                }
                .buttonStyle(.glass)
            }
            if let started { Text(started).font(.caption).foregroundStyle(.secondary) }
        }
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
                Text("\(model.agents.name(of: task)) wants to use **\(approval.tool)**")
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
                // The agent's standing permission, when it offers one: allow this kind every time.
                if let always = approval.options?.first(where: { $0.kind == "allow_always" }) {
                    Button(always.name) { decide(true, option: always) }
                        .buttonStyle(.glass)
                }
                Button("Allow") { decide(true) }
                    .buttonStyle(.glassProminent)
            }
            .disabled(deciding)
        }
    }

    private func decide(_ allow: Bool, option: AgentCenter.Approval.Option? = nil) {
        deciding = true
        Task {
            await model.agents.decide(task, allow: allow, option: option)
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
    @AppStorage("caboose.agent.choice") private var agent = ""
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
                    // The phone's own model cannot take a screenshot along, so a window goes to a computer agent.
                    Picker("Agent", selection: $agent) {
                        Text("Default Agent").tag("")
                        if agent == AskBar.onDevice { Text("On iPhone").tag(AskBar.onDevice) }
                        ForEach(model.agents.installedAgents) { Text($0.name).tag($0.id) }
                    }
                    Toggle("Ask Before Acting", isOn: $askFirst)
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
            let chosen = model.agents.listing(agent)?.isInstalled == true ? agent : nil
            let started = await model.agents.ask(text, agent: chosen, askFirst: askFirst, attachments: attachments)
            sending = false
            if started { dismiss() }
        }
    }
}
