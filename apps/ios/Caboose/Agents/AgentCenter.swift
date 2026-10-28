import CabooseKit
import Foundation
import Observation
import UIKit

/// Agent tasks on the computer and the live control channel that reports them.
@MainActor @Observable
final class AgentCenter {
    struct Task: Identifiable, Decodable, Equatable {
        var id: String
        /// The agent's registry id.
        var agent: String
        var agentName: String?
        var profileId: String?
        var prompt: String
        var status: String
        var startedAt: String?
        var finishedAt: String?
        var summary: String?
        var turns: Int?
        var approvals: String?
        var pendingApproval: Approval?
        /// How to sign in, when the task stopped because its agent was signed out.
        var signIn: [SignInMethod]?
        /// Replies waiting for the agent's turn to end; they go to it together as its next turn.
        var queued: [String]?
        var queuedAttachments: [[String]]?
        var draft: AgentDraft?

        var isRunning: Bool { status == "running" || status == "queued" || status == "paused" }
    }

    /// The agent is waiting for the owner to allow or deny one action.
    struct Approval: Identifiable, Decodable, Equatable {
        struct Option: Identifiable, Decodable, Equatable {
            var id: String
            var name: String
            /// ACP: allow_once, allow_always, reject_once or reject_always.
            var kind: String
            var allows: Bool { kind.hasPrefix("allow") }
        }
        var id: String
        var tool: String
        var summary: String
        var options: [Option]?
    }

    typealias Attachment = AgentAttachment

    struct Line: Identifiable, Equatable {
        let id = UUID()
        var kind: String
        var text: String
    }

    let library = AgentLibrary()
    private(set) var tasks: [Task] = []
    /// Each task's conversation as far as it is known: read from the host when opened, then live.
    private(set) var threads: [String: AgentThread] = [:]
    /// The chat the Agents tab shows: a task, whose turns are the conversation. Nil for a new chat.
    var currentChat: String? = UserDefaults.standard.string(forKey: AgentCenter.chatKey) {
        didSet { UserDefaults.standard.set(currentChat, forKey: Self.chatKey); chatRevision += 1 }
    }
    private(set) var chatRevision = 0
    private var composerDrafts: [String: AgentComposerDraft] = [:]
    func composerDraft(for id: String?) -> AgentComposerDraft {
        let key = id ?? "new"
        if let existing = composerDrafts[key] { return existing }
        let draft = AgentComposerDraft()
        composerDrafts[key] = draft
        return draft
    }

    /// Short names for chats, by task id, written by the iPhone's model where it has one.
    private(set) var titles: [String: String] = UserDefaults.standard.dictionary(forKey: AgentCenter.titlesKey) as? [String: String] ?? [:]
    /// A chat to show, asked for from elsewhere in the app (Home, a notification); the Agents tab opens it.
    var focusedTask: String?
    /// Text for the composer to take, from a suggestion.
    var draft: String?
    /// The registry's agents as this computer sees them, installed first.
    private(set) var catalog: [AgentListing] = []
    private(set) var defaultAgent: String?
    private(set) var registryError: String?
    /// Agents being installed now.
    private(set) var installing: Set<String> = []
    private static let chatKey = "caboose.agent.chat"
    private static let titlesKey = "caboose.agent.titles"
    private(set) var output: [String: [Line]] = [:]
    private(set) var available = true
    private(set) var tasksError: String?
    var lastError: String?

    /// The computer's management status, whenever the host reports a change on the control socket.
    var onComputer: ((HostClient.ComputerStatus) -> Void)?
    /// Other control-socket events (`media.*`), for whoever handles them.
    var onEvent: ((String, [String: Any]) -> Void)?

    private var attached = false
    private var control: URLSessionWebSocketTask?
    private var host: HostClient?

    /// The agent seat: a second display where agents run GUI apps without touching yours.
    private(set) var seat: CabooseDisplaySession?

    func attach(host: HostClient) {
        self.host = host
        library.attach(host)
        attached = true
        openControl()
        Swift.Task { await refresh() }
        Swift.Task { await refreshAgents() }
    }

