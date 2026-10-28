import CabooseKit
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation

/// The agent a new chat goes to.
enum AskTarget {
    /// The storage key: "" for the default agent, else an agent's registry id.
    static let key = "caboose.agent.target"
}

/// The chat composer. In a new chat it picks the agent; in a chat it talks to that chat's
/// agent, and while the agent works, what you send waits for its turn to end.
struct ChatComposer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let task: AgentCenter.Task?
    var connectModel: () -> Void = {}
    @AppStorage(AskTarget.key) private var target = ""
    @AppStorage("caboose.agent.askFirst") private var askFirst = true
    @AppStorage("caboose.agent.craftMcp") private var craftMcp = true
    @State private var photos: [PhotosPickerItem] = []
    @State private var showingPhotos = false
    @State private var showingFiles = false
    @State private var showingCamera = false
    @State private var dictation = AgentDictation()
    @State private var focused = false

    private var draft: AgentComposerDraft { model.agents.composerDraft(for: task?.id) }
    private var chosen: AgentListing? { model.agents.listing(target).flatMap { $0.isInstalled ? $0 : nil } }
    private var name: String {
        task.map { model.agents.name(of: $0) } ?? model.agents.library.selectedProfile?.name ?? chosen?.name
            ?? model.agents.defaultAgent.flatMap { model.agents.listing($0)?.name } ?? "Your agent"
    }

    var body: some View {
        @Bindable var draft = draft
        VStack(alignment: .leading, spacing: 10) {
            if let error = draft.error ?? dictation.error {
                HStack(alignment: .top) {
                    Text(error).font(.caption).foregroundStyle(.orange)
                    Spacer(minLength: 0)
                    Button("Dismiss", systemImage: "xmark") { draft.error = nil; dictation.error = nil }
                        .labelStyle(.iconOnly).font(.caption)
                }
                .padding(.horizontal, 8)
                .accessibilityElement(children: .contain)
            }
            attachmentTray
            if dictation.listening {
                Label("Listening… Tap the microphone to finish.", systemImage: "waveform")
                    .font(.caption).foregroundStyle(Brand.amber)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            inputField
            controls

        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .padding(.horizontal, 14).padding(.bottom, 8)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .photosPicker(isPresented: $showingPhotos, selection: $photos, maxSelectionCount: max(1, 4 - draft.files.count), matching: .images)
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.data, .content], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): for url in urls { draft.add(url) }
            case .failure(let error): draft.error = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingCamera) {
            AgentCamera { image in
                if let data = image.jpegData(compressionQuality: 0.85) { draft.add(name: "Camera-\(UUID().uuidString.prefix(6)).jpg", type: "image/jpeg", data: data) }
                else { draft.error = "Could not read this photo." }
            }.ignoresSafeArea()
        }
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            let destination = draft
            destination.importing = true
            Task {
                defer { destination.importing = false; photos = [] }
                for item in items {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadCorruptFile) }
                        let type = item.supportedContentTypes.first(where: { $0.conforms(to: .image) }) ?? .image
                        destination.add(name: "Photo-\(UUID().uuidString.prefix(6)).\(type.preferredFilenameExtension ?? "jpg")",
                                        type: type.preferredMIMEType ?? "image/jpeg", data: data)
                    } catch { destination.error = error.localizedDescription }
                }
            }
        }
        .onAppear { if model.askFocusRequested { focused = true; model.askFocusRequested = false } }
        .onChange(of: model.askFocusRequested) { _, requested in
            if requested { focused = true; model.askFocusRequested = false }
        }
        .onChange(of: model.agents.draft, initial: true) { _, suggestion in
            guard let suggestion else { return }
            draft.text = suggestion; focused = true; model.agents.draft = nil
        }
        .onDisappear { focused = false; dictation.stop() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { dictation.stop() } }
        .onChange(of: model.phase) { _, phase in if phase != .ready { dictation.stop() } }
    }

    @ViewBuilder private var attachmentTray: some View {
        if !draft.files.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(draft.files) { file in
                            HStack(spacing: 8) {
                                if let image = file.thumbnail {
                                    Image(uiImage: image).resizable().scaledToFill().frame(width: 36, height: 36).clipShape(.rect(cornerRadius: 7))
                                } else { Image(systemName: "doc.fill").foregroundStyle(Brand.amber) }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.attachment.name).font(.caption.weight(.medium)).lineLimit(1)
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.attachment.data.count), countStyle: .file)).font(.caption2).foregroundStyle(.secondary)
                                }.frame(maxWidth: 140, alignment: .leading)
                                Button { draft.files.removeAll { $0.id == file.id } } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }.accessibilityLabel("Remove \(file.attachment.name)")
                            }
                            .padding(8).background(.white.opacity(0.06), in: .rect(cornerRadius: 12))
                        }
                    }
                }.scrollIndicators(.hidden)
            }
    }

    private var inputField: some View {
        @Bindable var draft = draft
        return
            NativeTextInput("Message \(name)…", text: $draft.text, focus: $focused, lines: 1...7, submit: send)
                .padding(.horizontal, 5).padding(.top, 3)
                .disabled(dictation.listening || draft.sending)
    }

    private var controls: some View {
            HStack(spacing: 12) {
                attachmentMenu
                agentMenu
                Spacer(minLength: 0)
                if draft.importing { ProgressView().controlSize(.small) }
                Button(action: toggleDictation) {
                    Image(systemName: dictation.listening ? "waveform.circle.fill" : "mic")
                        .font(.body.weight(.medium)).foregroundStyle(dictation.listening ? Brand.amber : .secondary)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel(dictation.listening ? "Finish Dictation" : "Dictate Message")
                .disabled(dictation.requesting || draft.importing)
                if draft.sending {
                    ProgressView().frame(width: 36, height: 36)
                } else if let task, task.isRunning, draft.text.isEmpty, draft.files.isEmpty {
                    Button { Task { await model.agents.cancel(task) } } label: {
                        Image(systemName: "stop.fill").font(.body.weight(.bold)).frame(width: 36, height: 36)
                    }
                    .buttonStyle(.glass).buttonBorderShape(.circle).accessibilityLabel("Stop Agent")
                } else {
                    Button(action: send) {
                        Image(systemName: task?.isRunning == true ? "arrow.up.to.line" : "arrow.up")
                            .font(.body.weight(.bold)).frame(width: 36, height: 36)
                    }
                    .buttonStyle(.glassProminent).buttonBorderShape(.circle)
                    .disabled((draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.files.isEmpty) || draft.importing)
                    .accessibilityLabel(task?.isRunning == true ? "Queue Message" : "Send Message")
                }
            }
            .disabled(draft.sending)    }

    private var attachmentMenu: some View {
        Menu {
            Button("Photo Library", systemImage: "photo.on.rectangle") { showingPhotos = true }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take Photo", systemImage: "camera") {
                    Task {
                        if await AVCaptureDevice.requestAccess(for: .video) { showingCamera = true }
                        else { draft.error = "Enable Camera for Caboose in Settings to take a photo." }
                    }
                }
            }
            Button("Choose Files", systemImage: "folder") { showingFiles = true }
        } label: { Image(systemName: "plus").font(.body.weight(.medium)).frame(width: 32, height: 36) }
        .accessibilityLabel("Add Attachments")
        .disabled(draft.files.count >= 4 || draft.importing || dictation.listening)
    }

    private var agentMenu: some View {
        let agents = model.agents
        return Menu {
            if let task {
                let others = agents.installedAgents.filter { $0.id != task.agent }
                if !others.isEmpty {
                    Menu("Ask Another Agent", systemImage: "arrow.triangle.branch") {
                        ForEach(others) { agent in Button(agent.name) { Task { await agents.retry(task, with: agent.id) } } }
                    }
                }
            } else {
                Section("Teammate") {
                    ForEach(agents.library.activeProfiles) { profile in
                        Button(profile.name, systemImage: agents.library.selectedProfileId == profile.id ? "checkmark.circle.fill" : "person.crop.circle") { agents.library.selectedProfileId = profile.id }
                    }
                    Button("Without a Teammate") { agents.library.selectedProfileId = nil }
                }
                if let profile = agents.library.selectedProfile {
                    Section("Teammate Settings") {
                        Text(agents.listing(profile.agent)?.name ?? profile.agent)
                        Text(profile.approvals == "ask" ? "Ask before acting" : "Automatic approvals")
                    }
                } else {
                    Picker("Agent", selection: $target) {
                        Text("Default Agent").tag("")
                        ForEach(agents.installedAgents) { Text($0.name).tag($0.id) }
                    }
                    Toggle(isOn: $askFirst) { Label("Ask Before Acting", systemImage: "hand.raised") }
                    Toggle(isOn: $craftMcp) { Label("Use Craft App Tools", systemImage: "wrench.and.screwdriver") }
                }
            }
            Section {
                Button(action: connectModel) { Label("Connect a Model…", systemImage: "key") }
                Button { model.showAgentSettings = true } label: { Label("Agent Settings", systemImage: "slider.horizontal.3") }
            }
        } label: {
            HStack(spacing: 6) {
                AgentAvatar(name: name, size: 23)
                Text(name).font(.caption.weight(.semibold)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("Agent: \(name)")
    }

    private func toggleDictation() {
        if dictation.listening { dictation.stop(); return }
        focused = false
        let destination = draft
        let prefix = destination.text.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await dictation.start { destination.text = prefix + (prefix.isEmpty ? "" : " ") + $0 } }
    }

    private func send() {
        let destination = draft
        guard !destination.sending, !destination.importing else { return }
        dictation.stop()
        let text = destination.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = destination.files.map(\.attachment)
        guard !text.isEmpty || !files.isEmpty else { return }
        let prompt = text.isEmpty ? "Please look at the attached files." : text
        let agents = model.agents
        let revision = agents.chatRevision
        let agent = chosen?.id
        let profileId = agents.library.selectedProfileId
        focused = false
        model.askFocusRequested = false
        destination.sending = true
        destination.error = nil
        Task {
            defer { destination.sending = false }
            let success: Bool
            if let task { success = await agents.reply(to: task, prompt, attachments: files) }
            else if let id = await agents.start(prompt, agent: agent, askFirst: askFirst, attachments: files, profileId: profileId) {
                if agents.chatRevision == revision { agents.currentChat = id }
                success = true
            } else { success = false }
            if success { destination.text = ""; destination.files = [] }
            else { destination.error = agents.lastError ?? "Your message could not be sent. Try again." }
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

/// What to do about a task whose agent was signed out: sign in from the phone, give it a key,
/// or run the same request with another agent or model.
struct SignInRow: View {
    @Environment(AppModel.self) private var model
    let task: AgentCenter.Task
    let methods: [SignInMethod]
    var connectModel: () -> Void = {}
    @State private var signingIn: SignInMethod?
    @State private var signedIn = false

    var body: some View {
        let agents = model.agents
        let others = agents.installedAgents.filter { $0.id != task.agent }
        VStack(alignment: .leading, spacing: 8) {
            Label("\(agents.name(of: task)) isn't signed in on your computer.", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                if methods.count == 1, let method = methods.first {
                    Button { signingIn = method } label: { Label("Sign In", systemImage: "person.badge.key") }
                        .buttonStyle(.glassProminent)
                } else {
                    Menu {
                        ForEach(methods) { method in
                            Button(method.name, systemImage: method.type == "terminal" ? "terminal" : "person.badge.key") { signingIn = method }
                        }
                    } label: { Label("Sign In", systemImage: "person.badge.key") }
                    .buttonStyle(.glassProminent)
                }
                Menu {
                    ForEach(others) { agent in
                        Button(agent.name) { Task { await agents.retry(task, with: agent.id) } }
                    }
                    Section { Button("Use Another Model…", systemImage: "key", action: connectModel) }
                } label: {
                    Label("Ask Another", systemImage: "arrow.triangle.branch")
                }
                .buttonStyle(.glass)
            }
            .controlSize(.small)
            .font(.caption.weight(.semibold))
            if signedIn { Text("Signed in. Reply to try again.").font(.caption).foregroundStyle(.secondary) }
        }
        .sheet(item: $signingIn) { method in
            AgentSignInView(agentID: task.agent, method: method) { signedIn = true }
                .environment(model)
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
    @State private var focused = false

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
                    NativeTextInput("What should the agent do with it?", text: $prompt, focus: $focused, lines: 3...8)
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
