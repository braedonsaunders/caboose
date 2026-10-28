import Foundation
import FoundationModels
import Observation
import SwiftUI

/// One request the iPhone's own model handled: what it did, and what it said.
@MainActor @Observable
final class OnDeviceRun: Identifiable {
    enum Status { case working, done, failed }
    let id = UUID()
    let prompt: String
    private(set) var steps: [String] = []
    private(set) var reply: String?
    private(set) var status: Status = .working
    private(set) var seconds: Double?

    init(prompt: String) { self.prompt = prompt }

    func add(_ step: String) { steps.append(step) }

    func finish(_ reply: String, failed: Bool = false, seconds: Double) {
        self.reply = reply
        self.seconds = seconds
        status = failed ? .failed : .done
    }
}

/// The Ask bar's "On iPhone" agent: Apple's on-device Foundation Models model, acting on the
/// computer through the host. It does quick things itself and delegates real work to one of
/// the computer's agents (docs/architecture.md § App, On iPhone).
struct OnDeviceAgent {
    let host: HostClient
    let center: AgentCenter
    /// The registry id of the agent that takes real work; nil for the owner's default agent.
    let delegate: String?

    static var isAvailable: Bool { SystemLanguageModel.default.availability == .available }

    @MainActor
    func run(_ run: OnDeviceRun) async {
        let started = Date()
        let apps = (try? await host.apps()) ?? []
        let actions = HostActions(host: host, apps: apps, run: run, center: center, fallback: delegate)
        let agents = center.installedAgents.map(\.name)
        let session = LanguageModelSession(
            model: .default, tools: OnDeviceTools.all(actions),
            instructions: OnDeviceTools.instructions(apps: apps.map { OnDeviceTools.describe(app: $0.name, categories: $0.categories) },
                                                     agents: agents.isEmpty ? ["the default agent"] : agents))
        do {
            let response = try await session.respond(to: run.prompt, options: GenerationOptions(sampling: .greedy))
            run.finish(response.content, seconds: Date().timeIntervalSince(started))
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } catch let error as LanguageModelSession.GenerationError {
            run.finish(Self.describe(error), failed: true, seconds: Date().timeIntervalSince(started))
        } catch {
            run.finish(error.localizedDescription, failed: true, seconds: Date().timeIntervalSince(started))
        }
    }

    private static func describe(_ error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .exceededContextWindowSize: "That was too much for the on-device model. Try a shorter request, or pick another agent."
        case .guardrailViolation: "The on-device model declined that request."
        case .unsupportedLanguageOrLocale: "The on-device model does not support this language yet."
        default: error.localizedDescription
        }
    }
}

/// Carries out the model's tool calls through the host, noting each on the run.
final class HostActions: ComputerActions, @unchecked Sendable {
    private let host: HostClient
    private let apps: [HostClient.App]
    private let run: OnDeviceRun
    private let center: AgentCenter
    private let fallback: String?
    /// What look_at_screen numbered, so click_element can press it.
    private var elements: [HostClient.ScreenElement] = []
    private let lock = NSLock()

    init(host: HostClient, apps: [HostClient.App], run: OnDeviceRun, center: AgentCenter, fallback: String?) {
        self.host = host
        self.apps = apps
        self.run = run
        self.center = center
        self.fallback = fallback
    }

    private func note(_ step: String) async { await MainActor.run { run.add(step) } }

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
        let (id, name) = await MainActor.run { () -> (String?, String) in
            let installed = center.installedAgents
            let wanted = agent?.lowercased() ?? ""
            let named = wanted.isEmpty ? nil : installed.first { $0.name.lowercased() == wanted || $0.id == wanted }
                ?? installed.first { $0.name.lowercased().contains(wanted) || $0.id.contains(wanted) }
            let id = named?.id ?? fallback ?? center.defaultAgent
            return (id, id.flatMap { center.listing($0)?.name } ?? "The default agent")
        }
        await note("Handed to \(name)")
        let started = await center.ask(task, agent: id)
        return started ? "\(name) started the task and will report back." : "\(name) could not start the task."
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

/// A request the iPhone handled, on Home beside the computer's tasks.
struct OnDeviceCard: View {
    @Environment(AppModel.self) private var model
    let run: OnDeviceRun

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Group {
                    switch run.status {
                    case .working: ProgressView().controlSize(.small)
                    case .done: Image(systemName: "iphone").foregroundStyle(.tint)
                    case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    }
                }
                .frame(width: 20)
                VStack(alignment: .leading, spacing: 4) {
                    Text(run.prompt).font(.subheadline.weight(.semibold)).lineLimit(2)
                    ForEach(Array(run.steps.enumerated()), id: \.offset) { _, step in
                        Label(step, systemImage: "arrow.turn.down.right").font(.caption).foregroundStyle(.cyan)
                    }
                    if let reply = run.reply, !reply.isEmpty {
                        Text(reply).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if run.status != .working {
                    Button { model.agents.dismiss(run) } label: { Image(systemName: "xmark").font(.caption) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            if let seconds = run.seconds {
                Text("On iPhone · \(seconds, specifier: "%.1f") s").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}
