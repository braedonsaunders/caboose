import CabooseKit
import Foundation
import FoundationModels
import SwiftUI

/// Apple's on-device Foundation Models model as Caboose's voice: it answers, acts on the
/// computer through the host, and delegates real work to one of the computer's agents
/// (docs/architecture.md § App, On iPhone).
enum OnDeviceAgent {
    static var isAvailable: Bool { SystemLanguageModel.default.availability == .available }

    static func describe(_ error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .exceededContextWindowSize: "That was too much for the on-device model. Try a shorter request, or pick another agent."
        case .guardrailViolation: "The on-device model declined that request."
        case .unsupportedLanguageOrLocale: "The on-device model does not support this language yet."
        default: error.localizedDescription
        }
    }
}

/// One conversation with the on-device model. Its session carries over from message to
/// message, so a follow-up ("and the other one?") has the earlier ones in view; it starts
/// over when its context is full.
@MainActor
final class OnDeviceConversation {
    let host: HostClient
    private weak var center: AgentCenter?
    private var session: LanguageModelSession?
    private var actions: HostActions?

    init(host: HostClient, center: AgentCenter) {
        self.host = host
        self.center = center
    }

    func respond(to id: UUID, prompt: String, delegate: String?, askFirst: Bool) async {
        guard let center else { return }
        let started = Date()
        do {
            let (session, actions) = try await prepared(fresh: false)
            actions.begin(message: id, fallback: delegate, askFirst: askFirst)
            let reply: String
            do {
                reply = try await session.respond(to: prompt, options: GenerationOptions(sampling: .greedy)).content
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                // The conversation outgrew the model's context: start over with this message alone.
                let (fresh, freshActions) = try await prepared(fresh: true)
                freshActions.begin(message: id, fallback: delegate, askFirst: askFirst)
                reply = try await fresh.respond(to: prompt, options: GenerationOptions(sampling: .greedy)).content
            }
            center.updateMessage(id) {
                $0.reply = reply
                $0.status = .done
                $0.seconds = Date().timeIntervalSince(started)
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } catch let error as LanguageModelSession.GenerationError {
            fail(id, OnDeviceAgent.describe(error), started)
        } catch {
            fail(id, error.localizedDescription, started)
        }
    }

    private func fail(_ id: UUID, _ reason: String, _ started: Date) {
        center?.updateMessage(id) {
            $0.reply = reason
            $0.status = .failed
            $0.seconds = Date().timeIntervalSince(started)
        }
    }

    /// The session to use: the running one, or a new one with the computer's current apps and agents.
    private func prepared(fresh: Bool) async throws -> (LanguageModelSession, HostActions) {
        if !fresh, let session, let actions, !session.isResponding { return (session, actions) }
        guard let center else { throw CancellationError() }
        let apps = (try? await host.apps()) ?? []
        let actions = HostActions(host: host, apps: apps, center: center)
        let agents = center.installedAgents.map(\.name)
        let session = LanguageModelSession(
            model: .default, tools: OnDeviceTools.all(actions),
            instructions: OnDeviceTools.instructions(apps: apps.map { OnDeviceTools.describe(app: $0.name, categories: $0.categories) },
                                                     agents: agents.isEmpty ? ["the default agent"] : agents))
        // A message sent while another is still answering gets its own session for now.
        if self.session?.isResponding != true || fresh {
            self.session = session
            self.actions = actions
        }
        return (session, actions)
    }
}

/// Carries out the model's tool calls through the host, noting each on the run.
final class HostActions: ComputerActions, @unchecked Sendable {
    private let host: HostClient
    private let apps: [HostClient.App]
    private let center: AgentCenter
    /// The message being answered, and the agent it hands work to (nil for the default).
    private var message: UUID?
    private var fallback: String?
    private var askFirst = false
    /// What look_at_screen numbered, so click_element can press it.
    private var elements: [HostClient.ScreenElement] = []
    private let lock = NSLock()

    init(host: HostClient, apps: [HostClient.App], center: AgentCenter) {
        self.host = host
        self.apps = apps
        self.center = center
    }

    func begin(message: UUID, fallback: String?, askFirst: Bool) {
        lock.withLock {
            self.message = message
            self.fallback = fallback
            self.askFirst = askFirst
        }
    }

    private func note(_ step: String) async {
        guard let id = lock.withLock({ message }) else { return }
        await MainActor.run { center.updateMessage(id) { $0.steps.append(step) } }
    }

    func status() async throws -> String {
        await note("Checked on the agents")
        return await MainActor.run { center.statusReport() }
    }

    func launch(app name: String) async throws -> String {
        guard let app = Self.match(name, in: apps) else { return "There is no app called \(name). Apps: \(apps.map(\.name).joined(separator: ", "))." }
        await note("Opened \(app.name)")
        try await host.launch(app)
        return "\(app.name) is open and focused."
    }

