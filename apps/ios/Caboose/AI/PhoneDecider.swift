import CabooseKit
import CryptoKit
import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// The computer's decision models (docs/ai.md § Computer models, § Decisions). The computer's
/// release carries them; this phone downloads a model's files from the computer through the
/// host, only the ones whose SHA-256 changed, checks each against the manifest, and answers
/// decisions with MLX on the GPU: one token, read over the offered choice letters, with the KV
/// cache kept across a task's steps because every step's prompt opens with the same task line.
///
/// Files live in `Application Support/Caboose/ComputerModels/<name>`, excluded from backups,
/// with `.manifest.json` recording the release and digests they were checked against.
@MainActor
final class PhoneDecider {
    nonisolated static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Caboose/ComputerModels", isDirectory: true)
    }

    /// Called when the decision models on offer change, so the computer hears of it.
    var changed: () -> Void = {}
    private(set) var installed: [String] = []
    private var syncing: Task<Void, Never>?
    private var reads: [String: CheckedContinuation<Data, any Error>] = [:]
    private var listing: (id: String, continuation: CheckedContinuation<AIRelay.ComputerModels, any Error>)?
    private var loaded: (name: String, container: ModelContainer, state: DecisionState)?

    struct Unanswered: Error { let reason: String }

    init() {
        installed = (try? FileManager.default.contentsOfDirectory(atPath: Self.root.path))?.filter { Self.recorded($0) != nil }.sorted() ?? []
    }

    func models() -> [AIRelay.Model] {
        installed.map { AIRelay.Model(id: $0, name: "Caboose decisions (\($0))", contextSize: 2048, capabilities: [], decision: true, ownedBy: "caboose") }
    }

    // MARK: Download

    /// Brings this phone's copies in line with the computer's manifest. `send` writes one message on the socket.
    func sync(send: @escaping (String) -> Void) {
        guard syncing == nil else { return }
        syncing = Task { [weak self] in
            defer { self?.syncing = nil }
            guard let self else { return }
            do {
                let id = Self.requestID()
                let manifest = try await withCheckedThrowingContinuation { continuation in
                    self.listing = (id, continuation)
                    send(AIRelay.listModels(id))
                }
                for model in manifest.models where AIRelay.safeName(model.name) {
                    try await self.install(model, release: manifest.release, send: send)
                }
                let names = Set(manifest.models.map(\.name))
                for stale in self.installed where !names.contains(stale) {
                    try? FileManager.default.removeItem(at: Self.root.appendingPathComponent(stale))
                    if self.loaded?.name == stale { self.loaded = nil }
                }
                self.refresh()
            } catch {
                // The computer is away or has nothing yet: the next connection tries again.
            }
        }
    }

    private func install(_ model: AIRelay.ComputerModels.Model, release: String, send: @escaping (String) -> Void) async throws {
        let folder = Self.root.appendingPathComponent(model.name, isDirectory: true)
        let recorded = Self.recorded(model.name)
        if recorded?.files == Dictionary(uniqueKeysWithValues: model.files.map { ($0.path, $0.sha256) }) { return }
        var directory = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        // The model is not on offer while its files change.
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(".manifest.json"))
        if loaded?.name == model.name { loaded = nil }
        refresh()
        for file in model.files where AIRelay.safeName(file.path) {
            let target = folder.appendingPathComponent(file.path)
            if FileManager.default.fileExists(atPath: target.path), recorded?.files[file.path] == file.sha256 { continue }
            try await download(model: model.name, file: file, to: target, send: send)
        }
        let keep = Set(model.files.map(\.path))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !keep.contains(name) && !name.hasPrefix(".") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        let record = try JSONEncoder().encode(Record(release: release, files: Dictionary(uniqueKeysWithValues: model.files.map { ($0.path, $0.sha256) })))
        try record.write(to: folder.appendingPathComponent(".manifest.json"), options: .atomic)
    }

    private func download(model: String, file: AIRelay.ComputerModels.File, to target: URL, send: @escaping (String) -> Void) async throws {
        let partial = target.appendingPathExtension("partial")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        var hash = SHA256()
        var offset: Int64 = 0
        while offset < file.size {
            let length = Int(min(Int64(AIRelay.maxRead), file.size - offset))
            let id = Self.requestID()
            let data = try await withCheckedThrowingContinuation { continuation in
                reads[id] = continuation
                send(AIRelay.read(id, model: model, path: file.path, offset: offset, length: length))
            }
            guard data.count == length else { throw Unanswered(reason: "a short read") }
            hash.update(data: data)
            try handle.write(contentsOf: data)
            offset += Int64(length)
        }
        try handle.close()
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
            try? FileManager.default.removeItem(at: partial)
            throw Unanswered(reason: "\(file.path) does not match the computer's manifest")
        }
        _ = try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: partial, to: target)
    }

    /// The computer's answer to a `models` request.
    func received(_ id: String, manifest: AIRelay.ComputerModels) {
        guard listing?.id == id, let continuation = listing?.continuation else { return }
        listing = nil
        continuation.resume(returning: manifest)
    }

    /// A read's bytes, or false when no read of this phone has that id.
    func received(chunk frame: Data) -> Bool {
        guard let (id, data) = AIRelay.chunk(frame), let continuation = reads.removeValue(forKey: id) else { return false }
        continuation.resume(returning: data)
        return true
    }

    func unanswered(_ id: String, reason: String) {
        if let continuation = reads.removeValue(forKey: id) { continuation.resume(throwing: Unanswered(reason: reason)) }
        if listing?.id == id, let continuation = listing?.continuation { listing = nil; continuation.resume(throwing: Unanswered(reason: reason)) }
    }

    /// The socket closed: every read in flight fails, and the next connection resumes the sync.
    func disconnected() {
        for continuation in reads.values { continuation.resume(throwing: Unanswered(reason: "the computer went away")) }
        reads = [:]
        if let continuation = listing?.continuation { listing = nil; continuation.resume(throwing: Unanswered(reason: "the computer went away")) }
    }

    private func refresh() {
        let now = (try? FileManager.default.contentsOfDirectory(atPath: Self.root.path))?.filter { Self.recorded($0) != nil }.sorted() ?? []
        if now != installed { installed = now; changed() }
    }

    private struct Record: Codable { let release: String; let files: [String: String] }

    private nonisolated static func recorded(_ name: String) -> Record? {
        guard AIRelay.safeName(name), let data = try? Data(contentsOf: root.appendingPathComponent(name).appendingPathComponent(".manifest.json")) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private nonisolated static func requestID() -> String {
        (0 ..< 16).map { _ in String(format: "%02x", UInt8.random(in: 0 ... 255)) }.joined()
    }

    // MARK: Decisions

    /// One decision: the index of the choice whose letter the model reads first.
    func decide(_ request: AIRelay.DecideRequest) async throws -> (choice: Int, elapsedMs: Double) {
        guard installed.contains(request.model) else { throw AIRelay.Failure(status: 404, code: "model_not_found", message: "No decision model \(request.model) on this iPhone.") }
        if loaded?.name != request.model {
            loaded = nil
            let directory = Self.root.appendingPathComponent(request.model, isDirectory: true)
            let container = try await loadModelContainer(from: ModelFolder(directory: directory), using: #huggingFaceTokenizerLoader(),
                                                         configuration: ModelConfiguration(directory: directory))
            loaded = (request.model, container, DecisionState())
        }
        guard let (_, container, state) = loaded else { throw AIRelay.Failure(status: 503, code: "model_unavailable", message: "The decision model is not loaded.") }
        return try await container.perform { context in try state.decide(context, request) }
    }

    /// Frees the model's memory: in the background, before another model loads.
    func unload() {
        loaded = nil
        MLX.Memory.clearCache()
    }
}

