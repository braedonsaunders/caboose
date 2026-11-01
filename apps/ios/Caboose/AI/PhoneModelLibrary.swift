import CabooseKit
import Foundation
import FoundationModels
import HuggingFace
import MLX
import MLXFoundationModels
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Observation
import Tokenizers

/// Open-weight language models the owner downloads to this phone and serves to the computer
/// next to Apple's (docs/ai.md § Phone models). They run with MLX on the phone's GPU, through
/// the same Foundation Models sessions as Apple's model (`MLXLanguageModel`, iOS 27).
///
/// Weights live in `Application Support/Caboose/Models/<id>`, excluded from backups. A model
/// is installed once its download completed; deleting it removes the folder.
@MainActor @Observable
final class PhoneModelLibrary {
    struct Entry: Identifiable, Sendable {
        let id: String
        let name: String
        let configuration: ModelConfiguration
        /// The download, about.
        let downloadBytes: Int64
        /// Memory while answering a long prompt, measured on an iPhone with 12 GB.
        let memoryBytes: Int64
        /// The window Caboose offers: what fits the phone's memory beside the weights.
        let contextSize: Int
        /// Output tokens per second, measured on an A20 Pro-class iPhone.
        let tokensPerSecond: Int
        let reasoning: Bool

        var repo: String { configuration.name }
    }

    enum State: Equatable {
        case absent
        case downloading(Double)
        case installed(bytes: Int64)
        case failed(String)
    }

    static let catalog: [Entry] = [
        Entry(id: "qwen3.5-2b", name: "Qwen3.5 2B", configuration: LLMRegistry.qwen3_5_2b_4bit, downloadBytes: 1_400_000_000,
              memoryBytes: 1_700_000_000, contextSize: 32768, tokensPerSecond: 93, reasoning: true),
        Entry(id: "qwen3-1.7b", name: "Qwen3 1.7B", configuration: LLMRegistry.qwen3_1_7b_4bit, downloadBytes: 1_000_000_000,
              memoryBytes: 1_600_000_000, contextSize: 32768, tokensPerSecond: 97, reasoning: true),
        Entry(id: "qwen3-4b", name: "Qwen3 4B", configuration: LLMRegistry.qwen3_4b_4bit, downloadBytes: 2_300_000_000,
              memoryBytes: 3_000_000_000, contextSize: 16384, tokensPerSecond: 44, reasoning: true),
        Entry(id: "gemma4-e2b", name: "Gemma 4 E2B", configuration: LLMRegistry.gemma4_e2b_it_4bit, downloadBytes: 2_700_000_000,
              memoryBytes: 3_400_000_000, contextSize: 16384, tokensPerSecond: 64, reasoning: false),
        Entry(id: "llama3.2-3b", name: "Llama 3.2 3B", configuration: LLMRegistry.llama3_2_3B_4bit, downloadBytes: 1_800_000_000,
              memoryBytes: 2_400_000_000, contextSize: 16384, tokensPerSecond: 55, reasoning: false),
    ]

