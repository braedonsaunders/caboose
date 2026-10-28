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

        var isRunning: Bool { status == "running" || status == "queued" || status == "paused" }
        /// A finished task's conversation can be continued with a reply.
        var canReply: Bool { !isRunning }
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

    private(set) var tasks: [Task] = []
    /// The registry's agents as this computer sees them, installed first.
    private(set) var catalog: [AgentListing] = []
    private(set) var defaultAgent: String?
    private(set) var registryError: String?
    /// Agents being installed now.
    private(set) var installing: Set<String> = []
    /// Requests the iPhone's own model handled, newest first.
    private(set) var localRuns: [OnDeviceRun] = []
    private(set) var output: [String: [Line]] = [:]
    private(set) var available = true
    var lastError: String?

    /// The computer's management status, whenever the host reports a change on the control socket.
    var onComputer: ((HostClient.ComputerStatus) -> Void)?
    /// Other control-socket events (`media.*`), for whoever handles them.
    var onEvent: ((String, [String: Any]) -> Void)?

    private var control: URLSessionWebSocketTask?
    private var host: HostClient?

    /// The agent seat: a second display where agents run GUI apps without touching yours.
    private(set) var seat: XpraSession?

    func attach(host: HostClient) {
        self.host = host
        openControl()
        Swift.Task { await refresh() }
        Swift.Task { await refreshAgents() }
    }

    func detach() {
        control?.cancel(with: .goingAway, reason: nil)
        control = nil
        seat?.disconnect()
        seat = nil
    }

    /// Forgets the computer entirely: a different one, or none, is next.
    func reset() {
        tookOver = false
        detach()
        host = nil
        seatToken = nil
        tasks = []
        output = [:]
        catalog = []
        defaultAgent = nil
        localRuns = []
        available = true
    }

    func refresh() async {
        guard let host else { return }
        do {
            tasks = try await host.agentTasks()
            LiveActivityCoordinator.shared.sync(tasks)
            available = true
            if !tasks.isEmpty { openSeatIfNeeded() }
        } catch HostClient.Failure.server(404, _) {
            available = false // a host without the agents API
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Tasks waiting on the owner, oldest first.
    var awaitingApproval: [Task] { tasks.filter { $0.pendingApproval != nil }.reversed() }

    /// Starts a task with agent `agent` (a registry id), or the owner's default agent when nil.
    @discardableResult
    func ask(_ prompt: String, agent: String?, askFirst: Bool = false, attachments: [Attachment] = []) async -> Bool {
        guard let host, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let approvals = askFirst ? "ask" : "auto"
        do {
            let id = try await host.startAgentTask(prompt: prompt, agent: agent, approvals: approvals, attachments: attachments, craftMcp: UserDefaults.standard.object(forKey: "caboose.agent.craftMcp") as? Bool ?? true)
            if !tasks.contains(where: { $0.id == id }) {
                let chosen = agent ?? defaultAgent ?? ""
                tasks.insert(Task(id: id, agent: chosen, agentName: listing(chosen)?.name, prompt: prompt, status: "running",
                                  turns: 1, approvals: approvals), at: 0)
            }
            openSeatIfNeeded()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
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

    func makeDefault(_ agentID: String) async throws {
        guard let host else { return }
        _ = try await host.updateSettings(["defaultAgent": .string(agentID)])
        await refreshAgents()
    }

    /// Hands a request to the iPhone's own model; it acts through the host or delegates to `fallback`.
    func askOnDevice(_ prompt: String, delegatingTo fallback: String?) async {
        guard let host, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let run = OnDeviceRun(prompt: prompt)
        localRuns.insert(run, at: 0)
        if localRuns.count > 10 { localRuns.removeLast() }
        await OnDeviceAgent(host: host, center: self, delegate: fallback).run(run)
    }

    func dismiss(_ run: OnDeviceRun) { localRuns.removeAll { $0.id == run.id } }

    /// Continues a finished task's conversation.
    func reply(to task: Task, _ prompt: String) async {
        guard let host, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let updated = try await host.replyToAgentTask(task.id, prompt: prompt)
            replace(updated)
            output[task.id, default: []].append(Line(kind: "prompt", text: prompt))
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } catch {
            lastError = error.localizedDescription
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
        try? await host?.cancelAgentTask(task.id)
    }

    /// The owner is driving the agent seat: running agents are stopped so the two never
    /// type into the same app at once.
    private(set) var tookOver = false

    func takeOver() async {
        guard let host, !tookOver else { return }
        tookOver = true
        for task in tasks where task.status == "running" { try? await host.holdAgentTask(task.id, paused: true) }
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    func handBack() async {
        guard let host, tookOver else { return }
        tookOver = false
        for task in tasks where task.status == "paused" { try? await host.holdAgentTask(task.id, paused: false) }
    }

    /// Remembers how to reach the agent seat. The seat's display server only starts once an
    /// agent is in use, so a computer nobody delegates to never runs a second Xpra.
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
        let session = XpraSession(displayURL: url.url!, token: host.token, password: displayToken, capabilities: capabilities)
        session.playsAudio = false // one stream of sound: the owner's display
        seat = session
        session.connect()
    }

    // MARK: Control channel

    private func openControl() {
        guard let host, control == nil else { return }
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
                    self.openControl()
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
        guard let id = event["id"] as? String else { return }
        switch type {
        case "agent.task.started":
            if !tasks.contains(where: { $0.id == id }) {
                tasks.insert(Task(id: id, agent: event["agent"] as? String ?? "", agentName: event["agentName"] as? String,
                                  prompt: event["prompt"] as? String ?? "", status: "running", turns: 1), at: 0)
            }
            openSeatIfNeeded()
        case "agent.task.output":
            output[id, default: []].append(Line(kind: event["kind"] as? String ?? "text", text: event["text"] as? String ?? ""))
        case "agent.task.paused", "agent.task.resumed":
            if let index = tasks.firstIndex(where: { $0.id == id }) {
                tasks[index].status = type == "agent.task.paused" ? "paused" : "running"
            }
        case "agent.task.finished":
            if let index = tasks.firstIndex(where: { $0.id == id }) {
                tasks[index].status = event["status"] as? String ?? "succeeded"
                tasks[index].summary = event["summary"] as? String
                tasks[index].pendingApproval = nil
                tasks[index].signIn = Self.decode([SignInMethod].self, event["signIn"])
                notifyFinished(tasks[index])
            }
        case "agent.task.replied":
            if let index = tasks.firstIndex(where: { $0.id == id }) {
                tasks[index].status = "running"
                tasks[index].summary = nil
                tasks[index].signIn = nil
                tasks[index].turns = event["turn"] as? Int ?? (tasks[index].turns ?? 1) + 1
                let prompt = event["prompt"] as? String ?? ""
                if output[id]?.last?.text != prompt { output[id, default: []].append(Line(kind: "prompt", text: prompt)) }
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

    func replyToAgentTask(_ id: String, prompt: String) async throws -> AgentCenter.Task {
        struct Replied: Decodable { var task: AgentCenter.Task }
        let replied: Replied = try await request("POST", "/v1/agent/tasks/\(id)/reply", body: ["prompt": .string(prompt)], timeout: 30)
        return replied.task
    }

    func decideAgentApproval(_ id: String, request requestID: String, allow: Bool, option: String? = nil) async throws {
        var body: [String: JSONValue] = ["allow": .bool(allow)]
        if let option { body["optionId"] = .string(option) }
        let result: [String: Bool] = try await request("POST", "/v1/agent/tasks/\(id)/approvals/\(requestID)", body: body, timeout: 20)
        guard result["resolved"] == true else { throw Failure.server(409, "This approval is no longer waiting for an answer.") }
    }

    func cancelAgentTask(_ id: String) async throws {
        let _: [String: Bool] = try await request("POST", "/v1/agent/tasks/\(id)/cancel", timeout: 20)
    }

    func holdAgentTask(_ id: String, paused: Bool) async throws {
        let _: [String: Bool] = try await request("POST", "/v1/agent/tasks/\(id)/\(paused ? "pause" : "resume")", timeout: 20)
    }
}
