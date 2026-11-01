import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Open-weight models run with MLX on the phone's GPU: download, load, input and output speed,
/// and memory, for each model named by `--mlx a,b` (registry names below).
@MainActor
struct MLXProbe {
    let probe: Probe

    static let models: [String: ModelConfiguration] = [
        "qwen3-0.6b": LLMRegistry.qwen3_0_6b_4bit,
        "qwen3-1.7b": LLMRegistry.qwen3_1_7b_4bit,
        "qwen3-4b": LLMRegistry.qwen3_4b_4bit,
        "qwen3-8b": LLMRegistry.qwen3_8b_4bit,
        "qwen3.5-2b": LLMRegistry.qwen3_5_2b_4bit,
        "llama3.2-1b": LLMRegistry.llama3_2_1B_4bit,
        "llama3.2-3b": LLMRegistry.llama3_2_3B_4bit,
        "gemma3-1b": LLMRegistry.gemma3_1B_qat_4bit,
        "gemma4-e2b": LLMRegistry.gemma4_e2b_it_4bit,
        "gemma4-e4b": LLMRegistry.gemma4_e4b_it_4bit,
        "smollm3-3b": LLMRegistry.smollm3_3b_4bit,
        "lfm2-1.2b": LLMRegistry.lfm2_1_2b_4bit,
    ]

    func run(_ names: [String]) async {
        Memory.cacheLimit = 256 * 1024 * 1024
        for name in names {
            guard let configuration = Self.models[name] else { probe.emit("mlx", ["model": name, "error": "unknown model"]); continue }
            do { try await measure(name, configuration) } catch { probe.emit("mlx", ["model": name, "error": String(describing: error).prefix(600).description]) }
            Memory.clearCache()
        }
    }

    private func measure(_ name: String, _ configuration: ModelConfiguration) async throws {
        let before = Probe.footprintMB()
        let loadStarted = Date()
        let container = try await #huggingFaceLoadModelContainer(configuration: configuration)
        let loaded = Date().timeIntervalSince(loadStarted)
        probe.emit("mlx.load", ["model": name, "id": "\(configuration.id)", "seconds": loaded, "footprintBeforeMB": before,
                                "activeMemoryMB": Double(Memory.activeMemory) / 1_048_576, "availableMemoryMB": os_proc_available_memory() / 1_048_576])
        for (label, prompt, tokens) in [("short", "Write a detailed essay of about 500 words about the history of railways in Canada.", 400),
                                        ("long", Probe.corpus(sentences: 120) + "\n\nIn one sentence, what is this text about?", 60)] {
            let input = try await container.prepare(input: UserInput(prompt: prompt))
            let started = Date()
            var first: Date?
            var text = ""
            var info: GenerateCompletionInfo?
            for await generation in try await container.generate(input: input, parameters: GenerateParameters(maxTokens: tokens, temperature: 0)) {
                switch generation {
                case .chunk(let chunk): if first == nil { first = Date() }; text += chunk
                case .info(let completion): info = completion
                default: break
                }
            }
            var fields: [String: Any] = ["model": name, "kind": label, "ttft": first.map { $0.timeIntervalSince(started) } ?? -1,
                                         "total": Date().timeIntervalSince(started), "tail": String(text.suffix(80)),
                                         "peakMemoryMB": Double(Memory.peakMemory) / 1_048_576]
            if let info {
                fields["promptTokens"] = info.promptTokenCount
                fields["promptTokensPerSecond"] = info.promptTokensPerSecond
                fields["outputTokens"] = info.generationTokenCount
                fields["outputTokensPerSecond"] = info.tokensPerSecond
            }
            probe.emit("mlx", fields)
        }
    }
}