    nonisolated static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Caboose/Models", isDirectory: true)
    }

    private(set) var states: [String: State] = [:]
    /// Called when the installed models change, so the computer hears of it.
    @ObservationIgnored var changed: () -> Void = {}
    @ObservationIgnored private var downloads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var loaded: [String: Any] = [:]

    init() {
        for entry in Self.catalog { states[entry.id] = Self.complete(entry.id) ? .installed(bytes: Self.size(of: Self.directory(entry.id))) : .absent }
    }

    var installed: [Entry] { Self.catalog.filter { if case .installed = states[$0.id] { true } else { false } } }

    nonisolated static func directory(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    nonisolated private static func marker(_ id: String) -> URL { directory(id).appendingPathComponent(".complete") }
    nonisolated static func complete(_ id: String) -> Bool { FileManager.default.fileExists(atPath: marker(id).path) }

    nonisolated static func size(of directory: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files { total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0) }
        return total
    }

    /// Free space for downloads on the phone.
    var freeBytes: Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    func download(_ id: String) {
        guard let entry = Self.catalog.first(where: { $0.id == id }), downloads[id] == nil else { return }
        if let free = freeBytes, free < entry.downloadBytes + 500_000_000 {
            states[id] = .failed("Not enough space: \(entry.downloadBytes.formatted(.byteCount(style: .file))) needed")
            return
        }
        states[id] = .downloading(0)
        downloads[id] = Task { @MainActor [weak self] in
            do {
                try await Self.fetch(entry) { fraction in Task { @MainActor in self?.states[id] = .downloading(fraction) } }
                guard let self, !Task.isCancelled else { return }
                self.states[id] = .installed(bytes: Self.size(of: Self.directory(id)))
                self.changed()
            } catch {
                guard let self else { return }
                if Task.isCancelled { try? FileManager.default.removeItem(at: Self.directory(id)); self.states[id] = .absent }
                else { self.states[id] = .failed(error.localizedDescription) }
            }
            self?.downloads[id] = nil
        }
    }

    func cancelDownload(_ id: String) {
        downloads.removeValue(forKey: id)?.cancel()
        try? FileManager.default.removeItem(at: Self.directory(id))
        states[id] = .absent
    }

    func delete(_ id: String) {
        downloads.removeValue(forKey: id)?.cancel()
        loaded[id] = nil
        try? FileManager.default.removeItem(at: Self.directory(id))
        states[id] = .absent
        changed()
    }

    /// The weights, downloaded into the model's folder; the marker is written last.
    private nonisolated static func fetch(_ entry: Entry, progress: @escaping @Sendable (Double) -> Void) async throws {
        let directory = directory(entry.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var root = Self.root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        guard let repo = Repo.ID(rawValue: entry.repo) else { throw CocoaError(.fileReadInvalidFileName) }
        let client = HubClient(host: HubClient.defaultHost, tokenProvider: .none, cache: nil)
        _ = try await client.downloadSnapshot(of: repo, to: directory, matching: ModelFolder.patterns) { value in progress(value.fractionCompleted) }
        try Data().write(to: marker(entry.id))
    }

    // MARK: Serving

    /// What the computer is told about the installed models.
    func models() -> [AIRelay.Model] {
        guard #available(iOS 27.0, *) else { return [] }
        return installed.map { entry in
            AIRelay.Model(id: entry.id, name: "\(entry.name) (on iPhone)", contextSize: entry.contextSize,
                          capabilities: ["tools", "json"] + (entry.reasoning ? ["reasoning"] : []), family: entry.repo, ownedBy: "mlx")
        }
    }

    /// The model to answer with, kept loaded between requests. Only one stays in memory.
    @available(iOS 27.0, *)
    func languageModel(_ id: String) -> MLXLanguageModel? {
        guard let entry = installed.first(where: { $0.id == id }) else { return nil }
        if let model = loaded[id] as? MLXLanguageModel { return model }
        unload()
        let folder = ModelFolder(directory: Self.directory(id))
        var capabilities: [LanguageModelCapabilities.Capability] = [.guidedGeneration, .toolCalling]
        if entry.reasoning { capabilities.append(.reasoning) }
        let model = MLXLanguageModel(configuration: entry.configuration, capabilities: capabilities,
                                     weightsLocation: { _ in folder.directory },
                                     load: { configuration, progress in
                                         try await loadModelContainer(from: folder, using: #huggingFaceTokenizerLoader(),
                                                                      configuration: configuration, progressHandler: progress)
                                     })
        loaded[id] = model
        return model
    }

    /// Frees the loaded model's memory: in the background, on a memory warning, before another loads.
    func unload() {
        guard #available(iOS 27.0, *) else { return }
        let models = loaded.values.compactMap { $0 as? MLXLanguageModel }
        loaded = [:]
        Task { for model in models { await model.evict() }; MLX.Memory.clearCache() }
    }
}

/// A downloaded model's folder as MLX's downloader: it never reaches the network.
private struct ModelFolder: MLXLMCommon.Downloader {
    static let patterns = ["*.safetensors", "*.json", "*.jinja", "*.model", "*.tiktoken", "*.txt"]
    let directory: URL

    func download(id: String, revision: String?, matching patterns: [String], useLatest: Bool,
                  progressHandler: @Sendable @escaping (Progress) -> Void) async throws -> URL {
        directory
    }
}
