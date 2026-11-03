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
    /// The open-weight models downloaded to this phone.
    let library = PhoneModelLibrary()
    /// The computer's decision models, downloaded from it.
    let decider = PhoneDecider()
    @ObservationIgnored private let runner: PhoneModelRunner

    init() {
        AISettings.register()
        runner = PhoneModelRunner(library: library)
        library.changed = { [weak self] in self?.modelsChanged() }
        decider.changed = { [weak self] in self?.modelsChanged() }
    }

    private func offered() -> [AIRelay.Model] { runner.models() + decider.models() }

    /// Tells the computer the models now on offer.
    private func modelsChanged() {
        models = offered()
        if let socket { send(AIRelay.hello(models), on: socket) }
    }

    func attach(host: HostClient) {
        self.host = host
        close()
        connect()
    }

    func detach() {
        host = nil
        close()
        status = .off
        // iOS ends an app holding gigabytes in the background.
        library.unload()
        runner.embedder.unload()
        decider.unload()
    }

    func settingChanged() {
        close()
        connect()
    }

    private func connect() {
        guard let host, socket == nil else { return }
        guard AISettings.enabled else { status = .off; return }
        models = offered()
        if models.isEmpty { status = .unavailable(runner.unavailableReason ?? "No models are on this iPhone."); return }
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
        decider.sync { [weak self] message in
            guard let self, self.socket === task else { return }
            self.send(message, on: task)
        }
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
        decider.disconnected()
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
                    case .data(let data): if !self.decider.received(chunk: data) { self.handle(String(decoding: data, as: UTF8.self), on: task) }
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
            running = tasks.count
        case .models(let id, let manifest):
            decider.received(id, manifest: manifest)
        case .unanswered(let id, let reason):
            decider.unanswered(id, reason: reason)
        case .decide(let id, let request):
            guard tasks[id] == nil else { return }
            send(AIRelay.started(id), on: task)
            tasks[id] = Task { @MainActor [weak self, decider] in
                let event: String
                do {
                    let answer = try await decider.decide(request)
                    event = answer.choice < request.choices ? AIRelay.decision(id, choice: answer.choice, elapsedMs: answer.elapsedMs)
                        : AIRelay.error(id, .init(status: 500, code: "model_error", message: "The model chose outside the offered choices."))
                } catch let failure as AIRelay.Failure {
                    event = AIRelay.error(id, failure)
                } catch {
                    event = AIRelay.error(id, .init(status: 500, code: "model_error", message: String(describing: error).prefix(500).description))
                }
                guard let self else { return }
                if self.tasks.removeValue(forKey: id) != nil, !Task.isCancelled, self.socket === task { self.send(event, on: task); self.answered += 1 }
                self.running = self.tasks.count
            }
            running = tasks.count
        case .request(let id, _), .embed(let id, _):
            guard tasks[id] == nil else { return }
            tasks[id] = Task { @MainActor [weak self, runner] in
                let send: (String) -> Void = { [weak self] event in
                    guard let self, self.socket === task else { return }
                    self.send(event, on: task)
                }
                switch message {
                case .request(_, let request): await runner.run(id: id, request: request, send: send)
                case .embed(_, let request): await runner.embed(id: id, request: request, send: send)
                case .cancel, .decide, .models, .unanswered: break
                }
                guard let self else { return }
                if self.tasks.removeValue(forKey: id) != nil { self.answered += 1 }
                self.running = self.tasks.count
            }
            running = tasks.count
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
                if ai.status == .serving {
                    LabeledContent("Answered", value: ai.running > 0 ? "\(ai.answered), \(ai.running) running" : "\(ai.answered)")
                }
                NavigationLink {
                    PhoneModelsView(ai: ai)
                } label: {
                    LabeledContent("Models", value: "\(ai.models.count)")
                }
            }
        } header: {
            Text("On-Device AI")
        } footer: {
            Text("While Caboose is open, programs on the computer use the models on this \(device) at localhost:11434, with the OpenAI or Ollama API. Requests and answers stay between this \(device) and your computer.")
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

/// The models the computer can use, and the open-weight ones to download.
struct PhoneModelsView: View {
    let ai: PhoneAI

    var body: some View {
        List {
            Section("Serving") {
                if ai.models.isEmpty { Text("No models").foregroundStyle(.secondary) }
                ForEach(ai.models, id: \.id) { model in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.id).font(.body.monospaced())
                        Text(model.embedding ? "Embeddings · \(model.contextSize.formatted()) tokens" : "\(model.contextSize.formatted())-token window · \(model.capabilities.joined(separator: ", "))")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                ForEach(PhoneModelLibrary.catalog) { entry in
                    PhoneModelRow(entry: entry, library: ai.library)
                }
            } header: {
                Text("Download")
            } footer: {
                Text("Open-weight models run on this iPhone's GPU while Caboose is open. Speeds were measured on an iPhone with an A20 Pro.\(ai.library.freeBytes.map { " \($0.formatted(.byteCount(style: .file))) free." } ?? "")")
            }
        }
        .navigationTitle("Models")
    }
}

private struct PhoneModelRow: View {
    let entry: PhoneModelLibrary.Entry
    let library: PhoneModelLibrary

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                Text("\(entry.tokensPerSecond) tokens/s · \(entry.contextSize.formatted())-token window · needs \(entry.memoryBytes.formatted(.byteCount(style: .memory)))")
                    .font(.footnote).foregroundStyle(.secondary)
                if case .failed(let reason) = library.states[entry.id] { Text(reason).font(.footnote).foregroundStyle(.red) }
            }
            Spacer()
            switch library.states[entry.id] ?? .absent {
            case .absent, .failed:
                Button("Get \(entry.downloadBytes.formatted(.byteCount(style: .file)))") { library.download(entry.id) }
                    .buttonStyle(.bordered)
            case .downloading(let fraction):
                ProgressView(value: fraction).frame(width: 60)
                Button("Stop", systemImage: "xmark.circle.fill") { library.cancelDownload(entry.id) }.labelStyle(.iconOnly)
            case .installed(let bytes):
                Text(bytes.formatted(.byteCount(style: .file))).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .swipeActions {
            if case .installed = library.states[entry.id] {
                Button("Delete", role: .destructive) { library.delete(entry.id) }
            }
        }
    }
}
