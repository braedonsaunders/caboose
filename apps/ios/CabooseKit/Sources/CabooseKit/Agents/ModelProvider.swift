import Foundation

/// A model provider the owner can connect with an API key instead of signing in to an account.
/// Each is carried by an ACP registry agent that reads the key, and for OpenRouter the model,
/// from its environment, set through `PUT /v1/agents/:id/env` (docs/architecture.md § Agents).
public struct ModelProvider: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// What the provider gives access to, in a few words.
    public let blurb: String
    /// The registry id of the agent that runs it.
    public let agent: String
    public let keyVariable: String
    /// Where the owner gets a key.
    public let keyURL: URL
    /// The variable that names the model, when the owner picks one.
    public let modelVariable: String?
    /// Variables the agent needs alongside the key.
    public let fixedEnvironment: [String: String]

    /// What to set in the agent's environment for `key` and, where the provider takes one, `model`.
    public func environment(key: String, model: String?) -> [String: String] {
        var env = fixedEnvironment
        env[keyVariable] = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if let modelVariable, let model, !model.isEmpty { env[modelVariable] = model }
        return env
    }

    /// Whether `key` could be a key: one line, no spaces, and long enough.
    public static func plausible(key: String) -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.count >= 20 && key.count <= 8192 && !key.contains(where: { $0.isWhitespace })
    }

    public static let openRouter = ModelProvider(
        id: "openrouter", name: "OpenRouter", blurb: "Any model — Claude, GPT, Gemini, Grok, Llama, Qwen, DeepSeek — with one key",
        agent: "goose", keyVariable: "OPENROUTER_API_KEY", keyURL: URL(string: "https://openrouter.ai/keys")!,
        modelVariable: "GOOSE_MODEL",
        fixedEnvironment: ["GOOSE_PROVIDER": "openrouter", "GOOSE_DISABLE_KEYRING": "1"])

    public static let anthropic = ModelProvider(
        id: "anthropic", name: "Anthropic API", blurb: "Claude, billed to your Anthropic API account",
        agent: "claude-acp", keyVariable: "ANTHROPIC_API_KEY", keyURL: URL(string: "https://console.anthropic.com/settings/keys")!,
        modelVariable: nil, fixedEnvironment: [:])

    public static let openAI = ModelProvider(
        id: "openai", name: "OpenAI API", blurb: "Codex with GPT, billed to your OpenAI API account",
        agent: "codex-acp", keyVariable: "OPENAI_API_KEY", keyURL: URL(string: "https://platform.openai.com/api-keys")!,
        modelVariable: nil, fixedEnvironment: [:])

    public static let all: [ModelProvider] = [.openRouter, .anthropic, .openAI]

    /// The provider an agent's environment shows is connected, if any.
    public static func connected(agent: String, environment names: [String]) -> ModelProvider? {
        all.first { $0.agent == agent && names.contains($0.keyVariable) }
    }
}

/// A model OpenRouter serves (`GET https://openrouter.ai/api/v1/models`).
public struct OpenRouterModel: Decodable, Identifiable, Equatable, Sendable {
    public struct Pricing: Decodable, Equatable, Sendable {
        /// US dollars per token, as a decimal string.
        public var prompt: String?
        public var completion: String?
    }

    public var id: String
    public var name: String
    public var created: Double?
    public var contextLength: Int?
    public var pricing: Pricing?
    public var supportedParameters: [String]?

    enum CodingKeys: String, CodingKey {
        case id, name, created, pricing
        case contextLength = "context_length"
        case supportedParameters = "supported_parameters"
    }

    public init(id: String, name: String, created: Double? = nil, contextLength: Int? = nil, pricing: Pricing? = nil, supportedParameters: [String]? = nil) {
        self.id = id; self.name = name; self.created = created; self.contextLength = contextLength
        self.pricing = pricing; self.supportedParameters = supportedParameters
    }

    /// An agent works by calling tools, so only models that take them can run one.
    public var usesTools: Bool { supportedParameters?.contains("tools") ?? false }

    /// Dollars per million input and output tokens, when OpenRouter says.
    public var pricePerMillion: (input: Double, output: Double)? {
        guard let input = pricing?.prompt.flatMap(Double.init), let output = pricing?.completion.flatMap(Double.init) else { return nil }
        return (input * 1_000_000, output * 1_000_000)
    }

    public var vendor: String { String(id.split(separator: "/").first ?? Substring(id)) }

    struct List: Decodable { var data: [OpenRouterModel] }

    public static func decodeList(_ data: Data) throws -> [OpenRouterModel] {
        try JSONDecoder().decode(List.self, from: data).data
    }

    /// Vendors whose newest model is offered first, in this order.
    public static let leadingVendors = ["anthropic", "openai", "google", "x-ai", "moonshotai", "qwen", "deepseek", "meta-llama", "mistralai", "z-ai"]

    /// Models that can run an agent, newest first, with each leading vendor's newest model on top.
    public static func ranked(_ models: [OpenRouterModel]) -> [OpenRouterModel] {
        let usable = models.filter(\.usesTools).sorted { ($0.created ?? 0) > ($1.created ?? 0) }
        let leaders = leadingVendors.compactMap { vendor in usable.first { $0.vendor == vendor } }
        let ids = Set(leaders.map(\.id))
        return leaders + usable.filter { !ids.contains($0.id) }
    }
}
