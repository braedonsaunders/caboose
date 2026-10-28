import CabooseKit
import SwiftUI

/// Where the composer sends: Caboose (the iPhone's model, which hands real work on) or one agent.
enum AskTarget {
    /// The storage key: "" for Caboose, else an agent's registry id.
    static let key = "caboose.agent.target"
}

/// The Agents tab's composer: talk to Caboose, or straight to one of the computer's agents.
struct AskBar: View {
    @Environment(AppModel.self) private var model
    @State private var prompt = ""
    @AppStorage(AskTarget.key) private var target = ""
    @AppStorage("caboose.agent.askFirst") private var askFirst = false
    @AppStorage("caboose.agent.craftMcp") private var craftMcp = true
    @AppStorage("caboose.agent.delegate") private var delegate = ""
    @FocusState private var focused: Bool
    var connectModel: () -> Void = {}

    var body: some View {
        let agents = model.agents
        let direct = agents.listing(target).flatMap { $0.isInstalled ? $0 : nil }
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                Picker("Talk To", selection: $target) {
                    Label(OnDeviceAgent.isAvailable ? "Caboose" : agents.defaultAgent.flatMap { agents.listing($0)?.name }.map { "Caboose (\($0))" } ?? "Caboose",
                          systemImage: "sparkles").tag("")
                    ForEach(agents.installedAgents) { agent in
                        Text(agent.name).tag(agent.id)
                    }
                }
                Section {
                    Toggle(isOn: $askFirst) { Label("Ask Before Acting", systemImage: "hand.raised") }
                    Toggle(isOn: $craftMcp) { Label("Use Craft App Tools", systemImage: "wrench.and.screwdriver") }
                }
                Section {
                    Button(action: connectModel) { Label("Connect a Model…", systemImage: "key") }
                    Button { model.showAgentSettings = true } label: { Label("Agents…", systemImage: "slider.horizontal.3") }
                }
            } label: {
                Group {
                    if let direct { AgentAvatar(name: direct.name, size: 30) } else { CabooseAvatar(size: 30) }
                }
                .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Talk to \(direct?.name ?? "Caboose")")
            TextField(direct.map { "Message \($0.name)…" } ?? "Ask Caboose anything…", text: $prompt, axis: .vertical)
                .lineLimit(1 ... 6)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.vertical, 8)
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(prompt.isEmpty ? 0.4 : 1)
        }
        .padding(.leading, 8).padding(.trailing, 6).padding(.vertical, 5)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26))
        .animation(.snappy, value: prompt.isEmpty)
        .onAppear { if model.askFocusRequested { focused = true; model.askFocusRequested = false } }
        .onChange(of: model.askFocusRequested) { _, requested in
            if requested { focused = true; model.askFocusRequested = false }
        }
        // A suggestion lands in the composer, to send as is or edit first.
        .onChange(of: model.agents.draft) { _, draft in
            guard let draft else { return }
            prompt = draft
            focused = true
            model.agents.draft = nil
        }
    }

    private func send() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        prompt = ""
        let agents = model.agents
        // An agent uninstalled elsewhere falls back to Caboose.
        if let agent = agents.listing(target), agent.isInstalled {
            Task { await agents.start(text, agent: agent.id, askFirst: askFirst) }
        } else {
            let chosen = agents.listing(delegate)?.isInstalled == true ? delegate : nil
            Task { await agents.send(text, agent: chosen, askFirst: askFirst) }
        }
    }
}

/// An agent as a letter mark in a disc, coloured from its name so each agent keeps its own colour.
struct AgentAvatar: View {
    let name: String
    var size: CGFloat = 28

    var body: some View {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.count > 1 ? String(words.prefix(2).compactMap(\.first)) : String(name.prefix(2))
        Text(letters.uppercased())
            .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Self.gradient(for: name), in: .circle)
            .accessibilityHidden(true)
    }

    static func gradient(for name: String) -> LinearGradient {
        let hue = Double(name.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value } % 360) / 360
        return LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.85), Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.55)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Caboose itself: the brand wheel in an amber disc.
struct CabooseAvatar: View {
    var size: CGFloat = 28
    var busy = false

