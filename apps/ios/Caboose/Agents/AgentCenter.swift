import CabooseKit
import Foundation
import Observation
import UIKit

/// Agent tasks on the computer and the live control channel that reports them.
@MainActor @Observable
final class AgentCenter {
    struct Task: Identifiable, Decodable, Equatable {
        var id: String
        var agent: String
        var prompt: String
        var status: String
        var startedAt: String?
        var finishedAt: String?
        var summary: String?

        var isRunning: Bool { status == "running" || status == "queued" || status == "paused" }
    }

    struct Line: Identifiable, Equatable {
        let id = UUID()
        var kind: String
        var text: String
    }

    private(set) var tasks: [Task] = []
    private(set) var output: [String: [Line]] = [:]
    private(set) var available = true
    var lastError: String?

    /// The computer's management status, whenever the host reports a change on the control socket.
    var onComputer: ((HostClient.ComputerStatus) -> Void)?

    private var control: URLSessionWebSocketTask?
    private var host: HostClient?

    /// The agent seat: a second display where agents run GUI apps without touching yours.
    private(set) var seat: XpraSession?

    func attach(host: HostClient) {
        self.host = host
        openControl()
        Swift.Task { await refresh() }
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
        available = true
    }

    func refresh() async {
        guard let host else { return }
        do {
            tasks = try await host.agentTasks()
            available = true
            if !tasks.isEmpty { openSeatIfNeeded() }
        } catch HostClient.Failure.server(404, _) {
            available = false // a host without the agents API
        } catch {
            lastError = error.localizedDescription
        }
    }

    func ask(_ prompt: String, agent: String) async {
        guard let host, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let id = try await host.startAgentTask(prompt: prompt, agent: agent)
            tasks.insert(Task(id: id, agent: agent, prompt: prompt, status: "running", startedAt: nil, finishedAt: nil, summary: nil), at: 0)
            openSeatIfNeeded()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } catch {
            lastError = error.localizedDescription
        }
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
        var request = URLRequest(url: host.socketURL("/v1/control"))
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
            return
        }
        guard let id = event["id"] as? String else { return }
        switch type {
        case "agent.task.started":
            if !tasks.contains(where: { $0.id == id }) {
                tasks.insert(Task(id: id, agent: event["agent"] as? String ?? "agent", prompt: event["prompt"] as? String ?? "",
                                  status: "running", startedAt: nil, finishedAt: nil, summary: nil), at: 0)
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
                notifyFinished(tasks[index])
            }
        default:
            break
        }
    }

    private func notifyFinished(_ task: Task) {
        UINotificationFeedbackGenerator().notificationOccurred(task.status == "succeeded" ? .success : .error)
    }
}

extension HostClient {
    func agentTasks() async throws -> [AgentCenter.Task] { try await request("GET", "/v1/agent/tasks", timeout: 20) }

    func startAgentTask(prompt: String, agent: String) async throws -> String {
        struct Started: Decodable { var id: String }
        let started: Started = try await request("POST", "/v1/agent/tasks", body: ["prompt": .string(prompt), "agent": .string(agent)], timeout: 30)
        return started.id
    }

    func cancelAgentTask(_ id: String) async throws {
        let _: [String: Bool] = try await request("POST", "/v1/agent/tasks/\(id)/cancel", timeout: 20)
    }

    func holdAgentTask(_ id: String, paused: Bool) async throws {
        let _: [String: Bool] = try await request("POST", "/v1/agent/tasks/\(id)/\(paused ? "pause" : "resume")", timeout: 20)
    }
}