    func open(url: String) async throws -> String {
        guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? "") else { return "\(url) is not a web address." }
        await note("Opened \(parsed.host() ?? url)")
        try await host.open(parsed)
        return "Opened \(url) in the browser."
    }

    func type(text: String, pressReturn: Bool) async throws -> String {
        await note("Typed “\(text.count > 40 ? text.prefix(40) + "…" : Substring(text))”")
        try await host.typeOnScreen(text)
        if pressReturn { try await host.pressOnScreen("Return") }
        return "Typed."
    }

    func press(keys: String) async throws -> String {
        await note("Pressed \(keys)")
        try await host.pressOnScreen(keys)
        return "Pressed \(keys)."
    }

    func park() async throws -> String {
        await note("Parked the computer")
        try await host.park()
        return "The computer is parking."
    }

    func delegate(task: String, agent: String?) async throws -> String {
        // The agent the user named, among those installed; otherwise the chosen one, or the default.
        let (fallback, askFirst) = lock.withLock { (self.fallback, self.askFirst) }
        let (id, name) = await MainActor.run { () -> (String?, String) in
            let installed = center.installedAgents
            let wanted = agent?.lowercased() ?? ""
            let named = wanted.isEmpty ? nil : installed.first { $0.name.lowercased() == wanted || $0.id == wanted }
                ?? installed.first { $0.name.lowercased().contains(wanted) || $0.id.contains(wanted) }
            let id = named?.id ?? fallback ?? center.defaultAgent
            return (id, id.flatMap { center.listing($0)?.name } ?? "The default agent")
        }
        await note("Handed to \(name)")
        let started = await center.start(task, agent: id, askFirst: askFirst)
        if let started, let message = lock.withLock({ self.message }) {
            await MainActor.run { center.updateMessage(message) { $0.taskID = started } }
        }
        if started != nil { return "\(name) started the task and will report back." }
        let reason = await MainActor.run { center.lastError } ?? ""
        return "\(name) could not start the task. \(reason)"
    }

    func look() async throws -> String {
        let screen = try await host.screenElements()
        let shown = screen.elements.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(60)
        lock.withLock { elements = Array(shown) }
        await note("Looked at \(screen.window.app.isEmpty ? "the screen" : screen.window.app)")
        guard !shown.isEmpty else { return screen.note ?? "The focused window (\(screen.window.title)) has no buttons or fields to press." }
        return "Window: \(screen.window.app) — \(screen.window.title)\n" + shown.enumerated()
            .map { "\($0.offset + 1). \($0.element.role) \"\($0.element.name.prefix(80))\"" }.joined(separator: "\n")
    }

    func click(element number: Int) async throws -> String {
        let element: HostClient.ScreenElement? = lock.withLock { elements.indices.contains(number - 1) ? elements[number - 1] : nil }
        guard let element else { return "There is no element \(number). Call look_at_screen first." }
        await note("Pressed “\(element.name.prefix(40))”")
        do {
            try await host.actOnScreen(element.id, action: "press")
        } catch HostClient.Failure.server(404, _) {
            return "That element is gone; the window changed. Call look_at_screen again."
        }
        return "Pressed \(element.name)."
    }

    /// The installed app a spoken name means: exact, then prefix, then any word.
    static func match(_ name: String, in apps: [HostClient.App]) -> HostClient.App? {
        let wanted = name.lowercased().trimmingCharacters(in: .whitespaces)
        return apps.first { $0.name.lowercased() == wanted }
            ?? apps.first { $0.name.lowercased().hasPrefix(wanted) || wanted.hasPrefix($0.name.lowercased()) }
            ?? apps.first { app in app.name.lowercased().split(separator: " ").contains { wanted.contains($0) && $0.count > 2 } }
    }
}

extension HostClient {
    struct ScreenElement: Decodable, Sendable {
        var id: String
        var role: String
        var name: String
    }

    struct Screen: Decodable, Sendable {
        struct Window: Decodable, Sendable { var title: String; var app: String }
        var window: Window
        var elements: [ScreenElement]
        var note: String?
    }

    func screenElements() async throws -> Screen { try await request("GET", "/v1/screen/elements", timeout: 30) }

    func actOnScreen(_ element: String, action: String) async throws {
        let _: [String: Bool] = try await request("POST", "/v1/screen/act", body: ["element": .string(element), "action": .string(action)], timeout: 30)
    }

    func typeOnScreen(_ text: String) async throws {
        let _: [String: Bool] = try await request("POST", "/v1/screen/type", body: ["text": .string(text)], timeout: 60)
    }

    func pressOnScreen(_ keys: String) async throws {
        let _: [String: Bool] = try await request("POST", "/v1/screen/keys", body: ["keys": .string(keys)], timeout: 30)
    }
}