    func detach() {
        attached = false
        control?.cancel(with: .goingAway, reason: nil)
        control = nil
        seat?.disconnect()
        seat = nil
    }

    /// Forgets the computer entirely: a different one, or none, is next.
    func reset() {
        library.reset()
        tookOver = false
        pausedForTakeover = []
        detach()
        host = nil
        seatToken = nil
        tasks = []
        tasksError = nil
        output = [:]
        threads = [:]
        composerDrafts = [:]
        catalog = []
        defaultAgent = nil
        currentChat = nil
        titles = [:]
        UserDefaults.standard.removeObject(forKey: Self.titlesKey)
        available = true
    }

    func refresh() async {
        guard let host else { return }
        do {
            tasks = try await host.agentTasks()
            tasksError = nil
            LiveActivityCoordinator.shared.sync(tasks)
            available = true
            if !tasks.isEmpty { openSeatIfNeeded() }
        } catch HostClient.Failure.server(404, _) {
            available = false // a host without the agents API
            tasksError = "Update caboose-host to list conversations."
        } catch {
            tasksError = error.localizedDescription
            lastError = error.localizedDescription
        }
    }

    /// Tasks waiting on the owner, oldest first.
    var awaitingApproval: [Task] { tasks.filter { $0.pendingApproval != nil }.reversed() }

    /// Starts a task with agent `agent` (a registry id), or the owner's default agent when nil.
    @discardableResult
    func ask(_ prompt: String, agent: String?, askFirst: Bool = false, attachments: [Attachment] = []) async -> Bool {
        await start(prompt, agent: agent, askFirst: askFirst, attachments: attachments) != nil
    }