    var body: some View {
        CabooseWheel(motion: busy ? .rolling : .still)
            .padding(size * 0.16)
            .frame(width: size, height: size)
            .background(Brand.amber.gradient.opacity(0.22), in: .circle)
            .overlay(Circle().stroke(Brand.amber.opacity(0.5), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// A task's state in a word or two, coloured.
struct TaskStatusPill: View {
    @Environment(AppModel.self) private var model
    let task: AgentCenter.Task

    var body: some View {
        let (text, color) = describe
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: .capsule)
    }

    private var describe: (String, Color) {
        if task.pendingApproval != nil { return ("Needs You", .yellow) }
        if task.signIn?.isEmpty == false && !task.isRunning { return ("Signed Out", .orange) }
        switch task.status {
        case "running", "queued":
            if let progress = model.agents.threads[task.id]?.progress { return ("Step \(min(progress.done + 1, progress.total)) of \(progress.total)", Brand.amber) }
            return ("Working", Brand.amber)
        case "paused": return ("Paused", .yellow)
        case "succeeded": return ("Done", .green)
        case "cancelled": return ("Stopped", .secondary)
        default: return ("Failed", .orange)
        }
    }
}

/// A computer agent's task in the conversation: who has it, what it is doing now (its plan's
/// progress and current step) or how it ended, and anything it needs from the owner. Tapping
/// it opens the whole conversation with that agent.
struct TaskCard: View {
    @Environment(AppModel.self) private var model
    let task: AgentCenter.Task
    /// Kept for callers that pass the task's flattened output; the card reads the thread.
    var lines: [AgentCenter.Line] = []
    var connectModel: () -> Void = {}

    var body: some View {
        let agents = model.agents
        let thread = agents.threads[task.id]
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink {
                AgentThreadView(taskID: task.id)
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        AgentAvatar(name: agents.name(of: task), size: 26)
                        Text(agents.name(of: task)).font(.subheadline.weight(.semibold))
                        TaskStatusPill(task: task)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    if task.isRunning {
                        if let progress = thread?.progress {
                            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                                .tint(Brand.amber)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if task.status == "paused" {
                                Image(systemName: "pause.fill").foregroundStyle(.yellow)
                            } else {
                                CabooseWheel(motion: .rolling).frame(width: 14, height: 14)
                            }
                            Text(thread?.activity ?? lines.last?.text ?? agents.output[task.id]?.last?.text ?? "Getting started…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .contentTransition(.opacity)
                        }
                    } else if let summary = task.summary, !summary.isEmpty, task.signIn?.isEmpty != false {
                        Text(Markdown.inline(summary))
                            .font(.callout)
                            .lineLimit(8)
                            .multilineTextAlignment(.leading)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let approval = task.pendingApproval {
                ApprovalRow(task: task, approval: approval)
            }
            // A signed-out agent: sign in on the computer's screen, use a key, or hand the request to another model.
            if let methods = task.signIn, !methods.isEmpty, !task.isRunning {
                SignInRow(task: task, methods: methods, connectModel: connectModel)
            }
        }
        .padding(14)
        .glassEffect(.regular.tint(task.pendingApproval != nil ? Color.yellow.opacity(0.10) : .clear), in: .rect(cornerRadius: 22))
        .animation(.snappy, value: task.status)
    }
}

/// Markdown as SwiftUI `Text` draws it: inline styles and links, line breaks kept.
enum Markdown {
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
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

/// What to do about a task whose agent was signed out: sign in on the computer's screen, give
/// it a key, or run the same request with another agent or model.
struct SignInRow: View {
    @Environment(AppModel.self) private var model
    let task: AgentCenter.Task
    let methods: [SignInMethod]
    var connectModel: () -> Void = {}
    @State private var started: String?

    var body: some View {
        let agents = model.agents
        let others = agents.installedAgents.filter { $0.id != task.agent }
        VStack(alignment: .leading, spacing: 8) {
            Label("\(agents.name(of: task)) isn't signed in on your computer.", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(methods) { method in
                        Button {
                            Task {
                                do {
                                    try await agents.signIn(task.agent, with: method)
                                    started = "Finish signing in on your computer's screen, then reply to try again."
                                } catch {
                                    started = error.localizedDescription
                                }
                            }
                        } label: {
                            Label(methods.count == 1 ? "Sign In" : method.name, systemImage: method.type == "terminal" ? "terminal" : "person.badge.key")
                        }
                        .buttonStyle(.glass)
                    }
                    Button(action: connectModel) { Label("Use Another Model", systemImage: "key") }
                        .buttonStyle(.glassProminent)
                    if !others.isEmpty {
                        Menu {
                            ForEach(others) { agent in
                                Button(agent.name) { Task { await agents.retry(task, with: agent.id) } }
                            }
                        } label: {
                            Label("Ask Another Agent", systemImage: "arrow.triangle.branch")
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
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
    @AppStorage(AskTarget.key) private var agent = ""
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
