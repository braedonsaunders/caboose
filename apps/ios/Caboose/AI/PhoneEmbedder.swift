import CabooseKit
import Foundation
import NaturalLanguage

/// Sentence embeddings for the computer (docs/ai.md § Embeddings) from Apple's on-device
/// contextual embedding for Latin-script languages (`NLContextualEmbedding`): the mean of a
/// text's token vectors, normalized to unit length. Texts longer than the model's sequence
/// are embedded from their beginning.
@MainActor
final class PhoneEmbedder {
    static let modelID = "apple-embedding"
    private let embedding = NLContextualEmbedding(script: .latin)
    private var loaded = false
    private var requested = false

    func models() -> [AIRelay.Model] {
        guard let embedding else { return [] }
        if !embedding.hasAvailableAssets {
            // The system downloads the model's assets once; it is offered when they are there.
            if !requested { requested = true; embedding.requestAssets { _, _ in } }
            return []
        }
        return [AIRelay.Model(id: Self.modelID, name: "Apple Contextual Embedding (on iPhone)", contextSize: embedding.maximumSequenceLength,
                              capabilities: [], family: "\(embedding.dimension) dimensions", embedding: true)]
    }

    /// The texts' vectors, in order, and how many tokens they had.
    func embed(_ request: AIRelay.EmbedRequest) async throws -> ([[Float]], Int) {
        guard request.model == Self.modelID, let embedding, embedding.hasAvailableAssets else {
            throw AIRelay.Failure(status: 404, code: "model_not_found", message: "This iPhone has no embedding model \(request.model).")
        }
        if !loaded { try embedding.load(); loaded = true }
        var vectors: [[Float]] = []
        var tokens = 0
        for text in request.input {
            try Task.checkCancellation()
            let result = try embedding.embeddingResult(for: text, language: nil)
            var sum = [Double](repeating: 0, count: embedding.dimension)
            var count = 0
            result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
                for (index, value) in vector.enumerated() where index < sum.count { sum[index] += value }
                count += 1
                return true
            }
            tokens += count
            let mean = sum.map { $0 / Double(max(count, 1)) }
            let norm = mean.reduce(0) { $0 + $1 * $1 }.squareRoot()
            vectors.append(mean.map { Float(norm > 0 ? $0 / norm : 0) })
            await Task.yield()
        }
        return (vectors, tokens)
    }

    func unload() {
        guard loaded else { return }
        embedding?.unload()
        loaded = false
    }
}
