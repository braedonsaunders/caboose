import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// The computer-use decision as the desktop specialist asks it: one constrained token, the
/// letter of a grounded choice, with the KV cache kept across a task's steps because every
/// step's prompt starts with the same task line. Replays `decisions.json` (rendered prompts
/// from generated fixture validation trajectories, see guest/desktop-mcp) for each model named
/// by `--decide a,b` (MLXProbe registry names), cold and with cache reuse.
@MainActor
struct DecisionProbe {
    let probe: Probe

    struct Step: Decodable, Sendable { let prompt: String; let choices: Int }
    struct Timing: Sendable { var milliseconds: [Double] = []; var promptTokens: [Int] = []; var cachedTokens: [Int] = [] }

    func run(_ names: [String]) async {
        guard let url = Bundle.main.url(forResource: "decisions", withExtension: "json"),
              let tasks = try? JSONDecoder().decode([[Step]].self, from: Data(contentsOf: url)) else {
            probe.emit("decide", ["error": "decisions.json missing from the probe bundle"]); return
        }
        Memory.cacheLimit = 256 * 1024 * 1024
        for name in names {
            guard let configuration = MLXProbe.models[name] else { probe.emit("decide", ["model": name, "error": "unknown model"]); continue }
            do {
                let container = try await #huggingFaceLoadModelContainer(configuration: configuration)
                for reuse in [false, true, true] {
                    let timing = try await container.perform { context in try Self.replay(context, tasks, reuse: reuse) }
                    let sorted = timing.milliseconds.sorted()
                    probe.emit("decide", ["model": name, "cacheReuse": reuse, "decisions": sorted.count,
                                          "medianMs": sorted[sorted.count / 2], "p95Ms": sorted[sorted.count * 95 / 100],
                                          "meanMs": sorted.reduce(0, +) / Double(sorted.count),
                                          "medianPromptTokens": timing.promptTokens.sorted()[timing.promptTokens.count / 2],
                                          "medianCachedTokens": timing.cachedTokens.sorted()[timing.cachedTokens.count / 2],
                                          "peakMemoryMB": Double(Memory.peakMemory) / 1_048_576])
                }
            } catch {
                probe.emit("decide", ["model": name, "error": String(describing: error).prefix(600).description])
            }
            Memory.clearCache()
        }
    }

    nonisolated static func replay(_ context: ModelContext, _ tasks: [[Step]], reuse: Bool) throws -> Timing {
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef".map { context.tokenizer.encode(text: " \($0)", addSpecialTokens: false) }
        guard letters.allSatisfy({ $0.count == 1 }) else { throw ProbeError.tokenizer }
        let letterIDs = letters.map { Int32($0[0]) }
        var timing = Timing()
        for task in tasks {
            var cache = try context.model.newCache(parameters: nil)
            var previous: [Int] = []
            for step in task {
                let started = ContinuousClock.now
                let ids = context.tokenizer.encode(text: step.prompt, addSpecialTokens: false)
                var common = 0
                if reuse {
                    while common < min(previous.count, ids.count - 1), previous[common] == ids[common] { common += 1 }
                    for layer in cache { _ = layer.trim(previous.count - common) }
                } else {
                    cache = try context.model.newCache(parameters: nil)
                }
                let input = MLXArray(ids[common...].map { Int32($0) }).reshaped([1, -1])
                let logits = context.model(input, cache: cache)[0, -1]
                let allowed = take(logits, MLXArray(Array(letterIDs[0 ..< step.choices])), axis: 0)
                _ = argMax(allowed).item(Int.self)
                let elapsed = ContinuousClock.now - started
                timing.milliseconds.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
                timing.promptTokens.append(ids.count)
                timing.cachedTokens.append(common)
                previous = ids
            }
        }
        return timing
    }

    enum ProbeError: Error { case tokenizer }
}
