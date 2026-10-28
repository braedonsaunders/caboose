import Foundation
import FoundationModels
import SwiftUI

/// Records the model's tool calls instead of acting on a computer, answering as the host would.
final class RecordingActions: ComputerActions, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [Call] = []
    private let screen: [(role: String, name: String)]

    init(screen: [(role: String, name: String)]) { self.screen = screen }

    var recorded: [Call] { lock.withLock { calls } }
    private func record(_ tool: String, _ args: [String: String]) { lock.withLock { calls.append(Call(tool: tool, args: args)) } }

    func launch(app: String) async throws -> String { record("launch_app", ["app": app]); return "\(app) is open and focused." }
    func open(url: String) async throws -> String { record("open_url", ["url": url]); return "Opened \(url) in the browser." }
    func type(text: String, pressReturn: Bool) async throws -> String { record("type_text", ["text": text, "pressReturn": String(pressReturn)]); return "Typed." }
    func press(keys: String) async throws -> String { record("press_keys", ["keys": keys]); return "Pressed \(keys)." }
    func park() async throws -> String { record("park_computer", [:]); return "The computer is parking." }
    func delegate(task: String, agent: String?) async throws -> String {
        record("delegate", ["task": task, "agent": agent ?? ""])
        return "\(agent ?? "Claude Code") started the task and will report back."
    }
    func look() async throws -> String {
        record("look_at_screen", [:])
        guard !screen.isEmpty else { return "The focused window has no buttons or fields to press." }
        return "Window: App — Window\n" + screen.enumerated().map { "\($0.offset + 1). \($0.element.role) \"\($0.element.name)\"" }.joined(separator: "\n")
    }
    func click(element number: Int) async throws -> String { record("click_element", ["number": String(number)]); return "Pressed." }
}

func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let line = String(data: data, encoding: .utf8) else { return }
    print("ONDEVICE-EVAL " + line)
    fflush(stdout)
}

@MainActor @Observable
final class Evaluation {
    var lines: [String] = []

    func run() async {
        let model = SystemLanguageModel.default
        var meta: [String: Any] = ["event": "meta", "availability": String(describing: model.availability)]
        if #available(iOS 27.0, *), model.isAvailable {
            meta["variant"] = model.variant.displayName
            meta["contextSize"] = model.contextSize
        }
        emit(meta)
        guard model.isAvailable else { lines.append("Apple Intelligence is not available"); return finish() }
        var passed = 0
        for item in cases {
            let actions = RecordingActions(screen: item.screen)
            let session = LanguageModelSession(model: model, tools: OnDeviceTools.all(actions),
                                               instructions: OnDeviceTools.instructions(apps: evalApps, agents: evalAgents))
            let started = ContinuousClock.now
            var text = "", failure = ""
            do { text = try await session.respond(to: item.prompt, options: GenerationOptions(sampling: .greedy)).content }
            catch { failure = String(describing: error) }
            let elapsed = started.duration(to: .now)
            let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            let pass = failure.isEmpty && item.pass(actions.recorded, text)
            if pass { passed += 1 }
            emit(["event": "case", "id": item.id, "category": item.category, "pass": pass, "ms": ms, "text": text, "error": failure,
                  "calls": actions.recorded.map { ["tool": $0.tool, "args": $0.args] }])
            lines.append("\(pass ? "✓" : "✗") \(item.id) \(ms) ms")
        }
        emit(["event": "done", "passed": passed, "total": cases.count])
        lines.append("\(passed)/\(cases.count) passed")
        finish()
    }

    /// Run from `devicectl … --console`, the app exits when done so the console returns.
    private func finish() {
        guard ProcessInfo.processInfo.environment["ONDEVICE_EVAL_STAY"] == nil else { return }
        Task { try? await Task.sleep(for: .seconds(1)); exit(0) }
    }
}

@main
struct OnDeviceEvalApp: App {
    @State private var evaluation = Evaluation()
    var body: some Scene {
        WindowGroup {
            List(evaluation.lines.reversed(), id: \.self) { Text($0).font(.caption.monospaced()) }
                .task { await evaluation.run() }
        }
    }
}