/// The KV cache and the tokens it holds. Only touched inside the model container's `perform`,
/// which runs one closure at a time.
private final class DecisionState: @unchecked Sendable {
    private var cache: [KVCache]?
    private var tokens: [Int] = []
    private var letters: [Int32]?

    func decide(_ context: ModelContext, _ request: AIRelay.DecideRequest) throws -> (choice: Int, elapsedMs: Double) {
        let started = ContinuousClock.now
        if letters == nil {
            let ids = AIRelay.decisionLetters.map { context.tokenizer.encode(text: " \($0)", addSpecialTokens: false) }
            guard ids.allSatisfy({ $0.count == 1 }) else { throw AIRelay.Failure(status: 500, code: "model_error", message: "The model cannot read choice letters as single tokens.") }
            letters = ids.map { Int32($0[0]) }
        }
        let ids = context.tokenizer.encode(text: request.prompt, addSpecialTokens: false)
        guard ids.count <= 2048 else { throw AIRelay.Failure(status: 413, code: "context_length_exceeded", message: "The decision prompt is longer than 2048 tokens.") }
        var common = 0
        if let cache {
            while common < min(tokens.count, ids.count - 1), tokens[common] == ids[common] { common += 1 }
            for layer in cache { _ = layer.trim(tokens.count - common) }
        } else {
            cache = try context.model.newCache(parameters: nil)
        }
        let input = MLXArray(ids[common...].map { Int32($0) }).reshaped([1, -1])
        let logits = context.model(input, cache: cache)[0, -1]
        let allowed = take(logits, MLXArray(Array(letters![0 ..< request.choices])), axis: 0)
        let choice = argMax(allowed).item(Int.self)
        tokens = ids
        let elapsed = ContinuousClock.now - started
        return (choice, Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
    }
}
