import Foundation

/// Caboose AI's messages between the host's `/v1/ai` and the phone (docs/ai.md § Phone). The
/// host has checked each request field by field; the phone reads it again, as anything that
/// crosses a network is read.
public enum AIRelay {
    /// A request the computer's program made, in the internal shape (docs/ai.md § Requests).
    public struct Request: Equatable, Sendable {
        public var model: String
        public var messages: [Message]
        public var tools: [Tool]
        public var toolChoice: ToolChoice
        public var temperature: Double?
        public var topP: Double?
        public var topK: Int?
        public var seed: UInt64?
        public var maxTokens: Int?
        public var responseFormat: ResponseFormat?
        public var stop: [String]

        public init(model: String, messages: [Message], tools: [Tool] = [], toolChoice: ToolChoice = .auto, temperature: Double? = nil, topP: Double? = nil,
                    topK: Int? = nil, seed: UInt64? = nil, maxTokens: Int? = nil, responseFormat: ResponseFormat? = nil, stop: [String] = []) {
            self.model = model; self.messages = messages; self.tools = tools; self.toolChoice = toolChoice; self.temperature = temperature; self.topP = topP
            self.topK = topK; self.seed = seed; self.maxTokens = maxTokens; self.responseFormat = responseFormat; self.stop = stop
        }
    }

    public enum Role: String, Sendable { case system, user, assistant, tool }

    public struct Message: Equatable, Sendable {
        public var role: Role
        public var parts: [Part]
        public var toolCalls: [ToolCall]
        public var toolCallId: String?

        public init(role: Role, parts: [Part], toolCalls: [ToolCall] = [], toolCallId: String? = nil) {
            self.role = role; self.parts = parts; self.toolCalls = toolCalls; self.toolCallId = toolCallId
        }

        /// The message's text, its text parts joined.
        public var text: String { parts.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined() }
        public var images: [Image] { parts.compactMap { if case .image(let image) = $0 { image } else { nil } } }
    }

    public enum Part: Equatable, Sendable {
        case text(String)
        case image(Image)
    }

    public struct Image: Equatable, Sendable {
        public var mediaType: String
        public var data: Data
        public init(mediaType: String, data: Data) { self.mediaType = mediaType; self.data = data }
    }

    public struct ToolCall: Equatable, Sendable {
        public var id: String
        public var name: String
        /// JSON text, as the program sent it.
        public var arguments: String
        public init(id: String, name: String, arguments: String) { self.id = id; self.name = name; self.arguments = arguments }
    }

    public struct Tool: Equatable, Sendable {
        public var name: String
        public var description: String
        /// A JSON Schema object.
        public var parameters: AIJSON
        public init(name: String, description: String, parameters: AIJSON) { self.name = name; self.description = description; self.parameters = parameters }
    }

    public enum ToolChoice: Equatable, Sendable { case auto, none, required, named(String) }

    public struct ResponseFormat: Equatable, Sendable {
        public var name: String
        /// A JSON Schema; nil for any JSON object.
        public var schema: AIJSON?
        public init(name: String = "response", schema: AIJSON? = nil) { self.name = name; self.schema = schema }
    }

    /// Texts to embed with an embedding model (docs/ai.md § Embeddings).
    public struct EmbedRequest: Equatable, Sendable {
        public var model: String
        public var input: [String]
        public init(model: String, input: [String]) { self.model = model; self.input = input }
    }

    /// What the host sends: a request to run, or one to stop.
    public enum Incoming: Equatable, Sendable {
        case request(id: String, Request)
        case embed(id: String, EmbedRequest)
        case cancel(id: String)
    }

    public struct InvalidMessage: Error, Equatable {
        public let id: String?
        public let reason: String
    }

