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
    @ObservationIgnored private var socket: HTTP1WebSocket?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    /// The open-weight models downloaded to this phone.
    let library = PhoneModelLibrary()
    @ObservationIgnored private let runner: PhoneModelRunner

    init() {
        AISettings.register()
        runner = PhoneModelRunner(library: library)
        library.changed = { [weak self] in self?.modelsChanged() }
    }

    /// Tells the computer the models now on offer.
    private func modelsChanged() {
        models = runner.models()
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
    }

    func settingChanged() {
        close()
        connect()
    }

    private func connect() {
        guard let host, socket == nil else { return }
        guard AISettings.enabled else { status = .off; return }
        models = runner.models()
        if models.isEmpty { status = .unavailable(runner.unavailableReason ?? "No models are on this iPhone."); return }
        generation += 1
        let current = generation
        let task = HTTP1WebSocket(url: host.socketURL("/v1/ai"), headers: [("Authorization", "Bearer \(host.token)")],
                                  maximumMessageSize: 40 * 1024 * 1024, label: "caboose.ai.socket")
        socket = task
        status = .connecting
        task.open { [weak self] event in
            // In order, on the main queue.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.socketEvent(event, on: task, generation: current) }
            }
        }
    }

    private func close() {
        generation += 1
        socket?.close(code: 1001)
        socket = nil
        for task in tasks.values { task.cancel() }
        tasks = [:]
        running = 0
        runner.cancelAll()
    }

    private func send(_ text: String, on task: HTTP1WebSocket) {
        task.send(.string(text))
    }

    private func socketEvent(_ event: HTTP1WebSocket.Event, on task: HTTP1WebSocket, generation current: Int) {
        guard generation == current, socket === task else { return }
        switch event {
        case .opened:
            send(AIRelay.hello(models), on: task)
            task.ping { [weak self] error in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, error == nil, self.generation == current, self.socket === task else { return }
                        self.status = .serving
                    }
                }
            }
        case .message(.string(let text)): handle(text, on: task)
        case .message(.data(let data)): handle(String(decoding: data, as: UTF8.self), on: task)
        case .closed:
            close()
            status = .connecting
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.generation == current + 1, self.host != nil else { return }
                self.connect()
            }
        }
    }

    private func handle(_ text: String, on task: HTTP1WebSocket) {
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
                case .cancel: break
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