    /// Starts a task and returns its id, or nil when it could not start (`lastError` says why).
    func start(_ prompt: String, agent: String?, askFirst: Bool = false, attachments: [Attachment] = [], profileId: String? = nil) async -> String? {
        guard let host, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let approvals = askFirst ? "ask" : "auto"
        do {
            let id: String
            if let profileId {
                id = try await host.startProfileTask(profileId, prompt: prompt, attachments: attachments)
            } else {
                id = try await host.startAgentTask(prompt: prompt, agent: agent, approvals: approvals, attachments: attachments, craftMcp: UserDefaults.standard.object(forKey: "caboose.agent.craftMcp") as? Bool ?? true)
            }
            if !tasks.contains(where: { $0.id == id }) {
                let profile = library.profiles.first { $0.id == profileId }
                let chosen = profile?.agent ?? agent ?? defaultAgent ?? ""
                tasks.insert(Task(id: id, agent: chosen, agentName: listing(chosen)?.name, profileId: profileId, prompt: prompt, status: "running",
                                  startedAt: Self.timestamp(Date()), turns: 1, approvals: profile?.approvals ?? approvals), at: 0)
            }
            if threads[id] == nil { threads[id] = AgentThread(entries: [], prompt: prompt) }
            nameChat(id, from: prompt)
            openSeatIfNeeded()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            return id
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Says something in the current chat: its next turn, or, while the agent is working, a
    /// reply that waits for the turn to end. With no chat it starts one with `agent` (the
    /// default agent when nil).
    func say(_ text: String, agent: String?, askFirst: Bool) async {
        if let id = currentChat, let task = tasks.first(where: { $0.id == id }) {
            await reply(to: task, text)
        } else if let id = await start(text, agent: agent, askFirst: askFirst) {
            currentChat = id
        }
    }

    /// Stops the agent's turn and sends what was waiting right away.
    func sendNow(_ task: Task) async {
        guard let host else { return }
        do { replace(try await host.sendQueuedAgentReplies(task.id)) }
        catch { lastError = error.localizedDescription }
    }

    /// Asks another agent the chat's last request, in a new chat, and shows it.
    func retry(_ task: Task, with agent: String?) async {
        let last = threads[task.id]?.lastTurn?.prompt ?? ""
        let prompt = last.isEmpty ? task.prompt : last
        if let id = await start(prompt, agent: agent, askFirst: task.approvals == "ask") { currentChat = id }
    }

    /// What to call a chat in the list.
    func title(of task: Task) -> String {
        titles[task.id] ?? task.prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? task.prompt
    }

    /// Names a new chat from its first message with the iPhone's own model, when it has one.
    private func nameChat(_ id: String, from prompt: String) {
        Swift.Task {
            guard let title = await ChatTitler.title(for: prompt) else { return }
            titles[id] = title
            let kept = Set(tasks.map(\.id))
            titles = titles.filter { kept.contains($0.key) || $0.key == id }
            UserDefaults.standard.set(titles, forKey: Self.titlesKey)
        }
    }

    // MARK: Threads

    /// Reads a task's whole conversation from the host. Live entries that arrive meanwhile are kept.
    func loadThread(_ id: String) async {
        guard let host, let task = tasks.first(where: { $0.id == id }), !loadingThreads.contains(id) else { return }
        loadingThreads.insert(id)
        pendingEntries[id] = []
        defer { loadingThreads.remove(id); pendingEntries[id] = nil }
        do {
            let read = try await host.agentTranscript(id)
            var thread = AgentThread(entries: read.entries, prompt: task.prompt, truncated: read.truncated)
            let recent = read.entries.suffix(64)
            for entry in pendingEntries[id] ?? [] where !recent.contains(entry) { thread.append(entry) }
            threads[id] = thread
        } catch {
            // A parked computer or an older host: the live entries and the task's summary stand in.
            if threads[id] == nil { threads[id] = AgentThread(entries: [], prompt: task.prompt) }
        }
    }

    func isLoading(_ id: String) -> Bool { loadingThreads.contains(id) }

    private var loadingThreads: Set<String> = []
    private var pendingEntries: [String: [TranscriptEntry]] = [:]

    private func record(_ entry: TranscriptEntry, for id: String) {
        if loadingThreads.contains(id) { pendingEntries[id, default: []].append(entry) }
        if threads[id] == nil, let task = tasks.first(where: { $0.id == id }) { threads[id] = AgentThread(entries: [], prompt: task.prompt) }
        threads[id]?.append(entry)
    }

    static func timestamp(_ date: Date) -> String { date.formatted(.iso8601) }

    /// When a task started, from the host's ISO time.
    static func started(_ task: Task) -> Date? {
        guard let value = task.startedAt else { return nil }
        return (try? Date(value, strategy: .iso8601)) ?? (try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }

    // MARK: Agents

    func refreshAgents() async {
        guard let host else { return }
        do {
            let response = try await host.agents()
            catalog = response.agents.sorted { rank($0) < rank($1) }
            defaultAgent = response.defaultAgent
            registryError = response.registry.error
        } catch HostClient.Failure.server(404, _) {
            catalog = [] // a host from before the registry
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func rank(_ agent: AgentListing) -> Int { agent.id == defaultAgent ? 0 : agent.isInstalled ? 1 : 2 }

    func listing(_ id: String) -> AgentListing? { catalog.first { $0.id == id } }

    /// What to call a task's agent.
    func name(of task: Task) -> String { task.agentName ?? listing(task.agent)?.name ?? (task.agent.isEmpty ? "The agent" : task.agent) }

    var installedAgents: [AgentListing] { catalog.filter(\.isInstalled) }

    func install(_ agent: AgentListing) async throws {
        guard let host else { return }
        installing.insert(agent.id)
        defer { installing.remove(agent.id) }
        _ = try await host.installAgent(agent.id)
        await refreshAgents()
    }

    func signIn(_ agentID: String, with method: SignInMethod) async throws {
        guard let host else { return }
        try await host.signInAgent(agentID, method: method.id)
        await refreshAgents()
    }

    func setEnv(_ agentID: String, set: [String: String] = [:], remove: [String] = []) async throws {
        guard let host else { return }
        _ = try await host.setAgentEnv(agentID, set: set, remove: remove)
        await refreshAgents()
    }

    /// Connects a model provider with the owner's key: installs the agent that runs it if needed,
    /// gives it the key (and the model), and makes it the default agent.
    func connect(_ provider: ModelProvider, key: String, model: String?, progress: (String) -> Void) async throws {
        guard let host else { throw HostClient.Failure.server(409, "Connect to your computer first.") }
        if catalog.isEmpty { await refreshAgents() }
        guard let agent = listing(provider.agent) else {
            throw HostClient.Failure.server(404, "\(provider.name) needs \(provider.agent) from the agent registry, which this computer cannot see yet.")
        }
        if !agent.isInstalled {
            progress("Installing \(agent.name) on your computer…")
            try await install(agent)
        }
        progress("Saving your key in your computer…")
        _ = try await host.setAgentEnv(agent.id, set: provider.environment(key: key, model: model))
        progress("Making \(agent.name) the default…")
        _ = try await host.updateSettings(["defaultAgent": .string(agent.id)])
        await refreshAgents()
    }

    func makeDefault(_ agentID: String) async throws {
        guard let host else { return }
        _ = try await host.updateSettings(["defaultAgent": .string(agentID)])
        await refreshAgents()
    }

    /// Continues a chat: the next turn, or, while the agent is working, a reply that waits for it.
    @discardableResult
    func reply(to task: Task, _ prompt: String, attachments: [Attachment] = []) async -> Bool {
        guard let host, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        do {
            let updated = try await host.replyToAgentTask(task.id, prompt: prompt, attachments: attachments)
            let started = (updated.turns ?? 1) > (tasks.first { $0.id == task.id }?.turns ?? task.turns ?? 1)
            replace(updated)
            if started {
                output[task.id, default: []].append(Line(kind: "prompt", text: prompt))
                threads[task.id]?.begin(turn: updated.turns ?? 1, prompt: prompt)
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Answers the task's waiting request: allow or deny, or one of the agent's own options.
    func decide(_ task: Task, allow: Bool, option: Approval.Option? = nil) async {
        guard let host, let approval = task.pendingApproval else { return }
        do {
            try await host.decideAgentApproval(task.id, request: approval.id, allow: option?.allows ?? allow, option: option?.id)
            clearApproval(task.id, approval.id)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func replace(_ task: Task) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index] = task } else { tasks.insert(task, at: 0) }
    }

    private func clearApproval(_ id: String, _ requestID: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].pendingApproval?.id == requestID else { return }
        tasks[index].pendingApproval = nil
    }

    func cancel(_ task: Task) async {
        guard let host else { return }
        do {
            try await host.cancelAgentTask(task.id)
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index].status = "cancelled"
                tasks[index].draft = nil
                tasks[index].queued = nil
                tasks[index].queuedAttachments = nil
            }
        } catch { lastError = error.localizedDescription }
    }

    /// The owner is driving the agent seat: running agents are stopped so the two never
    /// type into the same app at once.
    private(set) var tookOver = false
    private var takeoverChanging = false
    private var pausedForTakeover: Set<String> = []

    func takeOver() async {
        guard let host, !tookOver, !takeoverChanging else { return }
        takeoverChanging = true
        defer { takeoverChanging = false }
        do {
            for task in tasks where task.status == "running" {
                try await host.holdAgentTask(task.id, paused: true)
                pausedForTakeover.insert(task.id)
            }
            tookOver = true
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        } catch {
            lastError = error.localizedDescription
            for id in pausedForTakeover {
                do { try await host.holdAgentTask(id, paused: false); pausedForTakeover.remove(id) }
                catch { lastError = error.localizedDescription }
            }
        }
    }

    func handBack() async {
        guard let host, !takeoverChanging else { return }
        takeoverChanging = true
        defer { takeoverChanging = false }
        for id in pausedForTakeover {
            do { try await host.holdAgentTask(id, paused: false); pausedForTakeover.remove(id) }
            catch { lastError = error.localizedDescription }
        }
        tookOver = !pausedForTakeover.isEmpty
    }

    /// Remembers how to reach the agent seat. The seat's display only starts once an agent is
    /// in use, so a computer nobody delegates to never runs a second display.
    func prepareSeat(displayToken: String, capabilities: ClientCapabilities) {
        seatToken = (displayToken, capabilities)
        if !tasks.isEmpty { openSeatIfNeeded() }
    }

    private var seatToken: (String, ClientCapabilities)?

    private func openSeatIfNeeded() {
        if let (token, capabilities) = seatToken { openSeat(displayToken: token, capabilities: capabilities) }
    }

    /// Opens the agent seat's display so its windows can be watched and taken over.
    func openSeat(displayToken: String, capabilities: ClientCapabilities) {
        guard let host, seat == nil else { return }
        var url = URLComponents(url: host.socketURL("/v1/display"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "seat", value: "agent")]
        let session = CabooseDisplaySession(displayURL: url.url!, token: host.token, password: displayToken, capabilities: capabilities)
        session.playsAudio = false // one stream of sound: the owner's display
        seat = session
        session.connect()
    }

    // MARK: Control channel

    private func openControl() {
        guard attached, let host, control == nil else { return }
        var components = URLComponents(url: host.socketURL("/v1/control"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "foreground", value: "1"), URLQueryItem(name: "phone", value: "1")]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(host.token)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        control = task
        task.resume()
        receive(on: task)
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Swift.Task { @MainActor in
                guard let self, self.control === task else { return }
                switch result {
                case .failure:
                    self.control = nil
                    try? await Swift.Task.sleep(for: .seconds(3))
                    guard self.attached else { return }
                    self.openControl()
                    await self.refresh()
                    if let id = self.currentChat { await self.loadThread(id) }
                case .success(let message):
                    if case .string(let text) = message { self.handle(text) }
                    if case .data(let data) = message, let text = String(data: data, encoding: .utf8) { self.handle(text) }
                    self.receive(on: task)
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }
        if type == "computer.settings", let computer = event["computer"],
           let body = try? JSONSerialization.data(withJSONObject: computer),
           let status = try? JSONDecoder().decode(HostClient.ComputerStatus.self, from: body) {
            onComputer?(status)
            // The default agent is a computer setting; another device may have changed it.
            let chosen = ((computer as? [String: Any])?["settings"] as? [String: Any])?["defaultAgent"] as? String
            if chosen != defaultAgent { defaultAgent = chosen; catalog.sort { rank($0) < rank($1) } }
            return
        }
        if !type.hasPrefix("agent.") {
            onEvent?(type, event)
            return
        }
        if type == "agent.profiles.changed" { Swift.Task { await library.refreshProfiles() }; return }
        if type == "agent.routines.changed" { Swift.Task { await library.refreshRoutines(); await library.refreshHistory(); await refresh() }; return }
        guard let id = event["id"] as? String else { return }
        switch type {
        case "agent.task.started":
            if !tasks.contains(where: { $0.id == id }) {
                tasks.insert(Task(id: id, agent: event["agent"] as? String ?? "", agentName: event["agentName"] as? String, profileId: event["profileId"] as? String,
                                  prompt: event["prompt"] as? String ?? "", status: "running", startedAt: Self.timestamp(Date()), turns: 1), at: 0)
            }
            openSeatIfNeeded()
        case "agent.task.output":
            output[id, default: []].append(Line(kind: event["kind"] as? String ?? "text", text: event["text"] as? String ?? ""))
        case "agent.task.event":
            if let entry = Self.decode(TranscriptEntry.self, event["entry"]) { record(entry, for: id) }
            return
        case "agent.task.draft":
            if let index = tasks.firstIndex(where: { $0.id == id }) {
                let draft = Self.decode(AgentDraft.self, event["draft"])
                tasks[index].draft = draft?.turn == tasks[index].turns ? draft : nil
            }
        case "agent.task.queued":
            if let index = tasks.firstIndex(where: { $0.id == id }) {
                let queued = event["queued"] as? [String] ?? []
                tasks[index].queued = queued.isEmpty ? nil : queued
                tasks[index].queuedAttachments = event["queuedAttachments"] as? [[String]]
            }
        case "agent.task.paused", "agent.task.resumed":
            if let index = tasks.firstIndex(where: { $0.id == id }) {
                tasks[index].status = type == "agent.task.paused" ? "paused" : "running"
            }
        case "agent.task.finished":
            if let index = tasks.firstIndex(where: { $0.id == id }) {
                tasks[index].status = event["status"] as? String ?? "succeeded"
                tasks[index].summary = event["summary"] as? String
                tasks[index].pendingApproval = nil
                tasks[index].draft = nil
                tasks[index].signIn = Self.decode([SignInMethod].self, event["signIn"])
                notifyFinished(tasks[index])
            }
        case "agent.task.replied":
            if let index = tasks.firstIndex(where: { $0.id == id }) {
                tasks[index].status = "running"
                tasks[index].summary = nil
                tasks[index].draft = nil
                tasks[index].signIn = nil
                tasks[index].turns = event["turn"] as? Int ?? (tasks[index].turns ?? 1) + 1
                let prompt = event["prompt"] as? String ?? ""
                if output[id]?.last?.text != prompt { output[id, default: []].append(Line(kind: "prompt", text: prompt)) }
                threads[id]?.begin(turn: tasks[index].turns ?? 1, prompt: prompt)
            }
            openSeatIfNeeded()
        case "agent.task.approval":
            guard let index = tasks.firstIndex(where: { $0.id == id }),
                  let request = Self.decode(Approval.self, event["request"]) else { break }
            tasks[index].pendingApproval = request
            notifyApproval(tasks[index])
        case "agent.task.approval.resolved":
            if let requestID = event["requestId"] as? String { clearApproval(id, requestID) }
        default:
            break
        }
        LiveActivityCoordinator.shared.sync(tasks)
    }

    /// A JSON value from a control event, decoded as `type`.
    private static func decode<T: Decodable>(_ type: T.Type, _ value: Any?) -> T? {
        guard let value, JSONSerialization.isValidJSONObject(value) || value is [Any],
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func notifyFinished(_ task: Task) {
        UINotificationFeedbackGenerator().notificationOccurred(task.status == "succeeded" ? .success : .error)
    }

    private func notifyApproval(_ task: Task) {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}

extension HostClient {
    func agentTasks() async throws -> [AgentCenter.Task] { try await request("GET", "/v1/agent/tasks", timeout: 20) }

    struct Transcript: Decodable {
        var entries: [TranscriptEntry]
        var truncated: Bool
    }

    /// Every turn of a task's conversation; 409 while the computer is parked.
    func agentTranscript(_ id: String) async throws -> Transcript { try await request("GET", "/v1/agent/tasks/\(id)/transcript", timeout: 30) }

    func replyToAgentTask(_ id: String, prompt: String, attachments: [AgentAttachment] = []) async throws -> AgentCenter.Task {
        struct Replied: Decodable { var task: AgentCenter.Task }
        var body: [String: JSONValue] = ["prompt": .string(prompt)]
        if !attachments.isEmpty { body["attachments"] = .array(attachments.map(\.json)) }
        let replied: Replied = try await request("POST", "/v1/agent/tasks/\(id)/reply", body: body, timeout: 120)
        return replied.task
    }

    func sendQueuedAgentReplies(_ id: String) async throws -> AgentCenter.Task {
        struct Replied: Decodable { var task: AgentCenter.Task }
        let replied: Replied = try await request("POST", "/v1/agent/tasks/\(id)/send-now", timeout: 60)
        return replied.task
    }

    func decideAgentApproval(_ id: String, request requestID: String, allow: Bool, option: String? = nil) async throws {
        var body: [String: JSONValue] = ["allow": .bool(allow)]
        if let option { body["optionId"] = .string(option) }
        let result: [String: Bool] = try await request("POST", "/v1/agent/tasks/\(id)/approvals/\(requestID)", body: body, timeout: 20)
        guard result["resolved"] == true else { throw Failure.server(409, "This approval is no longer waiting for an answer.") }
    }

    func cancelAgentTask(_ id: String) async throws {
        let result: [String: Bool] = try await request("POST", "/v1/agent/tasks/\(id)/cancel", timeout: 20)
        guard result["cancelled"] == true else { throw Failure.server(409, "This agent has already stopped.") }
    }

    func holdAgentTask(_ id: String, paused: Bool) async throws {
        let result: [String: Bool] = try await request("POST", "/v1/agent/tasks/\(id)/\(paused ? "pause" : "resume")", timeout: 20)
        guard result[paused ? "paused" : "resumed"] == true else { throw Failure.server(409, "The agent's state changed. Refresh the conversation and try again.") }
    }
}