    /// Reads one message from the host. A request it cannot read throws with its id, so the
    /// phone can answer that it is invalid.
    public static func incoming(_ text: String) throws -> Incoming {
        let json: AIJSON
        do { json = try AIJSON.parse(text) } catch { throw InvalidMessage(id: nil, reason: "not JSON") }
        guard let id = json["id"]?.string, id.count == 32, id.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw InvalidMessage(id: nil, reason: "no request id") }
        switch json["type"]?.string {
        case "cancel": return .cancel(id: id)
        case "request":
            do { return .request(id: id, try request(json["request"])) } catch let error as InvalidMessage { throw InvalidMessage(id: id, reason: error.reason) }
        case "embed":
            guard let model = json["request"]?["model"]?.string, let input = json["request"]?["input"]?.array?.compactMap(\.string), !input.isEmpty else {
                throw InvalidMessage(id: id, reason: "an embeddings request needs a model and texts")
            }
            return .embed(id: id, EmbedRequest(model: model, input: input))
        default: throw InvalidMessage(id: id, reason: "unknown message type")
        }
    }

    static func invalid(_ reason: String) -> InvalidMessage { InvalidMessage(id: nil, reason: reason) }

    static func request(_ json: AIJSON?) throws -> Request {
        guard let json, let model = json["model"]?.string, let messages = json["messages"]?.array, !messages.isEmpty else { throw invalid("a request needs a model and messages") }
        var request = Request(model: model, messages: try messages.map(message))
        if let tools = json["tools"]?.array {
            request.tools = try tools.map { tool in
                guard let name = tool["name"]?.string, let parameters = tool["parameters"], parameters.pairs != nil else { throw invalid("a tool needs a name and parameters") }
                return Tool(name: name, description: tool["description"]?.string ?? "", parameters: parameters)
            }
        }
        switch json["toolChoice"] {
        case nil, .string("auto"): request.toolChoice = .auto
        case .string("none"): request.toolChoice = .none
        case .string("required"): request.toolChoice = .required
        case let choice?:
            guard let name = choice["name"]?.string else { throw invalid("toolChoice must be auto, none, required or { name }") }
            request.toolChoice = .named(name)
        }
        request.temperature = json["temperature"]?.number
        request.topP = json["topP"]?.number
        request.topK = json["topK"]?.integer
        request.seed = json["seed"]?.integer.flatMap { $0 >= 0 ? UInt64($0) : nil }
        request.maxTokens = json["maxTokens"]?.integer
        if let format = json["responseFormat"] {
            guard format["type"]?.string == "json" else { throw invalid("responseFormat must be json") }
            request.responseFormat = ResponseFormat(name: format["name"]?.string ?? "response", schema: format["schema"])
        }
        request.stop = json["stop"]?.array?.compactMap(\.string) ?? []
        return request
    }

    static func message(_ json: AIJSON) throws -> Message {
        guard let raw = json["role"]?.string, let role = Role(rawValue: raw) else { throw invalid("a message needs a role") }
        var parts: [Part] = []
        switch json["content"] {
        case .string(let text)?: if !text.isEmpty { parts = [.text(text)] }
        case .array(let items)?:
            parts = try items.map { item in
                switch item["type"]?.string {
                case "text": return .text(item["text"]?.string ?? "")
                case "image":
                    guard let type = item["mediaType"]?.string, let base64 = item["data"]?.string, let data = Data(base64Encoded: base64) else { throw invalid("an image needs a type and base64 data") }
                    return .image(Image(mediaType: type, data: data))
                default: throw invalid("a part must be text or an image")
                }
            }
        case nil, .null?: break
        default: throw invalid("content must be text or parts")
        }
        let calls = try (json["toolCalls"]?.array ?? []).map { call in
            guard let id = call["id"]?.string, let name = call["name"]?.string else { throw invalid("a tool call needs an id and a name") }
            return ToolCall(id: id, name: name, arguments: call["arguments"]?.string ?? "{}")
        }
        return Message(role: role, parts: parts, toolCalls: calls, toolCallId: json["toolCallId"]?.string)
    }

    // MARK: What the phone sends

    public struct Model: Equatable, Sendable {
        public var id: String
        public var name: String
        public var contextSize: Int
        public var capabilities: [String]
        public var family: String?
        public var embedding: Bool
        public var ownedBy: String
        public init(id: String, name: String, contextSize: Int, capabilities: [String], family: String? = nil, embedding: Bool = false, ownedBy: String = "apple") {
            self.id = id; self.name = name; self.contextSize = contextSize; self.capabilities = capabilities; self.family = family
            self.embedding = embedding; self.ownedBy = ownedBy
        }
    }

    public enum FinishReason: String, Sendable { case stop, length, toolCalls = "tool_calls", contentFilter = "content_filter" }

    public struct Usage: Equatable, Sendable {
        public var promptTokens: Int
        public var completionTokens: Int
        public var cachedTokens: Int?
        public var reasoningTokens: Int?
        public init(promptTokens: Int, completionTokens: Int, cachedTokens: Int? = nil, reasoningTokens: Int? = nil) {
            self.promptTokens = promptTokens; self.completionTokens = completionTokens; self.cachedTokens = cachedTokens; self.reasoningTokens = reasoningTokens
        }
    }

    /// One piece of a tool call as it streams: the first carries its id and name.
    public struct ToolCallDelta: Equatable, Sendable {
        public var index: Int
        public var id: String?
        public var name: String?
        public var arguments: String
        public init(index: Int, id: String? = nil, name: String? = nil, arguments: String) { self.index = index; self.id = id; self.name = name; self.arguments = arguments }
    }

    /// A failure the program sees as an HTTP status with an OpenAI-style error code.
    public struct Failure: Error, Equatable, Sendable {
        public var status: Int
        public var code: String
        public var message: String
        public init(status: Int, code: String, message: String) { self.status = status; self.code = code; self.message = message }
    }

    public static func hello(_ models: [Model]) -> String {
        AIJSON.object([("type", .string("hello")), ("models", .array(models.map { model in
            var pairs: [(key: String, value: AIJSON)] = [("id", .string(model.id)), ("name", .string(model.name)), ("contextSize", .number(Double(model.contextSize))),
                                                        ("capabilities", .array(model.capabilities.map(AIJSON.string))), ("ownedBy", .string(model.ownedBy))]
            if let family = model.family { pairs.append(("family", .string(family))) }
            if model.embedding { pairs.append(("type", .string("embedding"))) }
            return .object(pairs)
        }))]).text
    }

    public static func started(_ id: String) -> String {
        AIJSON.object([("type", .string("started")), ("id", .string(id))]).text
    }

    public static func delta(_ id: String, content: String? = nil, reasoning: String? = nil, toolCalls: [ToolCallDelta] = []) -> String {
        var pairs: [(key: String, value: AIJSON)] = [("type", .string("delta")), ("id", .string(id))]
        if let content { pairs.append(("content", .string(content))) }
        if let reasoning { pairs.append(("reasoning", .string(reasoning))) }
        if !toolCalls.isEmpty {
            pairs.append(("toolCalls", .array(toolCalls.map { call in
                var item: [(key: String, value: AIJSON)] = [("index", .number(Double(call.index)))]
                if let id = call.id { item.append(("id", .string(id))) }
                if let name = call.name { item.append(("name", .string(name))) }
                item.append(("arguments", .string(call.arguments)))
                return .object(item)
            })))
        }
        return AIJSON.object(pairs).text
    }

    public static func vector(_ id: String, index: Int, values: [Float]) -> String {
        AIJSON.object([("type", .string("vector")), ("id", .string(id)), ("index", .number(Double(index))),
                       ("values", .array(values.map { .number(Double($0)) }))]).text
    }

    public static func done(_ id: String, finish: FinishReason, usage: Usage) -> String {
        var counts: [(key: String, value: AIJSON)] = [("promptTokens", .number(Double(usage.promptTokens))), ("completionTokens", .number(Double(usage.completionTokens)))]
        if let cached = usage.cachedTokens { counts.append(("cachedTokens", .number(Double(cached)))) }
        if let reasoning = usage.reasoningTokens { counts.append(("reasoningTokens", .number(Double(reasoning)))) }
        return AIJSON.object([("type", .string("done")), ("id", .string(id)), ("finishReason", .string(finish.rawValue)), ("usage", .object(counts))]).text
    }

    public static func error(_ id: String, _ failure: Failure) -> String {
        AIJSON.object([("type", .string("error")), ("id", .string(id)), ("status", .number(Double(failure.status))),
                       ("code", .string(failure.code)), ("message", .string(String(failure.message.prefix(2000))))]).text
    }
}
