import CabooseKit
import Foundation
import Observation
import SwiftUI

/// The phone's language models as the computer's (docs/ai.md § Phone): while Caboose is open
/// and connected, and On-Device AI is on, the phone serves Apple's on-device model on the
/// host's `/v1/ai`, and programs in the computer reach it at `localhost:11434`. In the
/// background, or with the switch off, the computer's programs are told the phone is away.
@MainActor @Observable
final class PhoneAI {
    enum Status: Equatable {
        case off
        case unavailable(String)
        case connecting
        case serving
    }

    private(set) var status: Status = .off
    /// Requests answered since Caboose opened.
    private(set) var answered = 0
    private(set) var running = 0
    private(set) var models: [AIRelay.Model] = []

    @ObservationIgnored private var host: HostClient?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let runner = AppleModelRunner()

    init() { AISettings.register() }

    func attach(host: HostClient) {
        self.host = host
        close()
        connect()
    }

    func detach() {
        host = nil
        close()
        status = .off
    }

    func settingChanged() {
        close()
        connect()
    }

    private func connect() {
        guard let host, socket == nil else { return }
        guard AISettings.enabled else { status = .off; return }
        models = runner.models()
        if let reason = runner.unavailableReason { status = .unavailable(reason); return }
        generation += 1
        let current = generation
        var request = URLRequest(url: host.socketURL("/v1/ai"))
        request.setValue("Bearer \(host.token)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 40 * 1024 * 1024
        socket = task
        status = .connecting
        task.resume()
        send(AIRelay.hello(models), on: task)
        task.sendPing { [weak self] error in
            Task { @MainActor in
                guard let self, error == nil, self.generation == current, self.socket === task else { return }
                self.status = .serving
            }
        }
        receive(on: task, generation: current)
    }

    private func close() {
        generation += 1
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        for task in tasks.values { task.cancel() }
        tasks = [:]
        running = 0
        runner.cancelAll()
    }

    private func send(_ text: String, on task: URLSessionWebSocketTask) {
        task.send(.string(text)) { _ in }
    }

    private func receive(on task: URLSessionWebSocketTask, generation current: Int) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.generation == current, self.socket === task else { return }
                switch result {
                case .failure:
                    self.close()
                    self.status = .connecting
                    try? await Task.sleep(for: .seconds(3))
                    guard self.generation == current + 1, self.host != nil else { return }
                    self.connect()
                case .success(let message):
                    switch message {
                    case .string(let text): self.handle(text, on: task)
                    case .data(let data): self.handle(String(decoding: data, as: UTF8.self), on: task)
                    @unknown default: break
                    }
                    self.receive(on: task, generation: current)
                }
            }
        }
    }

    private func handle(_ text: String, on task: URLSessionWebSocketTask) {
        let message: AIRelay.Incoming
        do {
            message = try AIRelay.incoming(text)
        } catch let invalid as AIRelay.InvalidMessage {
            if let id = invalid.id { send(AIRelay.error(id, .init(status: 400, code: "invalid_request", message: invalid.reason)), on: task) }
            return
        } catch {
            return
        }
        switch message {
        case .cancel(let id):
            tasks.removeValue(forKey: id)?.cancel()
        case .request(let id, let request):
            guard tasks[id] == nil else { return }
            running += 1
            tasks[id] = Task { @MainActor [weak self, runner] in
                await runner.run(id: id, request: request) { [weak self] event in
                    guard let self, self.socket === task else { return }
                    self.send(event, on: task)
                }
                guard let self else { return }
                if self.tasks.removeValue(forKey: id) != nil {
                    self.running -= 1
                    self.answered += 1
                }
            }
        }
    }
}

/// The On-Device AI switch, kept on this phone.
enum AISettings {
    static let enabledKey = "ai.onDevice"

    static func register() {
        UserDefaults.standard.register(defaults: [enabledKey: true])
    }

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
}

/// Computer settings' On-Device AI section.
struct PhoneAISettingsSection: View {
    let ai: PhoneAI
    @AppStorage(AISettings.enabledKey) private var enabled = true
    private let device = UIDevice.current.model

    var body: some View {
        Section {
            Toggle(isOn: $enabled) {
                Label { Text("On-Device AI for Apps") } icon: { Image(systemName: "apple.intelligence") }
            }
            .onChange(of: enabled) { _, _ in ai.settingChanged() }
            if enabled {
                LabeledContent("Status", value: statusText)
                if let model = ai.models.first, ai.status == .serving {
                    LabeledContent("Model", value: model.family.map { "\(model.id) (\($0))" } ?? model.id)
                    LabeledContent("Context", value: "\(model.contextSize.formatted()) tokens")
                    LabeledContent("Answered", value: ai.running > 0 ? "\(ai.answered), \(ai.running) running" : "\(ai.answered)")
                }
            }
        } header: {
            Text("On-Device AI")
        } footer: {
            Text("While Caboose is open, programs on the computer use Apple's model on this \(device) at localhost:11434, with the OpenAI or Ollama API. Requests and answers stay between this \(device) and your computer.")
        }
    }

    private var statusText: String {
        switch ai.status {
        case .off: "Off"
        case .unavailable(let reason): reason
        case .connecting: "Connecting"
        case .serving: "Serving"
        }
    }
}
